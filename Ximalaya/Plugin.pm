# Plugins::Ximalaya::Plugin
#
# Ximalaya (喜马拉雅) online audio for Lyrion Music Server / Daphile.
# Menu pattern follows Slim::Plugin::Podcast::Plugin (Slim::Plugin::OPMLBased).
#
# Personal use only: requires the user's own login cookie (set in plugin
# settings). No credentials are bundled; audio is streamed, never cached.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License, version 2.

package Plugins::Ximalaya::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Time::HiRes qw(time);

use Plugins::Ximalaya::API;
use Plugins::Ximalaya::Categories;

# make sure the xmly:// protocol handler is registered early
use Plugins::Ximalaya::ProtocolHandler;

# pc show page width cap - single source of truth in API.pm
use constant PC_SHOW_MAX => Plugins::Ximalaya::API::PC_SHOW_MAX();

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.ximalaya',
	'defaultLevel' => 'ERROR',
	'description'  => __PACKAGE__->getDisplayName(),
});

# name shown by LMS/Daphile in the plugin list (strings token)
sub getDisplayName { return 'PLUGIN_XIMALAYA'; }

my $prefs = preferences('plugin.ximalaya');

# Local-only risk-control cooldown (0.1.7): after a soft-risk hit on a
# browse endpoint family, repeat menu requests within this window are
# answered with a hint instead of hammering the API. Playback resolution
# (ProtocolHandler -> resolveTrack) is NEVER gated - playing must always
# get its chance.
use constant RISK_COOLDOWN => 60;    # seconds

my %RISK_LAST;                       # family => epoch of last risk hit

sub _cooling {
	my ($family) = @_;
	return (($RISK_LAST{$family} || 0) + RISK_COOLDOWN) > time();
}

# Record a soft-risk hit for a browse endpoint family (audit P1-1 fix:
# single entry point - the menu handlers' error paths AND
# Plugins::Ximalaya::Categories (family 'category') all report here).
# Local-only state, never persisted.
sub note_risk_hit {
	my ($family) = @_;
	$RISK_LAST{$family || ''} = time();
	return;
}

sub initPlugin {
	my $class = shift;

	$prefs->init({
		cookie  => '',
		quality => 64,
		albums  => '',       # newline separated album ids
		pc_channel   => 1,   # 0.1.12: pc (desktop-client) channel master switch
		mobile_channel => 1, # 0.1.17: mobile album list (exact totals for paid albums)
		pc_device_id => '',  # self-made pc device uuid, persisted (see API.pm)
	});

	if (main::WEBUI) {
		require Plugins::Ximalaya::Settings;
		Plugins::Ximalaya::Settings->new();
	}

	# 0.1.29: HTTP feed route for starred albums. Favourites entries point at
	# this URL (see albumItem) so clicking one in Favourites browses the
	# album's track list like any other menu instead of failing with
	# "can not request non-http url".
	require Slim::Web::Pages;
	Slim::Web::Pages->addPageFunction(
		qr{^plugins/Ximalaya/albumfeed\.html$},
		\&albumFeedHandler,
	);

	$class->SUPER::initPlugin(
		feed => \&handleFeed,
		tag  => 'ximalaya',
		menu => 'apps',
	);

	return;
}

# ------------------------------------------------------------------ top menu

# 0.1.7 order: browse entries first, tools next, status last
sub handleFeed {
	my ($client, $cb, $params, $args) = @_;

	my $logged = Plugins::Ximalaya::API->logged_in;

	my @items = (
		{
			name => cstring($client, 'PLUGIN_XIMALAYA_MYALBUMS'),
			type => 'link',
			url  => \&myAlbumsHandler,
		},
		{
			name => cstring($client, 'PLUGIN_XIMALAYA_CATEGORY'),
			type => 'link',
			url  => \&categoriesFeed,
		},
		{
			name => cstring($client, 'PLUGIN_XIMALAYA_SEARCH'),
			type => 'search',
			url  => \&searchHandler,
		},
		{
			name        => cstring($client, 'PLUGIN_XIMALAYA_PASTE'),
			type        => 'search',
			url         => \&pasteHandler,
			passthrough => ['paste'],
		},
		{
			name => cstring($client, 'PLUGIN_XIMALAYA_ACCOUNT') . ': '
				. ($logged ? 'OK' : cstring($client, 'PLUGIN_XIMALAYA_NOLOGIN')),
			type => 'text',
		},
	);

	$cb->({ items => \@items });
}

