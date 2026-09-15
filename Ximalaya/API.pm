# Plugins::Ximalaya::API
#
# Async wrappers around the Ximalaya web endpoints used by the plugin.
# All requests are non-blocking (Slim::Networking::SimpleAsyncHTTP).
#
# Endpoint semantics verified in M0 (see _research/ximalaya-daphile-plugin/m0/):
#   - xm-sign must be generated FRESH per request (single-use / short TTL)
#   - baseInfo requires a login cookie even for free tracks (ret=1001 otherwise)
#   - getTracksList needs xm-sign (407 "webtk missing" without it); soft risk
#     control may return ret=200 with an empty list and riskLevel set
#   - ret=0 (baseInfo) / ret=200 (list, simple) mean success
#   - ret=1001 anonymous/risk-control; 927/3005 no permission
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License, version 2.

package Plugins::Ximalaya::API;

use strict;
use warnings;

use JSON::XS::VersionOneAndTwo;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Time::HiRes qw(time);
use URI::Escape qw(uri_escape_utf8);

use Plugins::Ximalaya::Sign;
use Plugins::Ximalaya::XimaCrypt;

my $log = logger('plugin.ximalaya');
my $prefs = preferences('plugin.ximalaya');

use constant BASE        => 'https://www.ximalaya.com';
use constant TRACKS_LIST => BASE . '/revision/album/v1/getTracksList';
use constant ALBUM_SIMPLE => BASE . '/revision/album/v1/simple';
use constant SEARCH_MAIN => BASE . '/revision/search/main';
use constant BASE_INFO   => BASE . '/mobile-playpage/track/v3/baseInfo';

# ----------------------------------------------------- m (mobile web) channel
# 0.1.27: the m.ximalaya.com revision API - a THIRD web surface with its own
# risk-control domain. VERIFIED 2026-09-13 (m0/diag_msearch_probe3.py):
# /m-revision/page/search answers ret=0 with REAL results when called with
# the user 1&_token cookie AND a fresh xm-sign header ("webtk" is just the
# du_web_sdk xm-sign - see HANDOFF §2.7). Anonymous -> ret 303 needLogin;
# token without xm-sign -> ret=0 BUT isIllegal:true + empty views + advice
# filler (SOFT failure - parsers must check isIllegal explicitly).
use constant M_BASE   => 'https://m.ximalaya.com';
use constant M_SEARCH => M_BASE . '/m-revision/page/search';
use constant M_SEARCH_ROWS => 20;  # server page width (rows=5 still gave 20)

# mobile UA for the m channel - the shape the successful probes used
my $MOBILE_UA = 'Mozilla/5.0 (Linux; Android 13; M2102J2SC) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36';

# ------------------------------------------------------------- pc channel
# Desktop-client protocol (0.1.12). Blueprint verified 2026-09-10 with real
# probes (m0/pc_*.json, trackquality_1012852891.json; 调研文档 §9 is the
# authority). Independent risk-control domain from the web endpoints.
use constant PC_BASE      => 'https://pc.ximalaya.com';
use constant PC_SHOW      => PC_BASE . '/simple-revision-for-pc/play/v1/show';
use constant PC_PAGE_SIZE => 30;   # show default page size (when size omitted)
use constant PC_SHOW_MAX  => 50;   # VERIFIED 2026-09-10: size=50 honored
                                   # (pageSize echoes 50, clean num=2
                                   # continuation); size=100 clamps to 30.
use constant PC_RANK_TABS    => PC_BASE . '/simple-revision-for-pc/rank/v4/rankTabs';
use constant PC_RANK_ELEMENT => PC_BASE . '/simple-revision-for-pc/rank/v4/element';
use constant TRACK_QUALITY =>
	'https://mobile.ximalaya.com/mobile-playpage/playpage/track/quality';
# mobile album track list. VERIFIED 2026-09-10: serves PAID/VIP albums with
# the EXACT data.totalCount (1388 for 83701277), pageSize echo, clean p1/p2
# continuation and per-track isPaid; free albums return a tiny empty reply
# (ret=0, list=[]) - they must go to the pc show path instead. Same domain
# as track/quality (zero risk-control so far).
use constant MOBILE_TRACKS =>
	'https://mobile.ximalaya.com/mobile/v1/album/track';

# Master switch for the pc channel. Package VARIABLE (not a constant) so the
# offline stub test can localize it; the user-facing pref 'pc_channel'
# (settings page) is AND-ed on top by pc_enabled().
our $PC_CHANNEL_ENABLED = 1;

# pc track/quality exposes PLAINTEXT playPathDto URLs. Field->tier mapping
# VERIFIED 2026-09-10 (§9.1): playPathAacV224 is M4A_24 (24kbps!), NOT 224k.
# No quality leap vs web - the pc channel's value is plaintext URLs, an
# independent risk domain, and the device=win fallback for VIP.
# 0.1.18: originPlayPath added for the "lossless/highest" tier - free tracks
# expose it as a FULL plaintext URL (same aod.cos CDN as the play paths;
# probe-verified). VIP tracks expose only a bare storages path there (not
# playable) - the http check in _parse_track_quality drops those.
# downloadPath stays unmapped (download-only 302 targets, same reasons as
# the reference downloader).
my %PC_PLAY_FIELDS = (
	originPlayPath => 'ORIGIN',
	playPathHq      => 'MP3_128',
	playPathAacV164 => 'M4A_64',
	playPath64      => 'MP3_64',
	playPathAacV224 => 'M4A_24',
	playPath32      => 'MP3_32',
);

# 0.1.24: playPathDto carries a byte size per tier (fixture qualityFree:
# originSize/hqSize/aacV164Size/mp364Size/aacV224Size/mp332Size; 0 = tier
# absent). Mapped to the SAME tier keys as %PC_PLAY_FIELDS so _resolvePC can
# publish the real bitrate (size*8/duration) exactly like the win chain does
# with playUrlList fileSize.
my %PC_SIZE_FIELDS = (
	originSize  => 'ORIGIN',
	hqSize      => 'MP3_128',
	aacV164Size => 'M4A_64',
	mp364Size   => 'MP3_64',
	aacV224Size => 'M4A_24',
	mp332Size   => 'MP3_32',
);

# Quality preference (pref 'quality') -> preferred pc tier order. Tier names
# match the playPathDto mapping above (and the win playUrlList "type" field).
# 0.1.18: new 256 tier ("lossless / highest", borrowed from the PC client's
# own quality ladder STANDARD=24/HDMI=64/ULTRA=128/LOSSLESS=256 - asar
# probe): for FREE tracks the highest really available source is the
# original upload (ORIGIN), for paid/VIP tracks it is the 128k tier unless
# the account+content carry lossless entitlement.
my %PC_QUALITY_ORDER = (
	256 => [qw(ORIGIN MP3_128 M4A_64 MP3_64 M4A_24 MP3_32)],
	128 => [qw(MP3_128 M4A_64 MP3_64 M4A_24 MP3_32)],
	64  => [qw(M4A_64 MP3_64 MP3_128 M4A_24 MP3_32)],
	32  => [qw(MP3_32 M4A_24 MP3_64 M4A_64 MP3_128)],
);

