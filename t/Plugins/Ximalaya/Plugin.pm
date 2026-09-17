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

	# 0.1.45: dual-write album favourites. The LMS/Daphile favourites list
	# stays the primary store (albumfeed.html?album=N entries, 0.1.29); on
	# EVERY favourites change we also sync ALBUM entries into the plugin
	# pref 'albums', so a starred album lives in "my albums" independently
	# of the favourites list. Track favourites (xmly://track/<id>) never
	# match the album URL shapes and stay out of my albums - user
	# requirement. subscribe() carries no dispatch-registration check, so
	# load order against the Favorites plugin does not matter.
	require Slim::Control::Request;
	Slim::Control::Request::subscribe(
		\&_on_favorites_changed,
		[ ['favorites'], ['changed'] ],
	);

	return;
}

# ------------------------------------------------------------------ top menu

# 0.1.38: Daphile's PRE-PLAY page (the big-artwork page that opens when a
# track or a TuneIn station is tapped, with Play/Add buttons) is rendered
# from the item's CONTEXT MENU response - and only for the full tile shape
# Slim::Menu::TrackInfo emits: {type:'text', addAction:'go',
# style:item_add|item_insert|itemplay|item_fav, actions carrying go+play+add
# aliases}. The default XMLBrowser CM fork emits a bare {actions:{go}} shape
# which Daphile paints WITHOUT buttons (verified on-device: local library
# tracks get buttons, our tracks did not). itemActions.info on the rows
# routes the CM request here (plain 'ximalaya items' query with cm*
# params), and we answer with the working tile shape bound to plain
# playlist commands on the xmly:// URLs - album URLs hit
# ProtocolHandler::explodePlaylist, so the album page's Play button queues
# the whole album. Strings and shapes mirror Slim::Menu::TrackInfo /
# XMLBrowser::_playlistControlContextMenu exactly.
sub _cm_action {
	my ($cmd, $nextWindow) = @_;
	return {
		player     => 0,
		cmd        => $cmd,
		nextWindow => $nextWindow,
	};
}