sub categoriesFeed {
	my ($client, $cb, $args) = @_;
	Plugins::Ximalaya::Categories->feed($client, $cb);
	return;
}

# ------------------------------------------------------------------- search

# 0.1.27: m-channel search with native windowing. The server page width is
# M_SEARCH_ROWS (20; it clamps rows), NOT the UI quantity - so the page index
# is derived from $args->{index} against that width, and the reply reports
# { items, offset, total } for the UI pager exactly like albumHandler.
sub searchHandler {
	my ($client, $cb, $args) = @_;
	my $search = $args->{search} || '';

	unless ($search) {
		$cb->({ items => [] });
		return;
	}

	if (_cooling('search')) {
		$cb->({ items => [ { name => cstring($client, 'PLUGIN_XIMALAYA_COOLDOWN'), type => 'text' } ] });
		return;
	}

	my $rows  = Plugins::Ximalaya::API::M_SEARCH_ROWS();
	my $index = $args->{index} || 0;
	my $page  = int($index / $rows) + 1;
	my $offset = ($page - 1) * $rows;

	Plugins::Ximalaya::API->searchAlbums(
		$search,
		$page,
		sub {
			my ($albums, $total) = @_;
			$cb->({
				items  => [ map { albumItem($_) } @$albums ],
				offset => $offset,
				(defined $total && $total > 0 ? (total => $total) : ()),
			});
		},
		sub {
			my ($code) = @_;
			note_risk_hit('search') if ($code || '') eq 'risk';
			$cb->({ items => [ errItem($client, $code) ] });
		},
	);

	return;
}

# -------------------------------------------------------------- album tracks

# 0.1.29: absolute feed URL for a starred album. Favourites store the URL
# string as-is and LMS later fetches it SERVER-SIDE, so it must be absolute
# (serverURL is client-less). Browsing it renders the OPML produced by
# albumFeedHandler below.
sub _albumFeedUrl {
	my ($albumId) = @_;
	my $base = eval { require Slim::Utils::Network; Slim::Utils::Network::serverURL() };
	$base = 'http://127.0.0.1:9000' unless $base;    # never expected; keep the entry non-fatal
	$base =~ s{/+$}{};
	return $base . '/plugins/Ximalaya/albumfeed.html?album=' . $albumId;
}

sub albumItem {
	my ($album) = @_;
	my $name = $album->{title} // "Album $album->{id}";
	$name .= " - $album->{announcer}" if $album->{announcer};
	$name .= ' [VIP]' if $album->{paid};

	# 0.1.28/0.1.29: native favourite support. The web UI (Slim::Web::XMLBrowser)
	# renders an add/remove favourites action for any item carrying a
	# favorites_url and flags it as already-starred (favorites=2) via
	# Favorites->hasUrl. Starred entries land in LMS Favourites as HTTP feed
	# URLs (albumfeed.html?album=N); clicking one browses the track list
	# (0.1.29; the earlier xmly://album/<id> shape was a dead bookmark).
	# One place here covers EVERY album entry point (search, ranks, catalog
	# browse, my albums itself).
	#
	# 0.1.34: whole-album play on the row itself (the Daphile equivalent of
	# the local album row's play button). 'play' gives the row the same
	# play/add controls the local library album rows have; the URL is
	# xmly://album/<id>, which ProtocolHandler::explodePlaylist expands into
	# the full ordered track list (the native mechanism LMS uses for
	# Spotify albums). The row itself still DESCENDS into the track list.
	return {
		name        => $name,
		image       => $album->{cover},
		type        => 'link',
		url         => \&albumHandler,
		passthrough => [ $album->{id} ],
		play            => 'xmly://album/' . $album->{id},
		favorites_url   => _albumFeedUrl($album->{id}),
		favorites_title => $name,
		favorites_type  => 'link',
	};
}