# Quality preference (pref 'quality': 256|128|64|32) -> try these playUrlList
# types. Type names VERIFIED 2026-09-09 against real baseInfo replies (free +
# VIP); 0.1.18: M4A_128 verified on the WIN endpoint (playUrlList qualityLevel
# 2, probe diag_baseinfo_levels.py). The web www2 endpoint's ceiling is
# 128k ("128KMP3"). Available tiers vary with the content source.
my %QUALITY_ORDER = (
	256 => [qw(M4A_128 128KMP3 M4A_64 MP3_64 M4A_24 MP3_32 AAC_24)],
	128 => [qw(M4A_128 128KMP3 M4A_64 MP3_64 M4A_24 MP3_32 AAC_24)],
	64  => [qw(M4A_64 MP3_64 M4A_128 128KMP3 M4A_24 MP3_32 AAC_24)],
	32  => [qw(MP3_32 M4A_24 AAC_24 MP3_64 M4A_64 M4A_128 128KMP3)],
);

# pref quality -> baseInfo trackQualityLevel (PC client ladder, asar
# STANDARD=24/HDMI=64/ULTRA=128/LOSSLESS=256). Probe 2026-09-10: level
# controls which tiers playUrlList carries (level 2 adds M4A_128); level 3
# (lossless) is entitlement-gated (ret 1001) and needs a one-step fallback.
my %WIN_LEVEL = (32 => 0, 64 => 1, 128 => 2, 256 => 3);

my $UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';

# ------------------------------------------------------------------- helpers

sub _cookie {
	my $c = $prefs->get('cookie') || '';
	$c =~ s/^\s+|\s+$//g;
	$c =~ s/\r?\n/ /g;    # pasted multi-line: keep on one header line
	return $c;
}

sub logged_in {
	my ($class) = @_;
	return _cookie() =~ /1&_token=/ ? 1 : 0;
}

sub _base_headers {
	my ($class, %extra) = @_;
	my %h = (
		'Accept'          => 'application/json, text/plain, */*',
		'Accept-Language' => 'zh-CN,zh;q=0.9,en;q=0.8',
		'User-Agent'      => $UA,
		%extra,
	);
	# caller-supplied Cookie (pc channel win fallback appends the device
	# triple) wins over the bare web cookie
	my $cookie = _cookie();
	$h{'Cookie'} = $cookie if $cookie && !$h{'Cookie'};
	return \%h;
}