sub _cm_items {
	my ($client, $args) = @_;
	my $url    = $args->{url};
	my $title  = $args->{title}  || 'Ximalaya';
	my $icon   = $args->{icon}   || '';
	my $favUrl = $args->{favUrl} || $url;

	$title =~ s/[\r\n]+/ /g if defined $title;

	my @items;

	for my $tile (
		[ 'ADD_TO_END', 'add',    'add',    [ 'playlist', 'add',    $url ], 'parent'     ],
		[ 'PLAY_NEXT',  'insert', 'insert', [ 'playlist', 'insert', $url ], 'parent'     ],
		[ 'PLAY',       'play',   'play',   [ 'playlist', 'play',   $url ], 'nowPlaying' ],
	) {
		my ($token, $method, $playcontrol, $cmd, $nextWindow) = @$tile;
		my $action = _cm_action($cmd, $nextWindow);
		my $jive = { actions => { $method => $action, play => $action, go => $action } };
		$jive->{style} = 'itemplay' if $playcontrol eq 'play';
		push @items, {
			type        => 'text',
			name        => cstring($client, $token),
			playcontrol => $playcontrol,
			jive        => $jive,
		};
	}

	my %favParams = (
		title         => $title,
		url           => $favUrl,
		type          => 'audio',
		isContextMenu => 1,
	);
	$favParams{icon} = $icon if $icon;
	push @items, {
		type => 'text',
		name => cstring($client, 'JIVE_SAVE_TO_FAVORITES'),
		jive => {
			style   => 'item_fav',
			actions => {
				go => {
					player => 0,
					cmd    => [ 'jivefavorites', 'add' ],
					params => \%favParams,
				},
			},
		},
	};

	# 0.1.39: album context menu gains a descend tile so the big-artwork page
	# is a complete landing spot: play/add/insert the whole album, browse the
	# track list, save to favourites.
	if (my $browse = $args->{browse}) {
		push @items, {
			type => 'text',
			name => cstring($client, 'PLUGIN_XIMALAYA_BROWSE_TRACKS'),
			jive => {
				actions => {
				go => {
					player => 0,
					cmd    => [ 'ximalaya', 'items' ],
					params => {
						menu           => 'ximalaya',
						cmBrowseAlbum  => $browse,
						cmBrowseTitle  => ( $args->{title}  // '' ),
						cmBrowseAuthor => ( $args->{author} // '' ),
						cmBrowseIcon   => ( $args->{icon}   // '' ),
					},
				},
				},
			},
		};
	}

	return \@items;
}

# 0.1.38: the CM requests carry the tile payload as plain named params (the
# itemActions fixedParams are baked per item at build time - XMLBrowser only
# forwards fixedParams for the 'info' action, no per-item variables).
sub _cm_feed_items {
	my ($client, $params) = @_;

	if (my $cmTrack = $params->{cmTrack}) {
		return _cm_items($client, {
			url   => 'xmly://track/' . $cmTrack,
			title => $params->{cmTitle},
			icon  => $params->{cmIcon},
		});
	}

	if (my $cmAlbum = $params->{cmAlbum}) {
		return _cm_items($client, {
			url    => 'xmly://album/' . $cmAlbum,
			title  => $params->{cmTitle},
			icon   => $params->{cmIcon},
			favUrl => _albumFeedUrl($cmAlbum),
			browse => $cmAlbum,
			author => ( $params->{cmAuthor} // '' ),
		});
	}

	return;
}

# 0.1.7 order: browse entries first, tools next, status last
sub handleFeed {
	my ($client, $cb, $params, $args) = @_;

	# 0.1.39/0.1.41: "Browse tracks" tile in the album context menu - descends
	# into the album's track list carrying title/author for the songinfo
	# header.
	if (my $cmBrowse = $params->{cmBrowseAlbum}) {
		albumHandler($client, $cb, $params, $cmBrowse,
			( $params->{cmBrowseTitle}  // '' ),
			( $params->{cmBrowseAuthor} // '' ),
			( $params->{cmBrowseIcon}   // '' ));
		return;
	}

	# 0.1.38: context-menu requests (itemActions.info from the rows) - no
	# API traffic, straight tile list.
	if (my $items = _cm_feed_items($client, $params)) {
		$cb->({ items => $items });
		return;
	}

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
	#
	# 0.1.36: the jive escape hatch (Slim::Control::XMLBrowser copies
	# item->{jive}->{window} verbatim into the jive item hash) lets the row
	# ask the UI to open the album page as an ALBUM-styled window
	# (SlimBrowser _newWindowSpec: item.window.menuStyle 'album' = the same
	# menu style the local album view / current-playlist album list use).
	# Daphile skins decide what chrome they paint for that style.
	#
	# 0.1.37: on_select=play makes the row a TOUCH-TO-PLAY item (XMLBrowser
	# touchToPlay(): type audio OR on_select=play -> the item's jive params
	# carry touchToPlay, exactly like TuneIn station rows). Daphile renders
	# those with its big-artwork play/add page - the same page a radio
	# station gets - and the page's play button runs this row's play url
	# (xmly://album/<id> -> explodePlaylist = the whole album). The descend
	# action stays in the protocol, so the track list remains reachable
	# through the row's context menu ("more"). Track rows already carry
	# touchToPlay (type=audio) - tapping a track shows the same style of
	# preview for the single track.
	return {
		name        => $name,
		image       => $album->{cover},
		type        => 'link',
		url         => \&albumHandler,
		# 0.1.41: passthrough now carries TITLE and ANNOUNCER past the id -
		# the web UI invokes coderefs as handler($client,$cb,\%args,@pt)
		# (Slim::Web::XMLBrowser L517), and albumHandler folds them into the
		# songinfo header (albumData labels), giving the album page the
		# local-library layout: big artwork LEFT, buttons RIGHT.
		# 0.1.42: plus the ALBUM cover - the track list API's per-track
		# covers come in mixed size tiers (some _T87x87), while the album
		# list cover (what my-albums rows show, the "originally crisp" one)
		# is the better source for the page header.
		passthrough => [
			$album->{id},
			($album->{title}     // ''),
			($album->{announcer} // ''),
			($album->{cover}     // ''),
		],
		play            => 'xmly://album/' . $album->{id},
		on_select       => 'play',
		favorites_url   => _albumFeedUrl($album->{id}),
		favorites_title => $name,
		favorites_type  => 'link',
		jive => {
			window => {
				menuStyle => 'album',
				'icon-id' => $album->{cover},
			},
		},
		# 0.1.38: Daphile's pre-play page (big artwork + Play/Add) reads its
		# buttons from the row's context menu; route it to our own tile list
		# (handleFeed cmAlbum branch) in the TrackInfo shape that page
		# renders. Play = whole album via explodePlaylist.
		itemActions => {
			info => {
				command     => [ 'ximalaya', 'items' ],
				fixedParams => {
					menu     => 1,
					cmAlbum  => $album->{id},
					cmTitle  => $name,
					cmIcon   => $album->{cover} || '',
					cmAuthor => ( $album->{announcer} // '' ),
				},
			},
		},
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
	# 0.1.41: @passthrough is (id, title, announcer) - albumItem widens it so
	# the WEB songinfo header can label the album (the local-library layout).
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
	my ($client, $cb, $args, $albumId, $albumTitle, $albumAuthor, $albumCover) = @_;
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
		# 0.1.42: header artwork source - album cover first, track cover as
		# the fallback (both upscaled by _cover_large below).
		my $headerCover = $albumCover || ($tracks->[0] && $tracks->[0]{cover});

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
			# 0.1.40: feed-level image = the artwork at the top of the WEB
			# page (Slim::Web::XMLBrowser L594 stash image -> template
			# xmlbrowser.html L302). This is the "album cover at the top of
			# the list page" the local album pages show.
			# 0.1.42: source priority = the ALBUM cover passed through from
			# the album row (the consistently-sized source the my-albums
			# rows show), falling back to the first track's cover; both are
			# upscaled via _cover_large, because the track list API hands
			# out mixed size tiers (_T87x87/_T250x250) and the header
			# renders whatever it gets.
			($headerCover
				? (image => Plugins::Ximalaya::API->_cover_large($headerCover))
				: ()),
			# 0.1.41: SONGINFO HEADER - the local-album-page layout (big art
			# LEFT, buttons RIGHT). Trigger pieces, per Slim::Web::XMLBrowser:
			#   play      -> stash playUrl (L564) -> details playLink/addLink
			#                (L976-985) = playlist play/add xmly://album/N,
			#                i.e. the WHOLE album via explodePlaylist;
			#   albumData -> L861 folds labelled rows into the header details
			#                WITHOUT touching the track list (ALBUM = title,
			#                ARTIST = announcer);
			#   with songinfo set the template's ALL_SONGS row is suppressed
			#   (xmlbrowser.html L314) - no more button-row below the art.
			# 0.1.35: feed-level actions become the level's BASE actions
			# (Slim::Control::XMLBrowser menuMode: _makeAction($feedActions,
			# 'play'|'add'|'insert')) - the UI renders them as the HEADER
			# play/add buttons next to the album image, exactly like a local
			# album page. Each command plays/adds the WHOLE album through
			# ProtocolHandler::explodePlaylist (same URL as the album row).
			($albumId =~ /^\d+$/
				? (actions => _album_play_actions($albumId))
				: ()),
			# 0.1.41: the songinfo trigger pair - see the block above.
			(( $albumId =~ /^\d+$/ )
				? ( play => 'xmly://album/' . $albumId )
				: ()),
			(( $albumId =~ /^\d+$/ && ( $albumTitle || $albumAuthor ) )
				? ( albumData => [
						( $albumTitle
							? ( { name => $albumTitle, type => 'text', label => 'ALBUM' } )
							: () ),
						( $albumAuthor
							? ( { name => $albumAuthor, type => 'text', label => 'ARTIST' } )
							: () ),
					] )
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
		# 0.1.40: a DEFINED duration flips Slim::Web::XMLBrowser's
		# itemsHaveAudio (L764-771) - the web UI (Daphile's device screen)
		# then renders the play-all/add-all controls on the album page.
		(defined $t->{duration} ? (duration => $t->{duration}) : ()),
		# 0.1.39: EXPLICIT single-track play/add/insert actions on the row.
		# Without these, Daphile's row buttons fall back to the page-level
		# base actions (0.1.35's whole-album commands) - so the row's play
		# button queued the WHOLE album instead of the clicked track.
		# itemActions.play also re-binds actions.go (XMLBrowser L1306-1308,
		# goAction is 'play' here), so tapping the row plays just that track.
		itemActions => {
			info   => {
				command     => [ 'ximalaya', 'items' ],
				fixedParams => {
					menu    => 1,
					cmTrack => $t->{id},
					cmTitle => $t->{title},
					cmIcon  => $t->{cover} || '',
				},
			},
			play   => { command => [ 'playlist', 'play',   "xmly://$t->{id}" ], fixedParams => {} },
			add    => { command => [ 'playlist', 'add',    "xmly://$t->{id}" ], fixedParams => {} },
			insert => { command => [ 'playlist', 'insert', "xmly://$t->{id}" ], fixedParams => {} },
		},
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
		# 0.1.40: ONLY the *all actions remain at feed level. The plain
		# play/add keys are GONE - on the web UI (which is what the device
		# screen runs) Slim::Web::XMLBrowser::_makePlayLink resolves every
		# ROW's play/add link feed-first (findAction), so the 0.1.35-0.1.39
		# whole-album play/add commands were stamped onto EVERY track row:
		# the row play button played the WHOLE album. With them removed the
		# row links fall back to the item's own play URL (single track),
		# while playall/addall stay for the page-level controls:
		# action=playall at the lowest level executes the feed action
		# DIRECTLY (XMLBrowser.pm L361-392) - whole album via
		# explodePlaylist, immune to the 50-row page window.
		playall => {
			command     => [ 'playlist', 'play',   'xmly://album/' . $albumId ],
			fixedParams => {},
		},
		addall => {
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
# "page 2 shows nothing but next page"). Width = itemsPerPage - 2 (room
# for the next-page row AND the jump-to-page row; the play-all slot that
# 0.1.33/0.1.43 reserved is gone since 0.1.44 - the shell header's own
# play button plays the album), capped at PC_SHOW_MAX (the API page
# width). itemsPerPage is the same server preference the UI uses
# (pageInfo falls back to preferences('server')->get('itemsPerPage');
# Daphile default 50).
sub _feed_page_width {
	my $pp = eval { preferences('server')->get('itemsPerPage') };
	$pp = 50 unless $pp && $pp =~ /^\d+$/ && $pp >= 4;    # garbage/tiny -> Daphile default
	$pp = 500 if $pp > 500;                               # paranoia clamp
	my $w = $pp - 2;
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
	# In-shell chrome budget: 2 slots for the ALBUM/ARTIST label rows
	# (labels appear whenever album/simple succeeds); the whole shell
	# content - labels + tracks + next + jump - must stay within ONE ui
	# page. The same width feeds the pages-layer ceil math. (0.1.43
	# reserved a third slot for the leading play-all row - removed in
	# 0.1.44, the shell row's own header play button plays the album.)
	my $width = _feed_page_width() - 2;

	my $finish = sub {
		my ($items, $meta, $wrap) = @_;

		my @rows;
		# 0.1.43: songinfo header labels for the favourites path. The OPML
		# channel CANNOT carry feed-level play/image/albumData (Slim::Formats::
		# XML::parseOPML keeps only type/title/items/... at feed level), but
		# outline ATTRIBUTES all survive (Slim/Formats/XML.pm L625-641) and
		# Slim::Web::XMLBrowser folds labelled rows into the songinfo header
		# (L861). Deliberately NO itemsHaveAudio trigger here (no duration/
		# playall attributes): the header's allcontrol would collect every
		# audio row url of the visible page (XMLBrowser.pm L663-725) and
		# re-queue the exploded album PLUS the page's tracks - a duplicate
		# mess. Per-row play/add buttons and the play-whole-album row keep
		# working (row-level _makePlayLink falls back to the item url).
		if ($meta) {
			push @rows, '<outline text="' . _xml_escape($meta->{title})
				. '" type="text" label="ALBUM"/>'
				if ($meta->{title} // '') ne '';
			push @rows, '<outline text="' . _xml_escape($meta->{announcer})
				. '" type="text" label="ARTIST"/>'
				if ($meta->{announcer} // '') ne '';
		}

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
			. '</title></head><body>' . "\n";

		# 0.1.43: wrap everything in ONE nested playlist outline. Feed-level
		# keys are impossible on the OPML channel (parseOPML keeps only
		# type/title/items/...), but ITEM attributes all survive - and when
		# the shell row is clicked it BECOMES the subfeed
		# (Slim::Web::XMLBrowser: subFeed has items -> normal list at
		# L539-552; playUrl = subFeed->'play' at L564 -> songinfo play/add
		# links = whole album; stash image = subFeed->'image' at L594 ->
		# header artwork). The shell row itself shows the cover and a
		# row-level play button (play = xmly://album -> explodePlaylist), so
		# the first hop doubles as an album card. This is exactly how the
		# stock radio plugins (AudioAddict -> jazzradio.com etc.) nest their
		# channel lists - the user's reference page is the same two-hop
		# shape.
		if ($albumId && $wrap) {
			my $shellName = ($meta && ($meta->{title} // '') ne '')
				? _xml_escape($meta->{title})
				: 'Ximalaya album ' . _xml_escape($albumId);
			my $shellImg = ($meta && ($meta->{cover} // '') ne '')
				? ' image="' . _xml_escape(Plugins::Ximalaya::API->_cover_large($meta->{cover})) . '"'
				: '';
			$body .= '<outline text="' . $shellName . '" type="playlist" play="'
				. _xml_escape('xmly://album/' . $albumId) . '"' . $shellImg . '>' . "\n"
				. (@rows ? join("\n", @rows) . "\n" : '')
				. '</outline>' . "\n";
		}
		elsif (@rows) {
			$body .= join("\n", @rows) . "\n";
		}

		$body .= '</body></opml>';

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
		$finish->(\@items, undef, 0);
		return;
	}

	# 0.1.43: album meta for the songinfo header labels, fetched BEFORE the
	# track feed (the handler is already asynchronous - this just adds one
	# more async hop). A failed/unavailable album/simple call degrades to
	# undef -> the page renders exactly as before (bare track list).
	my $run = sub {
		my ($meta) = @_;

		Plugins::Ximalaya::Plugin::albumHandler($client,
			sub {
				my ($feed) = @_;
				my $items = $feed->{items} || [];
				my $total = $feed->{total};
				my $have  = ($feed->{offset} || 0) + scalar @$items;
				my ($cover) = map { $_->{image} || () } @$items;
				# Navigation rows. 0.1.44: the leading play-whole-album row
				# is GONE - the shell row's own play (songinfo header play
				# button = whole album) already covers it, and the user
				# asked for the redundant row to go. Next-page and
				# jump-to-page close the page; they reuse the first cover
				# of this batch so they do not render bare in cover-aware
				# skins. The jump row embeds the server total into its URL
				# (mode=pages layer above) so flipping to it costs zero API
				# calls.
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
				$finish->($items, $meta, 1);
			},
			# no_play_row: the menu track list keeps its trailing play-all
			# row (+1 total); this feed never renders it - since 0.1.44 it
			# has NO play-all row at all (the shell header plays the album)
			{ quantity => $width, index => ($page - 1) * $width, no_play_row => 1 },
			$albumId,
		);
	};

	Plugins::Ximalaya::API->albumInfo($albumId, $run, sub { $run->(undef) });

	return;
}

# --------------------------------------------------------------- my albums

# 0.1.45: the album URL shapes recognised across favourites handling -
# the 0.1.29 starred-feed URL (albumfeed.html?album=N) and the 0.1.28
# legacy bookmark (xmly://album/N). Returns the album id or undef.
# Track URLs (xmly://track/<id>) deliberately do NOT match - single
# episodes never enter "my albums" (user requirement).
sub _album_id_from_url {
	my ($u) = @_;
	return undef unless defined $u;
	if ($u =~ m{^xmly://album/(\d+)}) {
		return $1;
	}
	if ($u =~ m{albumfeed\.html\?album=(\d+)}) {
		return $1;
	}
	return undef;
}

# 0.1.45: dual-write favourites sync. Fired (via the request notification
# queue - async, next idle loop) whenever the LMS favourites list was
# saved: Slim::Plugin::Favorites::OpmlFavorites::save fires
# ['favorites','changed'] on every add AND delete, whatever UI path issued
# it (web favadd/favdel action L1002-1024, jive tile, CLI). We scan the
# favourites (OpmlFavorites::all is recursive, folders included) and
# append every ALBUM id missing from the pref 'albums'. Deleting a
# favourite does NOT remove it from the pref: "my albums" is the plugin's
# own persistent list (editable in settings), Daphile's favourites is the
# other, independent copy. Errors degrade silently (no favorites module ->
# no sync, same policy as the myAlbums merge).
sub _on_favorites_changed {
	my $favs = eval {
		require Slim::Utils::Favorites;
		Slim::Utils::Favorites->new(undef);    # client ignored by the store
	};
	return unless $favs;

	my $items = eval { $favs->all } || [];

	my $raw   = $prefs->get('albums') || '';
	my @ids   = grep { /^\d+$/ } split /[\s,;]+/, $raw;
	my %seen  = map { $_ => 1 } @ids;
	my $added = 0;

	for my $fi (@$items) {
		my $id = _album_id_from_url($fi->{url});
		next unless defined $id;
		next if $seen{$id}++;
		push @ids, $id;
		$added++;
	}

	return unless $added;

	$prefs->set('albums', join("\n", @ids));
	$log->info("Ximalaya: $added album(s) favourited -> synced into my albums");

	return;
}

sub myAlbumsHandler {
	my ($client, $cb, $args) = @_;

	# 0.1.28: two sources, merged. (1) the plugin pref 'albums' (editable in
	# settings, order preserved) and (2) albums the user starred with the
	# web UI's native favourites action - those are stored in LMS Favourites
	# as xmly://album/<id> links (see albumItem). Dedup with the pref list
	# first. A missing/unreadable Favorites module degrades silently to the
	# pref-only list.
	# 0.1.45: starring ALSO writes into the pref (_on_favorites_changed), so
	# this merge is a safety net for entries starred before 0.1.45 and for
	# the window between the favourites save and the async notification.
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
			my $id = _album_id_from_url($fi->{url});
			next unless defined $id;
			push @ids, $id unless $seen{$id}++;
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
