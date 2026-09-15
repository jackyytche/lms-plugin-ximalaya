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

sub albumItem {
	my ($album) = @_;
	my $name = $album->{title} // "Album $album->{id}";
	$name .= " - $album->{announcer}" if $album->{announcer};
	$name .= ' [VIP]' if $album->{paid};

	# 0.1.28: native favourite support. The web UI (Slim::Web::XMLBrowser)
	# renders an add/remove favourites action for any item carrying a
	# favorites_url and flags it as already-starred (favorites=2) via
	# Favorites->hasUrl. Starred entries land in LMS Favourites as
	# xmly://album/<id> links; myAlbumsHandler merges them back into the
	# my-albums list. One place here covers EVERY album entry point
	# (search, ranks, catalog browse, my albums itself).
	return {
		name        => $name,
		image       => $album->{cover},
		type        => 'link',
		url         => \&albumHandler,
		passthrough => [ $album->{id} ],
		favorites_url   => "xmly://album/$album->{id}",
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
		favorites_url   => "xmly://album/$id",
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

		$cb->({
			items  => \@items,
			offset => $offset,
			(defined $total ? (total => $total) : ()),
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
			next unless (($fi->{url} || '') =~ m{^xmly://album/(\d+)});
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