# normalize cover references to absolute https URLs. Every shape occurs in
# the wild: protocol-relative ("//imagev2.xmcdn.com/..."), bare storages
# paths ("storages/..."), http:// and https:// URLs. 0.1.24: album/simple
# hands out a protocol-relative cover (probe m0/diag_album_cover.py, real
# reply for 83701277) and albumInfo passed it through raw - Daphile's cover
# render crashed on it ("my albums" covers broken since the beginning; the
# per-parser copies of this logic also disagreed, e.g. the track/quality
# meta cover stayed a bare path so free-track now-playing artwork could
# never load). All parsers funnel through this single helper now.
sub _norm_cover {
	my ($class, $c) = @_;
	return '' unless defined $c && length $c;
	$c =~ s{^//}{https://};
	$c = 'https://imagev2.xmcdn.com/' . $c if $c !~ m{^https?://};
	$c =~ s{^http://}{https://};
	return $c;
}

# ------------------------------------------------------------------ pc helpers

# self-made device id for the pc channel (调研文档 §9.3): a UUID4-style id
# shared by install_id and 1&_device. PERSISTED in pref 'pc_device_id' -
# a new id per request would look like device churn to the server.
sub _uuid_v4 {
	my @h = map { sprintf('%02x', int(rand(256))) } (1 .. 16);
	substr($h[6], 0, 1) = '4';                                       # version 4
	substr($h[8], 0, 1) = sprintf('%x', 8 + (hex(substr($h[8], 0, 1)) % 4)); # variant 10xx
	# 16 bytes -> 8-4-4-4-12: bytes 0-3 / 4-5 / 6-7 / 8-9 / 10-15
	return sprintf('%s%s%s%s-%s%s-%s%s-%s%s-%s',
		@h[0 .. 3], @h[4 .. 5], @h[6 .. 7], @h[8 .. 9], join('', @h[10 .. 15]));
}

sub _pc_device_cookie {
	my ($class) = @_;

	my $uuid = $prefs->get('pc_device_id') || '';
	unless ($uuid =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/) {
		$uuid = _uuid_v4();
		$prefs->set('pc_device_id', $uuid);
		$log->debug("Ximalaya: pc device id generated and persisted");
	}

	# format VERIFIED 2026-09-10 (diag_pc_channel4 / downloader cookies.py):
	# channel=99&100001 (client 4.0.14), 1&_device=win32&<same uuid>&4.0.14
	return "install_id=$uuid; channel=99&100001; 1&_device=win32&$uuid&4.0.14";
}

# pc channel on? = package master switch AND user pref (default on).
sub pc_enabled {
	my ($class) = @_;
	return ($PC_CHANNEL_ENABLED && ($prefs->get('pc_channel') ? 1 : 0)) ? 1 : 0;
}

# Mobile album-list channel (0.1.17): the mobile-domain track list is a
# pc-family endpoint (same trust domain as play/v1/show), so it is gated
# by the pc master switch AND its own pref. Off = paid albums fall
# straight through to the pc show list (hasMore-estimated totals).
sub mobile_enabled {
	my ($class) = @_;
	return 0 unless $class->pc_enabled();
	return ($prefs->get('mobile_channel') ? 1 : 0) ? 1 : 0;
}

# headers for pc.ximalaya.com: web cookie + device triple, client-like
# Referer/Origin. xm-sign added per-call (real Sign.pm - the PC client sends
# the same hdaa-derived signature, §9.2).
sub _pc_headers {
	my ($class, $referer) = @_;

	my $cookie = _cookie();
	$cookie .= '; ' if $cookie;
	$cookie .= $class->_pc_device_cookie;

	return {
		'Accept'          => 'application/json, text/plain, */*',
		'Accept-Language' => 'zh-CN,zh;q=0.9,en;q=0.8',
		'User-Agent'      => $UA,
		'Referer'         => $referer,
		'Origin'          => PC_BASE,
		'Cookie'          => $cookie,
	};
}

# GET $url -> JSON, cb->($data), ecb->($errmsg, $http)
sub _json_get {
	my ($class, $url, $headers, $cb, $ecb, $cache_expires) = @_;

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my ($http) = @_;
			my $data = eval { from_json($http->content) };
			if ($@ || !$data) {
				my $snippet = substr($http->content || '', 0, 120);
				$log->error("Ximalaya: non-JSON response for $url: $snippet");
				$ecb->('nonjson', $http);
				return;
			}
			$cb->($data);
		},
		sub {
			my ($http, $error) = @_;
			my $resp = eval { $http->response } || '';
			my $server  = eval { $resp->header('Server') }  || '';
			my $ctype   = eval { $resp->header('Content-Type') } || '';
			my $snippet = eval { substr($http->content || '', 0, 160) } || '';
			$log->error("Ximalaya: request failed for $url: $error | Server=$server CT=$ctype body=$snippet");
			$ecb->($error, $http);
		},
		{
			timeout => 15,
			($cache_expires ? (cache => 1, expires => $cache_expires) : ()),
		},
	)->get($url, %{ $headers });

	return;
}

# Map an endpoint reply to (undef, $errcode) on failure
sub _check_ret {
	my ($class, $data) = @_;
	my $ret = $data->{ret};
	return undef if defined $ret && ($ret == 0 || $ret == 200);
	my $code = defined $ret ? $ret : 'http';
	return $code;
}

# ------------------------------------------------------------------- album

# $class->albumInfo($albumId, $cb, $ecb)
#   cb->( { id, title, cover, announcer, tracksCount, paid, finished } )
sub albumInfo {
	my ($class, $albumId, $cb, $ecb) = @_;

	$class->_json_get(
		ALBUM_SIMPLE . '?albumId=' . uri_escape_utf8($albumId),
		$class->_base_headers('Referer' => BASE . "/album/$albumId"),
		sub {
			my ($data) = @_;
			if (my $code = $class->_check_ret($data)) {
				$ecb->($code);
				return;
			}
			my $info = eval { $data->{data}{albumPageMainInfo} } || {};
			# 0.1.24: cover MUST be absolutized (protocol-relative in the real
			# reply -> broke my-albums covers); anchorName is the real announcer
			# field (probe 2026-09-11) - announcerName/nickname never matched.
			$log->debug("Ximalaya: album/simple $albumId: " . ($info->{albumTitle} // '?')
				. " cover=" . ($info->{cover} // 'none'));
			$cb->({
				id          => $albumId,
				title       => $info->{albumTitle} // "Album $albumId",
				cover       => $class->_norm_cover($info->{cover}),
				announcer   => $info->{anchorName} // $info->{announcerName} // $info->{nickname} // '',
				tracksCount => $info->{tracksCount} // undef,
				paid        => $info->{isPaid}      // 0,
				finished    => $info->{isFinished}  // 0,
			});
		},
		$ecb,
		'30min',
	);

	return;
}

# $class->albumTracks($albumId, $page, $pageSize, $cb, $ecb)
#   cb->( [ { id, title, paid, cover }, ... ], $total )   or ecb->($errcode)
#   $total = server-side trackTotalCount (may be undef)
sub albumTracks {
	my ($class, $albumId, $page, $pageSize, $cb, $ecb) = @_;
	$page     ||= 1;
	$pageSize ||= 100;

	Plugins::Ximalaya::Sign->gen(
		sub {
			my ($sign) = @_;
			$class->_json_get(
				TRACKS_LIST . "?albumId=" . uri_escape_utf8($albumId)
				. "&pageNum=" . int($page) . "&sort=0&pageSize=" . int($pageSize),
				$class->_base_headers(
					'Referer' => BASE . "/album/$albumId",
					'xm-sign' => $sign,
				),
				sub {
					my ($data) = @_;
					if (my $code = $class->_check_ret($data)) {
						$ecb->($code);
						return;
					}
					my $d = $data->{data} || {};
					my $list = $d->{tracks} || $d->{tracksAudioPlay} || [];

					# 0.1.9 diagnostics (pagination issue): log the reply shape
					# at DEBUG - real page size, total fields, first/last ids
					my @meta = map { "$_=" . ($d->{$_} // '') } grep { !ref $d->{$_} } sort keys %$d;
					$log->debug("Ximalaya: album $albumId page $page reply: n="
						. scalar(@$list) . " meta[@meta]"
						. (@$list ? " first=" . ($list->[0]{trackId} // '?')
							. " last=" . ($list->[-1]{trackId} // '?') : ''));

					# Soft risk control: HTTP success but empty content
					if (!@$list && ($d->{riskLevel} // 0)) {
						$log->warn("Ximalaya: album $albumId list soft-risk (riskLevel=$d->{riskLevel})");
						$ecb->('risk');
						return;
					}
					$cb->([ map {
						my $t = $_;
						{
							id    => $t->{trackId},
							title => $t->{title} // $t->{trackName} // "?",
							paid  => $t->{isPaid} // 0,
							cover => $class->_norm_cover($t->{coverPath} || $t->{cover}),
						}
					} @$list ], $d->{trackTotalCount});
				},
				$ecb,
			);
		},
		sub {
			my ($error) = @_;
			$ecb->($error);
		},
	);

	return;
}

# ----------------------------------------------------------------- category

# Master switch for the category endpoints. Package VARIABLE (not a
# constant) so the offline stub test can localize it to 0 and re-verify
# the zero-network 'todo' short-circuit.
#
# 2026-09-10 verification day: candidate (1) queryCategoryPageAlbums
# confirmed LIVE via m0/diag_category.py - ret=200, no riskLevel,
# data.albums[30], total echo (see t/fixtures_category.json real2026).
# Default is 1; set to 0 to return the menu to the 待接入 placeholder.
our $CATEGORY_API_ENABLED = 1;

# Candidate endpoint (third-party scripts commonly use this route; the
# fallback candidate is /revision/category/queryAllCategory).
use constant CATEGORY_ALBUMS_URL => BASE . '/revision/category/queryCategoryPageAlbums';

# Sort params per sort key. VERIFIED 2026-09-10: sort=0 is the default
# (最热) ordering - the live probe returned the expected hot list (top
# album ~2.0e9 plays). The other three orderings are still UNVERIFIED:
# undef entries are omitted from the query (they would silently degrade
# to the default order) and the sort menu hides them until device-side
# probing pins their real values (0.1.12 candidate).
my %CATEGORY_SORT_PARAMS = (
	hot      => { sort  => 0 },
	new      => { sort  => undef },
	play     => { sort  => undef },
	finished => { state => undef },
);

# $class->categoryAlbums($catId, $sortKey, $page, $pageSize, $cb, $ecb)
#   cb->( [ {id,title,cover,announcer,tracksCount,paid}, ... ], $total )
#   ecb->($errcode)   'todo' = endpoint not wired/verified yet
sub categoryAlbums {
	my ($class, $catId, $sortKey, $page, $pageSize, $cb, $ecb) = @_;
	$page     ||= 1;
	$pageSize ||= 30;
	$sortKey  ||= 'hot';

	unless ($CATEGORY_API_ENABLED) {
		$ecb->('todo');
		return;
	}

	my $sort  = $CATEGORY_SORT_PARAMS{$sortKey} || $CATEGORY_SORT_PARAMS{hot};
	# Param names VERIFIED 2026-09-10 (live probe + 2019 third-party
	# script, m0/ref/cnblogs_2019_category_api.md): the server takes
	# perPage (NOT pageSize) plus an optional empty meta; page is 1-based
	# (page=1 returned the natural first page). Server echoes data.pageSize.
	my %query = (
		category => $catId,
		meta     => '',
		page     => int($page),
		perPage  => int($pageSize),
		(map { defined $sort->{$_} ? ($_ => $sort->{$_}) : () } keys %$sort),
	);
	my $query = join '&', map { $_ . '=' . uri_escape_utf8($query{$_}) } sort keys %query;

	Plugins::Ximalaya::Sign->gen(
		sub {
			my ($sign) = @_;
			$class->_json_get(
				CATEGORY_ALBUMS_URL . '?' . $query,
				$class->_base_headers(
					'Referer' => BASE . '/' . $catId,
					'xm-sign' => $sign,
				),
				sub {
					my ($data) = @_;
					if (my $code = $class->_check_ret($data)) {
						$ecb->($code);
						return;
					}
					my ($albums, $total) = $class->_parse_category_albums($data);
					unless (defined $albums) {
						$ecb->($total);
						return;
					}
					$cb->($albums, $total);
				},
				$ecb,
			);
		},
		sub {
			my ($error) = @_;
			$ecb->($error);
		},
	);

	return;
}

# Pure parser for category album lists - offline stub-tested by
# t/category_stub_test.pl against t/fixtures_category.json.
# Returns ($albums_ref, $total) on success, (undef, $errcode) on failure
# ('risk' for soft risk control, 'empty' for an unrecognized/empty shape).
sub _parse_category_albums {
	my ($class, $data) = @_;

	my $d = $data->{data} || {};

	if ($d->{riskLevel} // 0) {
		return (undef, 'risk');
	}

	# Candidate doc paths. VERIFIED 2026-09-10: the live endpoint returns
	# data.albums as a PLAIN array (no docs wrapper). Older shapes stay as
	# fallbacks for response drift.
	my $docs = $d->{albums}
		|| $d->{albumsResult}{docs}
		|| $d->{albums}{docs}
		|| $d->{docs}
		|| [];

	unless (@$docs) {
		return (undef, 'empty');
	}

	my @albums = map {
		my $a = $_;
		# cover: VERIFIED 2026-09-10 the live feed hands out protocol-
		# relative paths; _norm_cover absolutizes every known shape
		{
			id          => $a->{albumId} // $a->{id},
			title       => $a->{title} // $a->{albumTitle} // '?',
			cover       => $class->_norm_cover($a->{cover} // $a->{coverPath} // ''),
			announcer   => $a->{anchorName} // $a->{nickname} // $a->{announcer} // '',
			tracksCount => $a->{tracksCount} // $a->{trackCount} // undef,
			paid        => $a->{isPaid} // 0,
		}
	} @$docs;

	my $total = $d->{total} // $d->{albumsResult}{total} // scalar @albums;

	return (\@albums, $total);
}

# ------------------------------------------------------------------- pc channel

# $class->albumTracksShow($albumId, $page, $size, $cb, $ecb)
#   pc play/v1/show album track list (0.1.12 free-album fallback; the pc
#   PRIMARY list since 0.1.13). VERIFIED 2026-09-10: anonymous AND
#   plugin-identity both return full content; 1-based page, hasMore, no
#   total. $size is SERVER-HONORED (probe: size=50 -> pageSize=50 echo,
#   clean num=2 continuation; size=100 clamps to 30) - since 0.1.14 the
#   caller passes the UI window width so paging math matches the web path
#   exactly; clamped to PC_SHOW_MAX.
#   cb->( [ { id, title, paid, cover }, ... ], $hasMore )  ecb->($errcode)
#   NOTE: tracks carry no isPaid field - per-track [VIP] marking is not
#   possible here (web fallback still supplies it).
sub albumTracksShow {
	my ($class, $albumId, $page, $size, $cb, $ecb) = @_;
	$page ||= 1;
	$size = int($size || PC_PAGE_SIZE);
	$size = 1            if $size < 1;
	$size = PC_SHOW_MAX  if $size > PC_SHOW_MAX;

	unless ($class->pc_enabled) {
		$ecb->('todo');
		return;
	}

	Plugins::Ximalaya::Sign->gen(
		sub {
			my ($sign) = @_;
			my $headers = $class->_pc_headers(PC_BASE . "/album/$albumId");
			$headers->{'xm-sign'} = $sign;
			$class->_json_get(
				PC_SHOW . '?id=' . uri_escape_utf8($albumId)
				. '&num=' . int($page) . '&sort=0&size=' . $size . '&ptype=0',
				$headers,
				sub {
					my ($data) = @_;
					if (my $code = $class->_check_ret($data)) {
						$ecb->($code);
						return;
					}
					my ($tracks, $has_more, $err) = $class->_parse_show_tracks($data);
					unless (defined $tracks) {
						$ecb->($err);
						return;
					}
					$cb->($tracks, $has_more);
				},
				$ecb,
			);
		},
		sub {
			my ($error) = @_;
			$ecb->($error);
		},
	);

	return;
}

# Pure parser for the play/v1/show reply - offline stub-tested by
# t/pc_stub_test.pl against t/fixtures_pc.json (real 2026-09-10 shapes).
# Returns ($tracks_ref, $has_more, undef) on success, (undef, undef, $errcode)
# on failure ('risk' for soft risk control, 'empty' for no/unrecognized list).
sub _parse_show_tracks {
	my ($class, $data) = @_;

	my $d = $data->{data} || {};

	if ($d->{riskLevel} // 0) {
		return (undef, undef, 'risk');
	}

	my $list = $d->{tracksAudioPlay} || [];
	unless (@$list) {
		return (undef, undef, 'empty');
	}

	my @tracks = map {
		my $t = $_;
		{
			id    => $t->{trackId},
			title => $t->{trackName} // "?",
			paid  => $t->{isPaid} // 0,      # absent in real replies -> 0
			cover => $class->_norm_cover($t->{trackCoverPath} // ''),
		}
	} @$list;

	return (\@tracks, $d->{hasMore} ? 1 : 0, undef);
}

# $class->trackQuality($trackId, $cb, $ecb)
#   pc track/quality: anonymous, NO xm-sign, NO cookie (verified exactly so).
#   cb->( \%urls, $meta )  %urls = ( tier => plaintext_url ), $meta =
#   { title, albumId, albumTitle, paid, cover }; ecb->($errcode).
#   %urls is EMPTY for paid tracks (plaintext withheld) - callers fall back
#   to baseInfo device=win.
sub trackQuality {
	my ($class, $trackId, $cb, $ecb) = @_;

	my $ts = int(Time::HiRes::time() * 1000);
	$class->_json_get(
		TRACK_QUALITY . "/" . uri_escape_utf8($trackId) . "/$ts",
		{
			# exactly the verified probe header set (diag_trackquality.py):
			# no cookie, no sign
			'Accept'     => 'application/json, text/plain, */*',
			'User-Agent' => $UA,
		},
		sub {
			my ($data) = @_;
			if (my $code = $class->_check_ret($data)) {
				$ecb->($code);
				return;
			}
			my ($urls, $meta, $err) = $class->_parse_track_quality($data);
			unless (defined $urls) {
				$ecb->($err);
				return;
			}
			$cb->($urls, $meta);
		},
		$ecb,
	);

	return;
}

# Pure parser for the track/quality reply. Returns (\%urls, $meta, undef) or
# (undef, undef, $errcode). Plaintext URL fields come out of
# data.debugInfo.debugDetailMap.detailTrackDto.result.playPathDto; empty
# strings mean the tier is absent (hqSize=0 etc).
sub _parse_track_quality {
	my ($class, $data) = @_;

	my $result = eval {
		$data->{data}{debugInfo}{debugDetailMap}{detailTrackDto}{result}
	} || {};

	if ($data->{data}{riskLevel} // 0) {
		return (undef, undef, 'risk');
	}

	my $dto = $result->{playPathDto} || {};
	my %urls;
	for my $field (keys %PC_PLAY_FIELDS) {
		my $u = $dto->{$field};
		next unless defined $u && length $u;
		# ORIGIN is only usable as a FULL plaintext URL; VIP replies carry a
		# bare storages path there (probe 2026-09-10) - drop those
		next if $field eq 'originPlayPath' && $u !~ m{^https?://};
		$urls{ $PC_PLAY_FIELDS{$field} } = $u;
	}

	# 0.1.24: per-tier byte sizes (+ result.duration) power the free-track
	# bitrate display; zero/absent sizes are skipped (tier not really there)
	my %sizes;
	for my $field (keys %PC_SIZE_FIELDS) {
		my $n = $dto->{$field};
		$sizes{ $PC_SIZE_FIELDS{$field} } = $n if defined $n && $n =~ /^\d+$/ && $n > 0;
	}

	my $meta = {
		title      => $result->{title} // undef,
		albumId    => $result->{albumId} // undef,
		albumTitle => $result->{albumTitle} // undef,
		paid       => $result->{isPaid} // 0,
		duration   => $result->{duration} // undef,
		sizes      => \%sizes,
		cover      => $class->_norm_cover($result->{coverPath}),
	};

	# no playPathDto at all = unrecognized shape; an empty %urls with a
	# present dto is a VALID paid-track reply and returned as success
	return (undef, undef, 'empty')
		unless keys %urls || keys %$dto || keys %$result;

	return (\%urls, $meta, undef);
}

# pick the best available URL from a tier=>url map given the preference order
# $class->albumTracksMobile($albumId, $page, $pageSize, $cb, $ecb)
#   mobile-domain album track list. VERIFIED 2026-09-10: PAID/VIP albums
#   get the EXACT data.totalCount (1388 for 83701277), pageSize echo, clean
#   p1/p2 continuation and per-track isPaid (so the [VIP] prefix works
#   again); free albums return an EMPTY list (ret=0) -> ecb('empty') and
#   the caller falls through to the pc show path. Same domain as
#   track/quality (zero risk-control so far). 30min HTTP cache - page
#   turns are free.
#   cb->( [ { id, title, paid, cover }, ... ], $totalCount )  ecb->($err)
sub albumTracksMobile {
	my ($class, $albumId, $page, $pageSize, $cb, $ecb) = @_;
	$page    ||= 1;
	$pageSize = int($pageSize || 50);
	$pageSize = 1   if $pageSize < 1;
	$pageSize = 150 if $pageSize > 150;   # observed healthy at 50

	$class->_json_get(
		MOBILE_TRACKS . '?albumId=' . uri_escape_utf8($albumId)
		. '&pageId=' . int($page) . '&pageSize=' . $pageSize . '&order=0',
		$class->_base_headers(),
		sub {
			my ($data) = @_;
			my ($tracks, $total, $err) = $class->_parse_mobile_tracks($data);
			unless (defined $tracks) {
				$ecb->($err);
				return;
			}
			$cb->($tracks, $total);
		},
		$ecb,
		'30min',
	);

	return;
}

# Pure parser: data.list[] -> ([{id,title,paid,cover}], $totalCount, undef)
# empty list -> (undef, undef, 'empty')  (free albums; caller falls through)
sub _parse_mobile_tracks {
	my ($class, $data) = @_;

	my $list = eval { $data->{data}{list} } || [];
	unless (@$list) {
		return (undef, undef, 'empty');
	}

	my @out = map {
		my $t = $_;
		{
			id    => $t->{trackId},
			title => $t->{title} // '?',
			paid  => $t->{isPaid} // 0,
			cover => $class->_norm_cover($t->{coverSmall} // $t->{coverMiddle} // $t->{coverLarge}),
		}
	} @$list;

	my $total = eval { $data->{data}{totalCount} };
	return (\@out, $total, undef);
}

sub _pick {
	my ($class, $urls, $order) = @_;
	for my $tier (@$order) {
		return ($urls->{$tier}, $tier) if $urls->{$tier};
	}
	return ();    # caller decides what an empty map means
}

# --------------------------------------------------------------- rank (pc)
# Discovery via the PC-client rank endpoints (0.1.13). VERIFIED 2026-09-10
# probes (m0/pc_ranktabs.json, pc_rank_element.json): rankTabs returns the
# full channel x chart table (sceneId=1); rank/element returns ONE chart's
# albums WITH full details (title/cover/anchor/trackCount/isPaid/finished)
# - 100 albums per chart, no server paging (slice locally).
# This replaces the web category browse (guessed slugs -> 404 on device).

# $class->rankTabs($cb, $ecb)
#   cb->( [ { id, name, ranks => [ { rankingId, name }, ... ] }, ... ] )
#   HTTP-cached 1h (chart table drifts slowly); one network hit then menu
#   turns serve from cache.
sub rankTabs {
	my ($class, $cb, $ecb) = @_;

	unless ($class->pc_enabled) {
		$ecb->('todo');
		return;
	}

	Plugins::Ximalaya::Sign->gen(
		sub {
			my ($sign) = @_;
			my $headers = $class->_pc_headers(PC_BASE . '/');
			$headers->{'xm-sign'} = $sign;
			$class->_json_get(
				PC_RANK_TABS . '?sceneId=1',
				$headers,
				sub {
					my ($data) = @_;
					if (my $code = $class->_check_ret($data)) {
						$ecb->($code);
						return;
					}
					my ($tabs, $err) = $class->_parse_rank_tabs($data);
					defined $tabs ? $cb->($tabs) : $ecb->($err);
				},
				$ecb,
				'1h',
			);
		},
		sub { $ecb->($_[0]); },
	);

	return;
}

# Pure parser: data.tabLists[] -> ordered [ { id, name, ranks => [...] } ]
sub _parse_rank_tabs {
	my ($class, $data) = @_;

	my $lists = eval { $data->{data}{tabLists} } || [];
	unless (@$lists) {
		return (undef, 'empty');
	}

	my @tabs;
	for my $t (@$lists) {
		next unless $t->{id} && $t->{name};
		my @ranks;
		for my $w (@{ $t->{tabWraps} || [] }) {
			next unless $w->{rankingId} && $w->{name};
			push @ranks, { rankingId => $w->{rankingId}, name => $w->{name} };
		}
		next unless @ranks;
		push @tabs, {
			id    => $t->{id},
			name  => $t->{name},
			pos   => $t->{position} // 99,
			ranks => \@ranks,
		};
	}

	unless (@tabs) {
		return (undef, 'empty');
	}

	@tabs = sort { $a->{pos} <=> $b->{pos} } @tabs;
	return (\@tabs, undef);
}

# $class->rankAlbums($rankingId, $cb, $ecb)
#   cb->( [ { id, title, cover, announcer, tracksCount, paid, finished }, ... ],
#         $total, $categoryCode )
#   Full chart in one reply (~100 albums, isPaid available); 30min HTTP cache.
#   $categoryCode = the chart's authoritative web-category slug (taken from
#   the albums' categoryCode field, e.g. 'youshengshu') - it powers the
#   "browse ALL albums" entry without any guessed slugs.
sub rankAlbums {
	my ($class, $rankingId, $cb, $ecb) = @_;
	$rankingId = int($rankingId || 0);
	unless ($rankingId) {
		$ecb->('empty');
		return;
	}

	unless ($class->pc_enabled) {
		$ecb->('todo');
		return;
	}

	Plugins::Ximalaya::Sign->gen(
		sub {
			my ($sign) = @_;
			my $headers = $class->_pc_headers(PC_BASE . '/');
			$headers->{'xm-sign'} = $sign;
			$class->_json_get(
				PC_RANK_ELEMENT . '?rankingId=' . $rankingId,
				$headers,
				sub {
					my ($data) = @_;
					if (my $code = $class->_check_ret($data)) {
						$ecb->($code);
						return;
					}
					my ($albums, $category_code, $err) = $class->_parse_rank_albums($data);
					unless (defined $albums) {
						$ecb->($err);
						return;
					}
					$cb->($albums, scalar @$albums, $category_code);
				},
				$ecb,
				'30min',
			);
		},
		sub { $ecb->($_[0]); },
	);

	return;
}

# Pure parser: data.rankList[] -> (album hashes, $categoryCode, undef)
sub _parse_rank_albums {
	my ($class, $data) = @_;

	my $lists = eval { $data->{data}{rankList} } || [];

	for my $r (@$lists) {
		my $albums = $r->{albums} || [];
		next unless @$albums;

		my $category_code = '';
		my @out = map {
			my $a = $_;
			$category_code ||= $a->{categoryCode} // '';
			{
				id          => $a->{id},
				title       => $a->{albumTitle} // '?',
				cover       => $class->_norm_cover($a->{cover} // $a->{coverPath} // ''),
				announcer   => $a->{anchorName} // '',
				tracksCount => $a->{trackCount} // undef,
				paid        => $a->{isPaid} // 0,
				finished    => ($a->{isFinished} ? 1 : 0),
			}
		} @$albums;
		return (\@out, $category_code, undef);
	}

	return (undef, undef, 'empty');
}

# ------------------------------------------------------------------- search

# $class->searchAlbums($kw, $page, $cb, $ecb)
#   cb->( [ { id, title, cover, announcer, tracksCount, paid }, ... ], $total )
#
# 0.1.27: rewritten onto the m (mobile web) revision search. The old web
# /revision/search/main is endpoint-dead (1005 family) and pc /search/main is
# client-gated (both probe-verified, HANDOFF §2.2/§2.7). The m channel needs
# the user 1&_token cookie AND a fresh xm-sign header per request - without
# the header it soft-fails (ret=0, isIllegal, empty results), which the
# parser reports as 'risk' so the menu cooldown kicks in.
sub searchAlbums {
	my ($class, $kw, $page, $cb, $ecb) = @_;
	$page = 1 unless $page && $page > 0;

	# anonymous searches are refused server-side (ret=303 needLogin) - fail
	# fast locally with the login error instead of burning a request
	unless (_cookie() =~ /1&_token=/) {
		$ecb->('1001');
		return;
	}

	Plugins::Ximalaya::Sign->gen(
		sub {
			my ($sign) = @_;
			$class->_json_get(
				M_SEARCH . '?kw=' . uri_escape_utf8($kw)
				. '&core=all&page=' . $page . '&rows=' . M_SEARCH_ROWS,
				{
					'Accept'          => 'application/json, text/plain, */*',
					'Accept-Language' => 'zh-CN,zh;q=0.9,en;q=0.8',
					'User-Agent'      => $MOBILE_UA,
					'Referer'         => M_BASE . '/search',
					'Cookie'          => _cookie(),
					'xm-sign'         => $sign,
				},
				sub {
					my ($data) = @_;
					if (my $code = $class->_check_ret($data)) {
						$ecb->($code);
						return;
					}
					my ($albums, $total, $err) = $class->_parse_search_albums($data);
					unless (defined $albums) {
						$ecb->($err);
						return;
					}
					$cb->($albums, $total);
				},
				$ecb,
			);
		},
		sub {
			my ($error) = @_;
			$ecb->($error);
		},
	);

	return;
}

# Pure parser: m-revision/page/search reply -> ([album hashes], $total, undef)
# or (undef, undef, $err). VERIFIED probe3 gold (fixtures_pc.json searchOk):
# albumViews.albums[] items carry albumInfo in the legacy docs shape -
# id/title/cover_path(protocol-relative or http)/nickname(anchor)/tracks
# (string count)/is_paid(STRING boolean "False"/"True")/play/intro - plus
# pageUriInfo{categoryCode}. NOT the recommendItems shape (which has
# statCountInfo/cover) - that is the advice-filler surface, not results.
sub _parse_search_albums {
	my ($class, $data) = @_;

	# soft-failure guard: ret=0 + isIllegal/sq marker + empty views happens
	# when xm-sign is stale/absent - treat as risk (menu cooldown), not empty
	my $d = $data->{data} || {};
	if (($d->{isIllegal} || 0) || (defined $d->{sq} && $d->{sq} ne '')) {
		return (undef, undef, 'risk');
	}

	my $av     = $d->{albumViews} || {};
	my $albums = $av->{albums} || [];
	my $total  = $av->{total};

	return ([], defined $total ? $total : undef, undef) unless @$albums;

	my @out = map {
		my $info = $_->{albumInfo} || {};
		{
			id          => $info->{id},
			title       => $info->{title} // '?',
			cover       => $class->_norm_cover($info->{cover_path} // ''),
			announcer   => $info->{nickname} // '',
			tracksCount => defined $info->{tracks} ? $info->{tracks} + 0 : undef,
			paid        => (($info->{is_paid} // '') =~ /^(True|true|1)$/) ? 1 : 0,
		}
	} @$albums;

	return (\@out, $total, undef);
}

# ------------------------------------------------------------------- resolve

# internal: fetch the baseInfo reply for one track.
# cb->( $trackInfoHash, $fullReplyHash )
#   xm-sign is regenerated per request (single-use). No HTTP caching here -
#   playback URLs are short-lived; trackMeta() layers its own metadata cache.
#   $opts (optional): { device => 'win' } switches to the desktop-client
#   variant (encrypted with the WIN AES key) and appends the pc device
#   triple to the cookie - the client's own flow for paid tracks.
sub _baseInfo {
	my ($class, $trackId, $cb, $ecb, $opts) = @_;
	$opts ||= {};
	my $device = $opts->{device} || 'www2';
	my $level  = $opts->{level};
	$level = 1 unless defined $level && $level >= 0 && $level <= 3;

	Plugins::Ximalaya::Sign->gen(
		sub {
			my ($sign) = @_;
			my $ts = int(Time::HiRes::time() * 1000);
			my %extra = (
				'Referer' => BASE . "/sound/$trackId",
				'Origin'  => BASE,
				'xm-sign' => $sign,
				'Sec-Fetch-Dest' => 'empty',
				'Sec-Fetch-Mode' => 'cors',
				'Sec-Fetch-Site' => 'same-origin',
			);
			if ($device eq 'win') {
				my $cookie = _cookie();
				$cookie .= '; ' if $cookie;
				$cookie .= $class->_pc_device_cookie;
				$extra{'Cookie'} = $cookie;
			}
			$class->_json_get(
				BASE_INFO . "/$ts?device=$device&trackId=" . uri_escape_utf8($trackId)
				. "&trackQualityLevel=$level",
				$class->_base_headers(%extra),
				sub {
					my ($data) = @_;
					if (my $code = $class->_check_ret($data)) {
						$ecb->($code);
						return;
					}
					$cb->(
						$data->{data}{trackInfo} || $data->{trackInfo} || {},
						$data,
					);
				},
				$ecb,
			);
		},
		sub {
			my ($error) = @_;
			$ecb->($error);
		},
	);

	return;
}

# in-memory browse-metadata cache (the paste menu may re-resolve the same
# track); metadata only - never the short-lived playback URLs
my %META_CACHE;    # trackId => { expires => epoch, meta => {...} }

# $class->trackMeta($trackId, $cb, $ecb)
#   cb->( { title, albumId, albumTitle, paid, authorized } )  ecb->($errcode)
#   10-minute cache to keep request frequency low. albumId is parsed
#   defensively: verified baseInfo payloads (2026-09-09, free track) expose
#   no album reference - if none is found, albumId stays undef and the menu
#   simply omits the "open containing album" link.
sub trackMeta {
	my ($class, $trackId, $cb, $ecb) = @_;

	my $hit = $META_CACHE{$trackId};
	if ($hit && $hit->{expires} > Time::HiRes::time()) {
		$cb->($hit->{meta});
		return;
	}

	$class->_baseInfo($trackId,
		sub {
			my ($info, $data) = @_;

			# soft risk control (observed 2026-09-09): HTTP 200 + ret=0 but
			# an EMPTY payload - treat like any other soft-risk reply
			unless ($info && keys %$info) {
				$log->warn("Ximalaya: baseInfo empty payload for track $trackId (soft risk?)");
				$ecb->('risk');
				return;
			}

			my $alb      = $info->{album} || $data->{data}{albumInfo} || $data->{data}{album} || {};
			my $albumId  = $info->{albumId} // $alb->{albumId} // $alb->{id} // '';
			$albumId     = ($albumId =~ /^\d+$/) ? $albumId : undef;

			my $meta = {
				title      => $info->{title} // "Track $trackId",
				albumId    => $albumId,
				albumTitle => ($alb->{albumTitle} // $alb->{title} // ''),
				paid       => $info->{isPaid} // 0,
				authorized => $info->{isAuthorized} // 0,
			};

			$META_CACHE{$trackId} = {
				expires => Time::HiRes::time() + 600,
				meta    => $meta,
			};
			$cb->($meta);
		},
		$ecb,
	);

	return;
}

# ---------------------------------------------- resolve cache (seek fast-path)
# 0.1.25: short-lived in-memory resolve cache (server RAM only, never
# persisted). WHY: a progress-bar seek makes LMS rebuild the song and re-run
# scanUrl. Our resolve is async (~1.5-3.5s: track/quality + hdaa + baseInfo,
# then Scanner::Remote probes the CDN URL) and that gap made the controller
# treat the player as stopped and restart the track WITHOUT seekdata - every
# seek restarted from 0. Diag 2026-09-11: the SAME remote CDN URL seeks fine
# (m0/diag_cdn_range.py: Accept-Ranges + HTTP 206) and a raw-URL A/B on the
# device confirmed the player/LMS chain is seek-capable - only the async
# handler hop broke it. With a fresh cache entry ProtocolHandler.scanUrl
# answers synchronously and the re-open carries its Range like any plain
# remote URL. Side effect: repeats/seeks within 10min cost ZERO API calls.
my %RESOLVE_CACHE;    # trackId => { expires => epoch, info => {resolve hash} }

sub peek_resolve {
	my ($class, $trackId) = @_;

	my $c = $RESOLVE_CACHE{$trackId} or return undef;
	if ($c->{expires} < Time::HiRes::time()) {
		delete $RESOLVE_CACHE{$trackId};
		return undef;
	}
	return $c->{info};
}

sub _store_resolve {
	my ($class, $trackId, $info) = @_;

	# tiny cap (one album of distinct tracks is far beyond normal use)
	%RESOLVE_CACHE = () if keys %RESOLVE_CACHE > 100;
	$RESOLVE_CACHE{$trackId} = {
		expires => Time::HiRes::time() + 600,
		info    => $info,
	};

	return;
}

# test hook: wipe the cache between stub scenarios
sub _clear_resolve_cache {
	%RESOLVE_CACHE = ();
	return;
}

# $class->resolveTrack($trackId, $cb, $ecb)
#   cb->( { trackId, title, authorized, paid, url, quality } )
#   ecb->( $errcode )   1001=login 927/3005=noperm risk=soft-risk 407=sign ...
#
# 0.1.12 routing with the pc channel enabled:
#   1. track/quality  - anonymous plaintext (free tracks end here, 1 request)
#   2. baseInfo win   - paid tracks (empty plaintext) via the client's own
#                       AES-ECB flow; win failure falls one step further to
#   3. baseInfo www2  - the pre-0.1.12 verified web path (also the blanket
#                       fallback whenever the whole pc chain fails).
sub resolveTrack {
	my ($class, $trackId, $cb, $ecb) = @_;

	# 0.1.25 seek fast-path: serve a fresh resolve synchronously
	if (my $cached = $class->peek_resolve($trackId)) {
		main::INFOLOG && $log->info("Ximalaya: track $trackId resolve cache hit (sync seek path)");
		$cb->($cached);
		return;
	}

	# store every successful resolve, then hand it on (0.1.25)
	my $store = sub {
		my ($info) = @_;
		$class->_store_resolve($trackId, $info) if $info && $info->{url};
		$cb->($info);
	};

	if ($class->pc_enabled) {
		$class->_resolvePC($trackId, $store,
			sub {
				my ($code) = @_;
				$log->warn("Ximalaya: pc resolve failed for $trackId ($code) - web fallback");
				$class->_resolveWeb($trackId, $store, $ecb);
			});
		return;
	}

	$class->_resolveWeb($trackId, $store, $ecb);

	return;
}

# pc chain: track/quality -> (paid?) baseInfo device=win
sub _resolvePC {
	my ($class, $trackId, $cb, $fail) = @_;

	$class->trackQuality($trackId,
		sub {
			my ($urls, $meta) = @_;

			if (keys %$urls) {
				my $quality = $prefs->get('quality') || 64;
				my ($url, $picked) = $class->_pick($urls, $PC_QUALITY_ORDER{$quality} || $PC_QUALITY_ORDER{64});
				# set log.plugin.ximalaya=DEBUG to audit which tier got picked
				$log->debug("Ximalaya: pc track $trackId quality=$quality picked=$picked");
				# 0.1.24: real bitrate for the free-track display - playPathDto
				# per-tier sizes + result.duration (same math as the win chain).
				# The CDNs send no icy-br header, so without this Daphile shows
				# no rate at all for the pc plaintext chain.
				my $size     = ($meta->{sizes} || {})->{$picked};
				my $duration = $meta->{duration};
				my $bitrate  = ($size && $duration) ? int($size * 8 / $duration) : undef;
				$log->debug("Ximalaya: pc track $trackId bitrate=", ($bitrate // 'unknown'),
					" duration=", ($duration // 'unknown'));
				$cb->({
					trackId    => $trackId,
					title      => $meta->{title} // "Track $trackId",
					authorized => 1,
					paid       => $meta->{paid} // 0,
					quality    => $picked =~ /^MP3_/ ? 'mp3' : 'm4a',
					cover      => $meta->{cover} || '',
					($bitrate ? (bitrate => $bitrate) : ()),
					($duration ? (duration => $duration) : ()),
					url        => $url,
				});
				return;
			}

			# paid track: playPathDto carries sizes only, no plaintext.
			# PC client's own flow: baseInfo device=win + WIN-key AES decrypt.
			$log->debug("Ximalaya: pc track $trackId has no plaintext paths (paid?) - baseInfo win");
			$class->_resolveWin($trackId, $cb, $fail);
		},
		$fail,
	);

	return;
}

# paid-track step: baseInfo device=win, playUrlList decrypted with the WIN
# key. 0.1.18: the request carries trackQualityLevel from the PC client's
# ladder (probe: level 2 adds the M4A_128 tier; level 3 = lossless is
# entitlement-gated, ret 1001 -> automatic one-step fallback). Tier picking
# prefers an exact qualityLevel match, then the pref's type order.
sub _resolveWin {
	my ($class, $trackId, $cb, $fail, $level) = @_;

	$level = $WIN_LEVEL{ $prefs->get('quality') || 64 } // 1
		unless defined $level;
	$level = 1 if $level < 0 || $level > 3;

	my $pick;    # forward-declared closure (recursive retry below)
	$pick = sub {
		my ($lvl) = @_;

	$class->_baseInfo($trackId,
		sub {
			my ($info) = @_;

			unless ($info && keys %$info) {
				$fail->('risk');
				return;
			}

			my $enc = $info->{playUrlList} || [];
			my %urls;
			my %sizes;
			my %bylvl;
			my %bylvlSize;
			for my $item (@$enc) {
				next unless $item->{url};
				my $plain = eval { Plugins::Ximalaya::XimaCrypt->decrypt_url_win($item->{url}) };
				$log->error("Ximalaya: win decrypt failed for $item->{type}: $@") if $@;
				next unless $plain;
				if ($item->{type}) {
					$urls{ $item->{type} }    = $plain;
					$sizes{ $item->{type} }   = $item->{fileSize};
				}
				my $ql = $item->{qualityLevel};
				if (defined $ql && !$bylvl{$ql}) {
					$bylvl{$ql}     = $plain;
					$bylvlSize{$ql} = $item->{fileSize};
				}
			}

			unless (keys %urls) {
				$fail->($info->{isAuthorized} ? 'nourl' : 'noperm');
				return;
			}

			# exact requested tier first (probe: playUrlList items carry the
			# numeric qualityLevel; type names alone miss M4A_128 at level 2)
			my ($url, $picked, $size);
			if (my $u = $bylvl{$lvl}) {
				$url    = $u;
				$picked = "level$lvl";
				$size   = $bylvlSize{$lvl};
			}
			if (!$url) {
				my $quality = $prefs->get('quality') || 64;
				($url, $picked) = $class->_pick(\%urls, $QUALITY_ORDER{$quality} || $QUALITY_ORDER{64});
				$size = $sizes{$picked};
			}
			unless ($url) {
				($url, $picked) = $class->_pick(\%urls, [sort keys %urls]);
				$size = $sizes{$picked};
			}
			$log->debug("Ximalaya: win track $trackId picked=$picked");

			# 0.1.19: exact bitrate for the display - Ximalaya CDNs send no
			# icy-br header, so LMS has nothing to show until (if ever) its
			# stream probe completes. playUrlList fileSize + trackInfo
			# duration give the real number (probe: the "128k" tier is
			# actually 96k CBR AAC - server labels oversell).
			my $duration = $info->{duration};
			my $bitrate  = ($size && $duration) ? int($size * 8 / $duration) : undef;
			$log->debug("Ximalaya: win track $trackId bitrate=", ($bitrate // 'unknown'), " duration=", ($duration // 'unknown'));

			$cb->({
				trackId    => $trackId,
				title      => $info->{title} // "Track $trackId",
				authorized => $info->{isAuthorized} // 1,
				paid       => $info->{isPaid} // 1,
				quality    => $url =~ /\.mp3/ ? 'mp3' : 'm4a',
				# 0.1.20: trackInfo carries coverLarge/Middle/Small (probe
				# 2026-09-10) - needed for the now-playing artwork
				cover      => $class->_norm_cover(
					$info->{coverLarge} || $info->{coverMiddle} || $info->{coverSmall}),
				($bitrate ? (bitrate => $bitrate)      : ()),
				($duration ? (duration => $duration)   : ()),
				url        => $url,
			});
		},
		sub {
			my ($code) = @_;
			# higher tiers are entitlement-gated (probe: level 3 -> ret 1001
			# "system busy" while level 2 succeeds): fall back one ladder
			# step, bottoming at level 1 (the pre-0.1.18 behaviour)
			if ($code eq '1001' && $lvl > 1) {
				$log->debug("Ximalaya: win track $trackId level $lvl gated (1001) - falling back to ", $lvl - 1);
				$pick->($lvl - 1);
				return;
			}
			$fail->($code);
		},
		{ device => 'win', level => $lvl },
	);
	};
	$pick->($level);

	return;
}

# pre-0.1.12 verified web path: baseInfo www2 + sbox/XOR playUrlList
sub _resolveWeb {
	my ($class, $trackId, $cb, $ecb) = @_;

	$class->_baseInfo($trackId,
		sub {
			my ($info) = @_;

			# soft risk control: ret=0 but no trackInfo payload at all
			# (was misreported as 'noperm' before 0.1.7)
			unless ($info && keys %$info) {
				$log->warn("Ximalaya: baseInfo empty payload for track $trackId (soft risk?)");
				$ecb->('risk');
				return;
			}

			my $enc = $info->{playUrlList} || [];

			if (!@$enc) {
				$ecb->($info->{isAuthorized} ? 'nourl' : 'noperm');
				return;
			}

			my %urls;
			for my $item (@$enc) {
				next unless $item->{url};
				my $plain = eval { Plugins::Ximalaya::XimaCrypt->decrypt_url($item->{url}) };
				$log->error("Ximalaya: decrypt failed for $item->{type}: $@") if $@;
				$urls{ $item->{type} } = $plain if $plain;
			}

			my $quality = $prefs->get('quality') || 64;
			my ($url, $picked);
			for my $type (@{ $QUALITY_ORDER{$quality} || $QUALITY_ORDER{64} }) {
				if ($urls{$type}) { $url = $urls{$type}; $picked = $type; last; }
			}

			unless ($url) {
				my @types = keys %urls;
				$ecb->('nourl'), return unless @types;
				$picked = $types[0];
				$url = $urls{ $picked };
			}

			# set log.plugin.ximalaya=DEBUG to audit which tier actually got picked
			$log->debug("Ximalaya: track $trackId quality=$quality picked=$picked");

			$cb->({
				trackId    => $trackId,
				title      => $info->{title} // "Track $trackId",
				authorized => $info->{isAuthorized} // 0,
				paid       => $info->{isPaid} // 0,
				quality    => $url =~ /\.mp3/ ? 'mp3' : 'm4a',
				cover      => $class->_norm_cover(
					$info->{coverLarge} || $info->{coverMiddle} || $info->{coverSmall}),
				url        => $url,
			});
		},
		$ecb,
	);

	return;
}

1;

__END__

=head1 NAME

Plugins::Ximalaya::API - async Ximalaya endpoint wrappers

=head1 SYNOPSIS

  Plugins::Ximalaya::API->resolveTrack($trackId,
      sub { my ($info) = @_; ... $info->{url} ... },
      sub { my ($errcode) = @_; ... },
  );

=cut