sub _albumFallbackItem {
	my ($id) = @_;
	return {
		name        => "Album $id",
		type        => 'link',
		url         => \&albumHandler,
		passthrough => [ $id ],
		favorites_url   => _albumFeedUrl($id),
		favorites_title => "Album $id",
		favorites_type  => 'link',
	};
}

sub albumHandler {
	# XMLBrowser calls coderef feeds as: handler($client, $cb, \%args, @passthrough).
	# 0.1.10: NATIVE WINDOWING - the web/player UI passes $args->{index}
	# (first wanted item) and $args->{quantity} (= server pref itemsPerPage,
	# 50 on Daphile). We fetch exactly that page from the API and report
	# { items, offset, total } so the UI renders its own pager.
	#
	# 0.1.12/0.1.13/0.1.14/0.1.16: track-list routing. Since 0.1.13 the PC
	# channel is primary (user decision: VIP included) because web
	# getTracksList 1005's for the free-list family. 0.1.14 fixed the
	# 30-vs-50 page misalignment (show honors size). 0.1.16: the page
	# COUNT is fixed by routing paid/VIP albums to the mobile list first -
	# VERIFIED one-shot reply with list + EXACT totalCount (+ per-track
	# isPaid, so [VIP] returns), 30min cache; its empty reply means the
	# album is not on the mobile index (typical FREE album) and we fall
	# through: mobile -> pc show (hasMore estimate) -> web. The 0.1.15
	# albumInfo detour is gone - album/simple carries no track count at
	# all (probe-verified 2026-09-10). Cooldown families: 'tracks_mobile'
	# (mobile list), 'tracks' (pc show), 'tracks_web' (web list).
	my ($client, $cb, $args, $albumId) = @_;
	$albumId ||= '';

	my $quantity = $args->{quantity} || 50;
	$quantity = 1                if $quantity < 1;
	$quantity = PC_SHOW_MAX()    if $quantity > PC_SHOW_MAX();
	my $index = $args->{index} || 0;
	my $page  = int($index / $quantity) + 1;

	my $render = sub {
		my ($tracks, $total, $offset) = @_;
		$log->debug("Ximalaya: albumHandler album=$albumId idx=$index qty=$quantity got "
			. scalar(@$tracks) . " tracks at offset=$offset"
			. (defined $total ? " of $total" : ''));
		my $n = 0;
		my @items = map { trackItem(++$n + $offset, $_) } @$tracks;

		# 0.1.34: trailing "play whole album" row at combined position
		# $total (the first window that reaches past the last track renders
		# it; the index<->track mapping of the earlier pages stays
		# untouched - the 0.1.28 windowing lesson). explodePlaylist turns
		# the xmly://album URL into the whole ordered list natively.
		# Callers that decorate the list themselves (the favourites feed)
		# pass no_play_row and get the plain track total back.
		if (!$args->{no_play_row}
			&& defined $total && $index <= $total && $index + $quantity > $total && @items) {
			push @items, {
				name => cstring($client, 'PLUGIN_XIMALAYA_PLAY_ALL'),
				type => 'audio',
				play => 'xmly://album/' . $albumId,
				($tracks->[0] && $tracks->[0]->{cover}
					? (image => $tracks->[0]->{cover})
					: ()),
			};
		}

		$cb->({
			items  => \@items,
			offset => $offset,
			(defined $total ? (total => $total + ($args->{no_play_row} ? 0 : 1)) : ()),
			# 0.1.35: feed-level actions become the level's BASE actions
			# (Slim::Control::XMLBrowser menuMode: _makeAction($feedActions,
			# 'play'|'add'|'insert')) - the UI renders them as the HEADER
			# play/add buttons next to the album image, exactly like a local
			# album page. Each command plays/adds the WHOLE album through
			# ProtocolHandler::explodePlaylist (same URL as the album row).
			($albumId =~ /^\d+$/
				? (actions => _album_play_actions($albumId))
				: ()),
		});
	};
	my $fail = sub {
		my ($code) = @_;
		$cb->({ items => [ errItem($client, $code) ] });
	};

	# web fallback: skipped while its own family is cooling
	my $tryWeb = sub {
		my ($pccode) = @_;
		if (_cooling('tracks_web')) {
			$fail->($pccode);
			return;
		}
		Plugins::Ximalaya::API->albumTracks(
			$albumId,
			$page,
			$quantity,
			sub {
				my ($tracks, $total) = @_;
				$render->($tracks, $total, ($page - 1) * $quantity);
			},
			sub {
				my ($code) = @_;
				note_risk_hit('tracks_web') if ($code || '') eq 'risk';
				$log->debug("Ximalaya: web fallback failed for album $albumId ("
					. ($code // '?') . ", pc was: " . ($pccode // '-') . ")");
				$fail->($code);
			},
		);
	};

	if (!Plugins::Ximalaya::API->pc_enabled) {
		# web-only mode: pre-0.1.12 behaviour including the cooldown hint
		if (_cooling('tracks_web')) {
			$cb->({ items => [ { name => cstring($client, 'PLUGIN_XIMALAYA_COOLDOWN'), type => 'text' } ] });
			return;
		}
		Plugins::Ximalaya::API->albumTracks(
			$albumId,
			$page,
			$quantity,
			sub {
				my ($tracks, $total) = @_;
				$render->($tracks, $total, ($page - 1) * $quantity);
			},
			sub {
				note_risk_hit('tracks_web') if ($_[0] || '') eq 'risk';
				$fail->($_[0]);
			},
		);
		return;
	}

	# pc show path - list only, NO server total (hasMore estimate; free
	# albums land here since the mobile index carries paid/VIP only)
	my $tryPC = sub {
		if (_cooling('tracks')) {
			$tryWeb->(undef);
			return;
		}
		Plugins::Ximalaya::API->albumTracksShow($albumId, $page, $quantity,
			sub {
				my ($tracks, $has_more) = @_;
				my $off = ($page - 1) * $quantity;
				# no server total: show "one more page" while hasMore, exact
				# count once the last page arrives
				my $total = $has_more ? $off + @$tracks + $quantity
				                      : $off + @$tracks;
				$render->($tracks, $total, $off);
			},
			sub {
				my ($code) = @_;
				note_risk_hit('tracks') if ($code || '') eq 'risk';
				$log->debug("Ximalaya: pc primary failed for album $albumId ("
					. ($code // '?') . ") - web fallback");
				$tryWeb->($code);
			},
		);
	};

	# mobile path FIRST (0.1.16): VERIFIED one-shot list + EXACT totalCount
	# (+ per-track isPaid) for paid/VIP albums, 30min cache; free albums
	# answer with an empty list ('empty', NOT an error) -> straight to pc.
	# The 0.1.15 albumInfo detour is gone: album/simple carries no track
	# count at all (probe-verified), so it could never fix the page count.
	my $tryMobile = sub {
		Plugins::Ximalaya::API->albumTracksMobile($albumId, $page, $quantity,
			sub {
				my ($tracks, $total) = @_;
				$render->($tracks, $total, ($page - 1) * $quantity);
			},
			sub {
				my ($code) = @_;
				note_risk_hit('tracks_mobile') if ($code || '') eq 'risk';
				$log->debug("Ximalaya: mobile list unavailable for album $albumId ("
					. ($code // '?') . ") - pc show path");
				$tryPC->(undef);
			},
		);
	};

	if (_cooling('tracks_mobile') || !Plugins::Ximalaya::API->mobile_enabled) {
		$tryPC->(undef);
		return;
	}
	$tryMobile->();

	return;
}

sub trackItem {
	my ($idx, $t) = @_;

	return {
		name      => ($t->{paid} ? '[VIP] ' : '') . "$idx. $t->{title}",
		image     => $t->{cover},
		type      => 'audio',
		play      => "xmly://$t->{id}",
		on_select => 'play',
	};
}

# 0.1.35: feed-level actions for an album track list (the menu level). XMLBrowser
# (menuMode) feeds these through _makeAction() into the result's 'base' actions -
# the play/add buttons the UI renders in the page HEADER next to the album image
# (the same chrome a local album page gets). Each command hits the xmly://album
# URL, which ProtocolHandler::explodePlaylist expands to the full ordered track
# list - one tap plays/queues the entire album. Shape per XMLBrowser::_makeAction:
#   command     -> becomes the action's cmd
#   fixedParams -> becomes its params ('menu' is force-added there)
sub _album_play_actions {
	my ($albumId) = @_;
	return {
		play => {
			command     => [ 'playlist', 'play',   'xmly://album/' . $albumId ],
			fixedParams => {},
		},
		add => {
			command     => [ 'playlist', 'add',    'xmly://album/' . $albumId ],
			fixedParams => {},
		},
		insert => {
			command     => [ 'playlist', 'insert', 'xmly://album/' . $albumId ],
			fixedParams => {},
		},
	};
}

# --------------------------------------------------- starred-album HTTP feed

sub _xml_escape {
	my ($s) = @_;
	return '' unless defined $s;
	$s =~ s/&/&amp;/g;
	$s =~ s/</&lt;/g;
	$s =~ s/>/&gt;/g;
	$s =~ s/"/&quot;/g;
	return $s;
}

# 0.1.31: per-feed-page TRACK width. The web UI pages a fetched feed by
# SLICING it: Slim::Web::XMLBrowser fetches the URL once, caches the whole
# parsed feed in a browse session and Slim::Web::Pages::Common::pageInfo
# slices it per page - the UI never re-fetches with a page parameter. So a
# feed page must never carry MORE items than the UI page width, or the
# overflow becomes a phantom page holding only the next-page row (the
# 0.1.29 bug: 50 tracks + 1 next-page row = 51 items vs 50 per page ->
# "page 2 shows nothing but next page"). Width = itemsPerPage - 3 (room
# for the 0.1.33 play-whole-album row, the next-page row AND the 0.1.32
# jump-to-page row), capped at PC_SHOW_MAX (the API page width).
# itemsPerPage is the same server preference the UI uses (pageInfo falls
# back to preferences('server')->get('itemsPerPage'); Daphile default 50).
sub _feed_page_width {
	my $pp = eval { preferences('server')->get('itemsPerPage') };
	$pp = 50 unless $pp && $pp =~ /^\d+$/ && $pp >= 4;    # garbage/tiny -> Daphile default
	$pp = 500 if $pp > 500;                               # paranoia clamp
	my $w = $pp - 3;
	$w = 1             if $w < 1;
	$w = PC_SHOW_MAX() if $w > PC_SHOW_MAX();
	return $w;
}

# 0.1.29: the web page behind a starred album's Favourites entry. LMS
# fetches it server-side as a remote OPML feed when the user clicks the
# favourite (Slim::Formats::XML), so we serve classic outline attributes
# (text/URL/type). Track rows are type=audio with xmly:// play URLs (the
# protocol handler is registered, playback verified), the next-page row is
# type=link pointing back at this route. Reuses albumHandler's
# mobile -> pc -> web routing + windowing untouched.
# 0.1.31: rows are laid out on _feed_page_width() boundaries so every
# fetched page fits on ONE UI page (no phantom pager page), and outlines
# carry image="..." covers (Slim::Formats::XML copies unknown outline
# attributes verbatim into the item hash; Daphile renders item images).
# 0.1.32: jump-to-page layer. The native pager cannot work across feed
# windows (a fetched feed is cached and sliced, never re-fetched), and
# db:-style coderef rewriting is hardcoded to local-library URLs - so
# direct page selection is built INTO the feed: each track page carries a
# "jump to page" row whose URL embeds the server total; that layer
# (mode=pages) lists every page as a link row generated LOCALLY with zero
# API calls. The page list itself is one fetch -> the UI's native pager
# works on it for free even for huge albums.
sub albumFeedHandler {
	my ($client, $params, $callback, $httpClient, $response) = @_;

	my $albumId = ($params->{album} || '') =~ /^(\d+)$/ ? $1 : '';
	my $page    = (($params->{page} || 1) =~ /^(\d+)$/ ? $1 : 1) || 1;
	$page = 1 if $page < 1;
	my $width = _feed_page_width();

	my $finish = sub {
		my ($items) = @_;

		my @rows;
		for my $it (@$items) {
			my $name = _xml_escape($it->{name} || '');
			next unless $name ne '';
			my $type = $it->{type} || '';
			my $img  = $it->{image} ? ' image="' . _xml_escape($it->{image}) . '"' : '';
			if ($type eq 'audio' && $it->{play}) {
				push @rows, '<outline text="' . $name . '" URL="'
					. _xml_escape($it->{play}) . '" type="audio"' . $img . '/>';
			}
			elsif (($type eq 'link' || $type eq 'audio') && $it->{url}) {
				push @rows, '<outline text="' . $name . '" URL="'
					. _xml_escape($it->{url}) . '" type="link"' . $img . '/>';
			}
			else {
				# error/status rows degrade to plain text entries
				push @rows, '<outline text="' . $name . '" type="text"' . $img . '/>';
			}
		}

		my $body = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' . "\n"
			. '<opml version="1.0"><head><title>Ximalaya album ' . _xml_escape($albumId)
			. '</title></head><body>' . "\n"
			. join("\n", @rows) . "\n</body></opml>";

		$response->content_type('text/xml; charset=utf-8');
		$callback->($client, $params, \$body, $httpClient, $response);
		return;
	};

	unless ($albumId) {
		$finish->([]);
		return;
	}

	# 0.1.32: page list layer - mode=pages&total=N. Pure local generation
	# from the total that the track page embedded in the link; one row per
	# page, each leading back to the track feed at that page.
	if (($params->{mode} || '') eq 'pages') {
		my $total = ($params->{total} || '') =~ /^(\d{1,7})$/ ? $1 : 0;
		my @items;
		if ($total) {
			my $pages = int(($total + $width - 1) / $width);
			for my $p (1 .. $pages) {
				my $from = ($p - 1) * $width + 1;
				my $to   = $from + $width - 1;
				$to = $total if $to > $total;
				push @items, {
					name => cstring($client, 'PLUGIN_XIMALAYA_PAGE_OF', $p, $from, $to),
					type => 'link',
					url  => _albumFeedUrl($albumId) . '&page=' . $p,
				};
			}
		}
		$finish->(\@items);
		return;
	}

	Plugins::Ximalaya::Plugin::albumHandler($client,
		sub {
			my ($feed) = @_;
			my $items = $feed->{items} || [];
			# navigation rows. Play-whole-album sits on top; next-page and
			# jump-to-page close the page. The nav rows reuse the first
			# cover of this batch so they do not render bare in cover-aware
			# skins. The jump row embeds the server total into its URL
			# (mode=pages layer above) so flipping to it costs zero API
			# calls. The play row's xmly://album URL is expanded into the
			# FULL ordered album by ProtocolHandler::explodePlaylist (one
			# click = whole album in the queue).
			my $total = $feed->{total};
			my $have  = ($feed->{offset} || 0) + scalar @$items;
			my ($cover) = map { $_->{image} || () } @$items;
			if (scalar @$items) {
				my $name = cstring($client, 'PLUGIN_XIMALAYA_PLAY_ALL');
				$name .= " ($total)" if defined $total && $total =~ /^\d+$/;
				unshift @$items, {
					name  => $name,
					type  => 'audio',
					play  => 'xmly://album/' . $albumId,
					image => $cover,
				};
			}
			if (defined $total && $have < $total && scalar @$items) {
				push @$items, {
					name  => cstring($client, 'PLUGIN_XIMALAYA_NEXT_PAGE'),
					type  => 'link',
					url   => _albumFeedUrl($albumId) . '&page=' . ($page + 1),
					image => $cover,
				};
			}
			if (defined $total && $total > $width) {
				my $pages = int(($total + $width - 1) / $width);
				push @$items, {
					name  => cstring($client, 'PLUGIN_XIMALAYA_JUMP_PAGES', $pages),
					type  => 'link',
					url   => _albumFeedUrl($albumId) . '&mode=pages&total=' . $total,
					image => $cover,
				};
			}
			$finish->($items);
		},
		# no_play_row: this feed adds its OWN leading play-all row (with
		# count + cover) - the handler's trailing row and the +1 total are
		# for the menu track list only
		{ quantity => $width, index => ($page - 1) * $width, no_play_row => 1 },
		$albumId,
	);

	return;
}

# --------------------------------------------------------------- my albums

sub myAlbumsHandler {
	my ($client, $cb, $args) = @_;

	# 0.1.28: two sources, merged. (1) the plugin pref 'albums' (editable in
	# settings, order preserved) and (2) albums the user starred with the
	# web UI's native favourites action - those are stored in LMS Favourites
	# as xmly://album/<id> links (see albumItem). Dedup with the pref list
	# first. A missing/unreadable Favorites module degrades silently to the
	# pref-only list.
	my $raw = $prefs->get('albums') || '';
	my @ids = grep { /^\d+$/ } split /[\s,;]+/, $raw;
	my %seen = map { $_ => 1 } @ids;

	my $favs = eval {
		require Slim::Utils::Favorites;
		Slim::Utils::Favorites->new($client);
	};
	if ($favs) {
		my $items = eval { $favs->all } || [];
		for my $fi (@$items) {
			my $u = $fi->{url} || '';
			# 0.1.29 URL shape (albumfeed.html?album=N) + 0.1.28 legacy
			# (xmly://album/N) - both merge into my albums
			next unless ($u =~ m{^xmly://album/(\d+)} || $u =~ m{albumfeed\.html\?album=(\d+)});
			push @ids, $1 unless $seen{$1}++;
		}
	}

	unless (@ids) {
		$cb->({ items => [ { name => cstring($client, 'PLUGIN_XIMALAYA_NOALBUMS'), type => 'text' } ] });
		return;
	}

	# 0.1.7: resolve real titles/covers via album/simple (cached 30 min),
	# one by one to stay gentle; a failing id degrades to the bare entry.
	_albumSeq($client, $cb, \@ids, 0, []);

	return;
}

sub _albumSeq {
	my ($client, $cb, $ids, $i, $out) = @_;
	my $next = sub {
		push @$out, @_;
		_albumSeq($client, $cb, $ids, $i + 1, $out);
	};

	if ($i >= @$ids) {
		$cb->({ items => [ @$out ] });
		return;
	}
	my $id = $ids->[$i];

	Plugins::Ximalaya::API->albumInfo($id,
		sub { $next->(albumItem($_[0])) },
		sub { $next->(_albumFallbackItem($id)) },
	);

	return;
}

# ------------------------------------------------------------- paste & play
#
# 0.1.7: accepts one or more of (whitespace/comma/semicolon separated):
#   /album/<id>         -> straight into the album track list
#   /sound/<id>         -> titled track + "open containing album" link
#   xmly://[track/]<id> -> same as /sound/
#   bare <id>           -> album first (album/simple), single track on failure
# Track metadata comes from baseInfo (verified endpoint); any metadata
# failure degrades silently to a plain "Track <id>" play entry.

sub pasteHandler {
	my ($client, $cb, $args) = @_;
	my $input = $args->{search} || '';
	$input =~ s/^\s+|\s+$//g;

	my @entries;
	for my $tok (split /[\s,;]+/, $input) {
		next unless length $tok;
		if    (my ($a) = $tok =~ m{/album/(\d+)})                        { push @entries, [ album => $a ] }
		elsif (my ($t) = $tok =~ m{(?:/sound/|xmly://(?:track/)?)(\d+)}) { push @entries, [ track => $t ] }
		elsif ($tok =~ /^(\d+)$/)                                        { push @entries, [ bare  => $1 ] }
	}

	unless (@entries) {
		$cb->({ items => [ { name => cstring($client, 'PLUGIN_XIMALAYA_BADINPUT'), type => 'text' } ] });
		return;
	}

	$#entries = 9 if @entries > 10;   # cap: every entry costs a lookup

	_pasteSeq($client, $cb, \@entries, 0, []);
	return;
}

sub _pasteSeq {
	my ($client, $cb, $entries, $i, $out) = @_;
	my $next = sub {
		push @$out, @_;
		_pasteSeq($client, $cb, $entries, $i + 1, $out);
	};

	if ($i >= @$entries) {
		$cb->({ items => [ @$out ] });
		return;
	}
	my ($kind, $id) = @{ $entries->[$i] };

	if ($kind eq 'album') {
		$next->(_albumFallbackItem($id));
		return;
	}

	if ($kind eq 'bare') {
		Plugins::Ximalaya::API->albumInfo($id,
			sub {
				# confirmed album: splice its full track list in place
				albumHandler($client,
					sub {
						push @$out, @{ $_[0]->{items} };
						_pasteSeq($client, $cb, $entries, $i + 1, $out);
					},
					{ passthrough => [$id] },
				);
			},
			sub { _trackEntry($client, $next, $id) },   # fall back to single track
		);
		return;
	}

	# /sound/<id> or xmly://<id>
	_trackEntry($client, $next, $id);
	return;
}

# resolve one track entry via baseInfo metadata (Plugin-side wrapper);
# metadata failures still leave a playable item - never a dead end
sub _trackEntry {
	my ($client, $done, $trackId) = @_;

	Plugins::Ximalaya::API->trackMeta($trackId,
		sub {
			my ($meta) = @_;
			my @items = ( _trackAudioItem($trackId, $meta->{title}) );

			# album reference is defensive: current baseInfo payloads expose
			# none for free tracks; when one appears the link lights itself up
			if (my $albumId = $meta->{albumId}) {
				push @items, {
					name        => cstring($client, 'PLUGIN_XIMALAYA_TRACK_ALBUM')
						. ($meta->{albumTitle} ? ": $meta->{albumTitle}" : ''),
					type        => 'link',
					url         => \&albumHandler,
					passthrough => [ $albumId ],
				};
			}

			$done->(@items);
		},
		sub { $done->(_trackAudioItem($trackId)) },
	);

	return;
}

sub _trackAudioItem {
	my ($trackId, $title) = @_;
	return {
		name      => $title // "Track $trackId",
		type      => 'audio',
		play      => "xmly://$trackId",
		on_select => 'play',
	};
}

# -------------------------------------------------------------- error items

sub errItem {
	my ($client, $code) = @_;

	my %token = (
		1001     => 'PLUGIN_XIMALAYA_ERR_LOGIN',
		303      => 'PLUGIN_XIMALAYA_ERR_LOGIN',   # m channel: needLogin (stale cookie)
		927      => 'PLUGIN_XIMALAYA_ERR_NOPERM',
		3005     => 'PLUGIN_XIMALAYA_ERR_NOPERM',
		risk     => 'PLUGIN_XIMALAYA_ERR_RISK',
		todo     => 'PLUGIN_XIMALAYA_CAT_TODO',
		nonjson  => 'PLUGIN_XIMALAYA_ERR_API',
		noperm   => 'PLUGIN_XIMALAYA_ERR_NOPERM',
		nourl    => 'PLUGIN_XIMALAYA_ERR_API',
		empty    => 'PLUGIN_XIMALAYA_ERR_API',
	);

	my $name;
	if ($code && $token{$code}) {
		$name = cstring($client, $token{$code});
	}
	elsif ($code && $code =~ /hdaa/) {
		$name = cstring($client, 'PLUGIN_XIMALAYA_ERR_SIGN');
	}
	else {
		$name = cstring($client, 'PLUGIN_XIMALAYA_ERR_API') . " ($code)";
	}

	return { name => $name, type => 'text' };
}

1;

__END__

=head1 NAME

Plugins::Ximalaya::Plugin - Ximalaya online audio for LMS / Daphile

=head1 SEE ALSO

M0/M1 research: _research/ximalaya-daphile-plugin/

=cut
