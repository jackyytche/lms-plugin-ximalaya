#!/usr/bin/perl
# pc_stub_test.pl - offline tests for the 0.1.12 pc (desktop-client) channel.
# Zero network. Covers:
#   - XimaCrypt::decrypt_url_win against the REAL 2026-08-16 device=win
#     capture (fixtures_pc.json winvector -> winPlainUrl, golden vector)
#   - play/v1/show reply parsing (real 2026-09-10 shapes)
#   - track/quality reply parsing (real 2026-09-10 shape; paid variant)
#   - pc device triple build + pref persistence (uuid stays stable)
#   - request wiring: routes, query params, headers (sign/cookie/referer)
#   - resolveTrack routing: quality -> baseInfo win -> web fallback chain
#   - Plugin albumHandler fallback: web first, pc page math, hasMore totals
# Run before every release, together with compile_check.pl.
use strict;
use warnings;
no warnings qw(once redefine);   # test-only typeglob overrides below trip both
use constant INFOLOG => 0;
use constant WEBUI  => 1;

# UTF-8 literals below (fixture comparisons); without this pragma the
# eq comparisons against utf8-flagged decoded JSON would fail.
use utf8;

use FindBin;
use lib File::Spec->catdir($FindBin::Bin);
use lib File::Spec->catdir($FindBin::Bin, 'Plugins', 'Ximalaya');

use JSON::PP ();
use Encode qw();
use Slim::Utils::Prefs;   # imports preferences() into main for the test itself

require Slim::Player::ProtocolHandlers;   # stub; ProtocolHandler.pm registers at compile time
require Plugins::Ximalaya::XimaCrypt;
require Plugins::Ximalaya::Sign;
require Plugins::Ximalaya::API;
require Plugins::Ximalaya::Plugin;

my $fail = 0;
my $n    = 0;
sub check {
	my ($name, $ok) = @_;
	$n++;
	$fail++ unless $ok;
	print($ok ? "ok   - $name\n" : "FAIL - $name\n");
}

my $api   = 'Plugins::Ximalaya::API';
my $prefs = preferences('plugin.ximalaya');
$prefs->init({ cookie => '', quality => 128, albums => '', pc_channel => 1, pc_device_id => '' });

# load fixtures (decoded text, mirroring what from_json hands the parser)
my $fixfile = File::Spec->catfile($FindBin::Bin, 'fixtures_pc.json');
open my $fh, '<:encoding(UTF-8)', $fixfile or die "cannot read $fixfile: $!";
local $/;
my $fx = JSON::PP->new->decode(<$fh>);
close $fh;

# ------------------------------------------------------------------ win crypto
{
	check('ximacrypt: load selftest', Plugins::Ximalaya::XimaCrypt->selftest_ok);

	my $plain = Plugins::Ximalaya::XimaCrypt->decrypt_url_win(
		$fx->{winvector}{trackInfo}{playUrlList}[0]{url});
	check('win: real capture decrypts to the captured PAID_URL',
		defined $plain && $plain eq $fx->{winPlainUrl});

	check('win: plain http passthrough',
		Plugins::Ximalaya::XimaCrypt->decrypt_url_win('http://aod.cos.tx.xmcdn.com/x.m4a')
			eq 'http://aod.cos.tx.xmcdn.com/x.m4a');

	check('win: short garbage -> undef',
		!defined Plugins::Ximalaya::XimaCrypt->decrypt_url_win('AAAA'));

	check('win: empty input -> undef',
		!defined Plugins::Ximalaya::XimaCrypt->decrypt_url_win(''));
}

# ------------------------------------------------------------ device triple
{
	$prefs->set('pc_device_id', '');
	my $ck1 = $api->_pc_device_cookie();
	my $stored = $prefs->get('pc_device_id') || '';
	check('device: uuid generated + persisted (v4 shape)',
		$stored =~ /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
	check('device: cookie format matches the verified triple',
		$ck1 eq "install_id=$stored; channel=99&100001; 1&_device=win32&$stored&4.0.14");
	my $ck2 = $api->_pc_device_cookie();
	check('device: stable across calls (no churn)', $ck2 eq $ck1);
	$prefs->set('pc_device_id', '01234567-89ab-4cde-8f01-23456789abcd');
	my $ck3 = $api->_pc_device_cookie();
	check('device: existing pref value is kept, not regenerated',
		$ck3 eq 'install_id=01234567-89ab-4cde-8f01-23456789abcd'
		. '; channel=99&100001; 1&_device=win32&01234567-89ab-4cde-8f01-23456789abcd&4.0.14');
	$prefs->set('pc_device_id', '');
}

# ------------------------------------------------------------ enabled gate
{
	$prefs->set('pc_channel', 1);
	check('enabled: pref on + master on', $api->pc_enabled == 1);
	{
		local $Plugins::Ximalaya::API::PC_CHANNEL_ENABLED = 0;
		check('enabled: master switch off wins', $api->pc_enabled == 0);
	}
	$prefs->set('pc_channel', 0);
	check('enabled: user pref off wins', $api->pc_enabled == 0);
	$prefs->set('pc_channel', 1);
}

# ------------------------------------------------------------ show parsing
{
	my ($tracks, $more, $err) = $api->_parse_show_tracks($fx->{showFree});
	check('show: parsed 2 tracks, hasMore=1', $tracks && @$tracks == 2 && $more == 1 && !defined $err);
	check('show: trackId/trackName mapping',
		$tracks->[0]{id} == 549382127 && $tracks->[0]{title} =~ /西溪的晴雨/);
	check('show: bare storages cover absolutized',
		$tracks->[0]{cover} eq 'https://imagev2.xmcdn.com/storages/56b8-audiofreehighqps/27/45/GMCoOScJjrMoAAKtOQKiZobF.jpeg');
	check('show: protocol-relative cover absolutized',
		$tracks->[1]{cover} eq 'https://imagev2.xmcdn.com/storages/0cfb-audiofreehighqps/F8/BE/GMCoOR8JYZlTAAKtOQKS8T35.jpeg');
	check('show: no isPaid in payload -> paid=0', $tracks->[0]{paid} == 0);

	($tracks, $more, $err) = $api->_parse_show_tracks($fx->{showLast});
	check('show: last page hasMore=0', $tracks && @$tracks == 1 && $more == 0);

	($tracks, $more, $err) = $api->_parse_show_tracks($fx->{showRisk});
	check('show: soft risk -> (undef, risk)', !defined $tracks && $err eq 'risk');
	($tracks, $more, $err) = $api->_parse_show_tracks($fx->{showEmpty});
	check('show: empty payload -> (undef, empty)', !defined $tracks && $err eq 'empty');
}

# -------------------------------------------------------- quality parsing
{
	my ($urls, $meta, $err) = $api->_parse_track_quality($fx->{qualityFree});
	check('quality: parse ok', defined $urls && !defined $err);
	check('quality: AacV224 field maps to M4A_24 tier (NOT 224k)',
		($urls->{M4A_24} || '') eq 'http://aod.cos.tx.xmcdn.com/storages/0071-audiofreehighqps/9A/CB/free_224.m4a');
	check('quality: MP3_128 absent (hq empty string)', !exists $urls->{MP3_128});
	check('quality: M4A_64 / MP3_64 / MP3_32 present',
		$urls->{M4A_64} && $urls->{MP3_64} && $urls->{MP3_32});
	my $joined = join ' ', values %$urls;
	# 0.1.18: originPlayPath is now mapped when it is a FULL plaintext URL
	check('quality: ORIGIN mapped from full plaintext URL',
		exists $urls->{ORIGIN} && $urls->{ORIGIN} =~ /free_origin\.mp3$/);
	check('quality: download paths still NOT mapped', $joined !~ /download/);
	check('quality: meta title/paid/albumId',		$meta->{title} =~ /伊朗打航母/ && $meta->{paid} == 0 && $meta->{albumId} == 81078584);
	# 0.1.24: per-tier sizes + duration power the free-track bitrate display
	check('quality: per-tier sizes mapped (ORIGIN/M4A_64/M4A_24/MP3_64/MP3_32)',
		$meta->{sizes}{ORIGIN} == 34273058 && $meta->{sizes}{M4A_64} == 8625530
		&& $meta->{sizes}{M4A_24} == 3298176 && $meta->{sizes}{MP3_64} == 8523276
		&& $meta->{sizes}{MP3_32} == 4261765);
	check('quality: absent tier (hq empty string) has no size entry; duration present',
		!exists $meta->{sizes}{MP3_128} && $meta->{duration} == 1065);

	($urls, $meta, $err) = $api->_parse_track_quality($fx->{qualityPaid});
	check('quality: paid reply parses OK with EMPTY url map (success, not error)',
		defined $urls && !keys %$urls && !defined $err && $meta->{paid} == 1);
	check('quality: paid reply sizes present without urls, duration absent',
		$meta->{sizes}{MP3_128} == 1545465 && $meta->{sizes}{M4A_64} == 778633
		&& !defined $meta->{duration});

	my ($pf) = $api->_parse_track_quality($fx->{qualityFree});
	my ($u128) = $api->_pick($pf, [qw(MP3_128 M4A_64 MP3_64 M4A_24 MP3_32)]);
	check('pick: pref 128 skips missing HQ -> M4A_64',
		($u128 || '') eq 'http://aod.cos.tx.xmcdn.com/storages/b3c0-audiofreehighqps/6D/57/free_164.m4a');
	my ($u32) = $api->_pick($pf, [qw(MP3_32 M4A_24)]);
	check('pick: pref 32 -> MP3_32 first',
		($u32 || '') eq 'http://aod.cos.tx.xmcdn.com/storages/3734-audiofreehighqps/29/E6/free_32.mp3');
}

# ------------------------------------------ album/simple cover (0.1.24)
# probe m0/diag_album_cover.py (real reply 2026-09-11, album 83701277): cover
# is PROTOCOL-RELATIVE ("//imagev2.xmcdn.com/..."), there is NO tracksCount
# (0.1.15 lesson) and the announcer lives in anchorName. 0.1.23 and earlier
# passed the raw cover through - my-albums covers broke in Daphile.
{
	check('cover: // relative -> https absolute',
		$api->_norm_cover('//imagev2.xmcdn.com/a/b.jpeg') eq 'https://imagev2.xmcdn.com/a/b.jpeg');
	check('cover: bare storages path -> imagev2 absolute',
		$api->_norm_cover('storages/ab-cd/x.jpeg') eq 'https://imagev2.xmcdn.com/storages/ab-cd/x.jpeg');
	check('cover: http upgraded, https untouched, empty/undef stay empty',
		$api->_norm_cover('http://imagev2.xmcdn.com/a.jpg') eq 'https://imagev2.xmcdn.com/a.jpg'
		&& $api->_norm_cover('https://imagev2.xmcdn.com/a.jpg') eq 'https://imagev2.xmcdn.com/a.jpg'
		&& $api->_norm_cover('') eq '' && $api->_norm_cover(undef) eq '');

	my ($info, $via);
	local *Plugins::Ximalaya::API::_json_get = sub {
		my ($class, $u, $h, $cb, $ecb, $cache) = @_;
		$cb->($fx->{albumSimple});
		return;
	};
	$api->albumInfo('83701277',
		sub { $via = 'cb'; $info = shift; },
		sub { $via = 'ecb' });
	check('albumInfo: cb path, title/anchorName/paid mapped',
		$via eq 'cb' && $info->{title} =~ /黑化/ && $info->{announcer} eq '头陀渊讲故事'
		&& $info->{paid} == 1);
	check('albumInfo: protocol-relative cover absolutized (my-albums crash fix)',
		$info->{cover} eq 'https://imagev2.xmcdn.com/storages/16c3-audiofreehighqps/CE/88/GAqhVp8MSkJhAAM2DAPhxNQf.jpeg');
	check('albumInfo: no tracksCount in real reply -> undef; isFinished truthy',
		!defined $info->{tracksCount} && $info->{finished});
}

# ------------------------------------------------------------- show wiring
{
	# zero-network short-circuit with the master switch off
	{
		local $Plugins::Ximalaya::API::PC_CHANNEL_ENABLED = 0;
		my $sign_called = 0;
		local *Plugins::Ximalaya::Sign::gen = sub { $sign_called = 1 };
		my ($got, $via);
		$api->albumTracksShow('12148879', 1, 50,
			sub { $via = 'cb' },
			sub { $got = shift; $via = 'ecb' });
		check('show: master off -> ecb(todo), zero network', $via eq 'ecb' && $got eq 'todo' && !$sign_called);
	}

	my ($url, $headers);
	local *Plugins::Ximalaya::Sign::gen = sub {
		my ($class, $cb, $ecb) = @_;
		$cb->('STUBSIGN');
	};
	local *Plugins::Ximalaya::API::_json_get = sub {
		my ($class, $u, $h, $cb, $ecb) = @_;
		($url, $headers) = ($u, $h);
		$cb->($fx->{showFree});
		return;
	};
	my ($tracks, $more, $via);
	$prefs->set('cookie', '1&_token=test');   # web login cookie for header build
	$api->albumTracksShow('12148879', 2, 50,
		sub { $via = 'cb'; ($tracks, $more) = @_; },
		sub { $via = 'ecb' });
	check('show: callback path taken', $via eq 'cb');
	check('show: route + VERIFIED size elasticity (0.1.14 probe: size=50 honored)',
		$url =~ m{^https://pc\.ximalaya\.com/simple-revision-for-pc/play/v1/show\?id=12148879&num=2&sort=0&size=50&ptype=0$}) if defined $url;
	check('show: real xm-sign header attached', $headers->{'xm-sign'} eq 'STUBSIGN');
	check('show: pc album Referer + pc Origin',
		$headers->{'Referer'} eq 'https://pc.ximalaya.com/album/12148879'
		&& $headers->{'Origin'} eq 'https://pc.ximalaya.com');
	my ($id1, $id2) = (($headers->{'Cookie'} || '') =~
		/^1&_token=test; install_id=([0-9a-f-]{36}); channel=99&100001; 1&_device=win32&([0-9a-f-]{36})&4\.0\.14$/);
	check('show: cookie = web cookie + device triple (same uuid twice)',
		defined $id1 && defined $id2 && $id1 eq $id2);
	check('show: cb gets tracks + hasMore', $tracks && @$tracks == 2 && $more == 1);

	# 0.1.14 probe: server honors 50 but clamps 100 -> client clamps to 50
	$api->albumTracksShow('12148879', 1, 100,
		sub { }, sub { });
	check('show: oversized size clamped to verified max 50',
		$url =~ m{&size=50&ptype=0$}) if defined $url;
}

# ---------------------------------------------------------- quality wiring
{
	my ($url, $headers);
	local *Plugins::Ximalaya::API::_json_get = sub {
		my ($class, $u, $h, $cb, $ecb) = @_;
		($url, $headers) = ($u, $h);
		$cb->($fx->{qualityFree});
		return;
	};
	my ($urls, $meta, $via);
	$api->trackQuality('1012852891',
		sub { $via = 'cb'; ($urls, $meta) = @_; },
		sub { $via = 'ecb' });
	check('quality: callback path taken', $via eq 'cb');
	check('quality: route /track/quality/{id}/{ms_ts}',
		$url =~ m{^https://mobile\.ximalaya\.com/mobile-playpage/playpage/track/quality/1012852891/\d+$}) if defined $url;
	check('quality: anonymous exactly as verified (no Cookie, no xm-sign)',
		!exists $headers->{'Cookie'} && !exists $headers->{'xm-sign'});
}

# ------------------------------------------------------- resolveTrack chain
{
	# URL-keyword routed _json_get stub shared by the chain tests
	my %routes;    # keyword => [mode, payload]
	my @hits;
	local *Plugins::Ximalaya::API::_json_get = sub {
		my ($class, $u, $h, $cb, $ecb) = @_;
		for my $kw (sort keys %routes) {
			if (index($u, $kw) >= 0) {
				my ($mode, $payload) = @{ $routes{$kw} };
				push @hits, $kw;
				$mode eq 'cb' ? $cb->($payload) : $ecb->($payload);
				return;
			}
		}
		die "unexpected URL in test: $u";
	};
	local *Plugins::Ximalaya::Sign::gen = sub {
		my ($class, $cb, $ecb) = @_;
		$cb->('STUBSIGN');
	};

	$api->_clear_resolve_cache;    # 0.1.25: keep scenarios independent

	# 1) free track: quality endpoint alone resolves it (no baseInfo call)
	%routes = ('track/quality' => ['cb', $fx->{qualityFree}]);
	@hits = ();
	my ($res, $via);
	$api->resolveTrack('1012852891',
		sub { $via = 'cb'; $res = shift; },
		sub { $via = 'ecb'; $res = shift; });
	check('resolve: free track -> single quality hit, cb path',
		$via eq 'cb' && @hits == 1 && $hits[0] eq 'track/quality');
	check('resolve: free track picks per pref 128 (HQ missing -> M4A_64), m4a',
		$res && ($res->{url} || '') =~ /free_164\.m4a$/ && $res->{quality} eq 'm4a');
	check('resolve: free track publishes bitrate/duration from aacV164Size (0.1.24)',
		$res->{duration} == 1065 && $res->{bitrate} == int(8625530 * 8 / 1065));

	# 2) paid track: quality returns no plaintext -> baseInfo WIN vector
	%routes = (
		'track/quality' => ['cb', $fx->{qualityPaid}],
		'baseInfo'      => ['cb', $fx->{winvector}],
	);
	@hits = ();
	$api->resolveTrack('759074956',
		sub { $via = 'cb'; $res = shift; },
		sub { $via = 'ecb'; $res = shift; });
	check('resolve: paid track -> quality then baseInfo, cb path',
		$via eq 'cb' && "@hits" eq 'track/quality baseInfo');
	check('resolve: paid track URL is the decrypted WIN capture',
		$res && $res->{url} eq $fx->{winPlainUrl} && $res->{paid} == 1);
	check('resolve: no duration in capture -> no bitrate published',
		$res && !exists $res->{bitrate} && !exists $res->{duration});

	# 3) pc chain broken -> blanket web (www2 sbox) fallback, verified vector
	my $webfx;
	{
		open my $wf, '<:encoding(UTF-8)', File::Spec->catfile($FindBin::Bin, 'fixtures.json')
			or die "cannot read fixtures.json: $!";
		local $/;
		$webfx = JSON::PP->new->decode(<$wf>);
		close $wf;
	}
	my $web_url_vec = $webfx->{urls}[0];
	my $web_baseinfo = {
		ret       => 0,
		trackInfo => {
			trackId     => 3,
			title       => 'web vector',
			isPaid      => 0,
			isAuthorized=> 1,
			playUrlList => [ { type => 'M4A_64', url => $web_url_vec->{enc} } ],
		},
	};
	%routes = (
		'track/quality' => ['ecb', 'http'],
		'baseInfo'      => ['cb', $web_baseinfo],
	);
	@hits = ();
	$api->resolveTrack('1',
		sub { $via = 'cb'; $res = shift; },
		sub { $via = 'ecb'; $res = shift; });
	check('resolve: quality failure falls back to web baseInfo (sbox path)',
		$via eq 'cb' && "@hits" eq 'track/quality baseInfo');
	check('resolve: web fallback URL equals the sbox golden plain',
		defined $res->{url} && Encode::decode_utf8($res->{url}, Encode::FB_CROAK() | Encode::LEAVE_SRC()) eq $web_url_vec->{plain});

	# 4) pc disabled -> straight to web, quality endpoint never touched
	{
		local $Plugins::Ximalaya::API::PC_CHANNEL_ENABLED = 0;
		%routes = ('baseInfo' => ['cb', $fx->{winvector}]);
		@hits = ();
		$api->resolveTrack('2',
			sub { $via = 'cb'; $res = shift; },
			sub { $via = 'ecb'; $res = shift; });
		check('resolve: pc off -> web only, zero quality requests',
			$via eq 'cb' && "@hits" eq 'baseInfo');
	}

	# ------------------------------------------------ 0.1.18 quality ladder
	# 5) pref 256 free track: ORIGIN (full plaintext URL) is the top pick
	{
		$api->_clear_resolve_cache;    # same id as scenario 1 - drop its entry
		$prefs->set('quality', 256);
		%routes = ('track/quality' => ['cb', $fx->{qualityFree}]);
		@hits = ();
		$api->resolveTrack('1012852891',
			sub { $via = 'cb'; $res = shift; },
			sub { $via = 'ecb'; $res = shift; });
		check('quality: pref 256 free track picks ORIGIN upload',
			$via eq 'cb' && ($res->{url} || '') =~ /free_origin\.mp3$/);
		check('resolve: ORIGIN bitrate from originSize/duration (0.1.24)',
			$res->{duration} == 1065 && $res->{bitrate} == int(34273058 * 8 / 1065));
		$prefs->set('quality', 128);
	}

	# bare-storages originPlayPath (VIP replies) must NOT be mapped
	{
		my ($u2) = $api->_parse_track_quality({
			ret => 0,
			data => { debugInfo => { debugDetailMap => { detailTrackDto => { result => {
				isPaid => 1,
				title  => 'bare origin',
				playPathDto => {
					originPlayPath  => 'storages/3ecc-x/Y.mp3',
					playPathAacV164 => 'http://aod.cos.tx.xmcdn.com/storages/a/ok.m4a',
				},
			} } } } } });
		check('quality: bare storages originPlayPath dropped, plaintext kept',
			$u2 && !exists $u2->{ORIGIN} && ($u2->{M4A_64} || '') =~ /ok\.m4a$/);
	}

	# 6) pref 256 paid track: level 3 is entitlement-gated (ret 1001) ->
	#    automatic one-step fallback to level 2 (M4A_128 tier present)
	{
		$prefs->set('quality', 256);
		my @urls_seen;
		my $lvl2_payload = {
			ret       => 0,
			trackInfo => {
				trackId => 759074956, title => 'lvl2', isPaid => 1, isAuthorized => 1,
				duration => 624,
				coverLarge => 'http://imagev2.xmcdn.com/storages/l2/cover_large.jpg',
				playUrlList => [
					{ type => 'M4A_128', qualityLevel => 2, url => 'http://aod.cos.tx.xmcdn.com/storages/l2/track_128.m4a', fileSize => 7555956 },
					{ type => 'M4A_64',  qualityLevel => 1, url => $fx->{winvector}{trackInfo}{playUrlList}[0]{url} },
				],
			},
		};
		local *Plugins::Ximalaya::API::_json_get = sub {
			my ($class, $u, $h, $cb, $ecb) = @_;
			if ($u =~ /mobile-playpage\/playpage\/track\/quality/) {
				$cb->($fx->{qualityPaid});    # no plaintext -> win chain
				return;
			}
			push @urls_seen, $u if $u =~ /baseInfo/;
			if ($u =~ /trackQualityLevel=3/) { $cb->({ ret => 1001 }); return; }
			if ($u =~ /trackQualityLevel=2/) { $cb->($lvl2_payload); return; }
			die "unexpected URL in test: $u";
		};
		$api->_clear_resolve_cache;    # same id as scenario 2 - drop its entry
		@hits = ();
		$api->resolveTrack('759074956',
			sub { $via = 'cb'; $res = shift; },
			sub { $via = 'ecb'; $res = shift; });
		check('quality: pref 256 paid track level 3 gated -> falls back to level 2',
			$via eq 'cb' && ($res->{url} || '') =~ /track_128\.m4a$/);
		check('quality: bitrate computed from fileSize/duration (96k for the 128 tier)',
			$res && $res->{duration} == 624
			&& $res->{bitrate} == int(7555956 * 8 / 624));
		check('quality: coverLarge passed through and https-ized',
			$res && ($res->{cover} || '') eq 'https://imagev2.xmcdn.com/storages/l2/cover_large.jpg');
		check('quality: fallback requested level 3 then level 2',
			@urls_seen == 2
			&& $urls_seen[0] =~ /trackQualityLevel=3/
			&& $urls_seen[1] =~ /trackQualityLevel=2/);
		# level parameter is clamped/passed verbatim for plain 128 too
		$prefs->set('quality', 128);
		$api->_clear_resolve_cache;    # lvl2 url from the resolve above is cached
		@urls_seen = ();
		%routes = (
			'track/quality' => ['cb', $fx->{qualityPaid}],
			'baseInfo'      => ['cb', $fx->{winvector}],
		);
		$api->resolveTrack('759074956',
			sub { $via = 'cb'; $res = shift; },
			sub { $via = 'ecb'; $res = shift; });
		check('quality: pref 128 requests trackQualityLevel=2',
			$via eq 'cb' && @urls_seen == 1 && $urls_seen[0] =~ /trackQualityLevel=2/);
		$prefs->set('quality', 128);
	}
}

# ------------------------------------------- 0.1.25 resolve cache + seek path
# Root cause fixed here: a progress-bar seek rebuilds the song and re-runs
# scanUrl; the ~1.5-3.5s async resolve gap made LMS drop the seekdata and
# restart from 0. A fresh cache entry lets scanUrl answer in-place.
{
	package TSongFake;
	sub new {
		my ($class, %a) = @_;
		return bless { currentTrack => 'THETRACK', streamUrl => undef, %a }, $class;
	}
	sub currentTrack { $_[0]->{currentTrack} }
	sub streamUrl    { my $s = shift; $s->{streamUrl} = $_[0] if @_; $s->{streamUrl} }
}

{
	my ($url, $headers);
	local *Plugins::Ximalaya::API::_json_get = sub {
		my ($class, $u, $h, $cb, $ecb) = @_;
		($url, $headers) = ($u, $h);
		$cb->($fx->{qualityFree});
		return;
	};

	$api->_clear_resolve_cache;   # outer lexical: string package name, file scope

	# priming: the first resolve goes through the stubbed fetcher and stores
	local *Plugins::Ximalaya::Sign::gen = sub { my ($class, $cb) = @_; $cb->('STUBSIGN') };
	my $r1;
	$api->resolveTrack('1012852891', sub { $r1 = shift }, sub { });
	check('cache: priming resolve stored (1 fetch, url in hand)',
		defined $r1 && ($r1->{url} || '') =~ /free_164\.m4a$/ && defined $api->peek_resolve('1012852891'));

	# sync re-serve: zero requests, same resolve content
	my (@hits2, $r2, $sync);
	local *Plugins::Ximalaya::API::_json_get = sub {
		my ($class, $u, $h, $cb, $ecb) = @_;
		push @hits2, $u;
		$cb->($fx->{qualityFree});
		return;
	};
	$api->resolveTrack('1012852891', sub { $sync = 1; $r2 = shift }, sub { });
	check('cache: second resolve is synchronous with ZERO requests',
		$sync && @hits2 == 0 && $r2->{url} eq $r1->{url});

	# scanUrl seek fast-path: with a primed cache the handler answers IN-PLACE
	# (cb before scanUrl returns - no SUPER::scanUrl scanner hop) and swaps
	# the stream URL. In-place cb is what keeps LMS's seekdata alive.
	my $song  = TSongFake->new;
	my ($cb_track, $inplace);
	Plugins::Ximalaya::ProtocolHandler->scanUrl('xmly://track/1012852891', {
		song => $song,
		cb   => sub { $inplace = 1; $cb_track = shift },
	});
	check('seek: scanUrl answered synchronously (no async scanner hop)',
		$inplace && @hits2 == 0);
	check('seek: scanUrl handed back the song\'s current track object',
		defined $cb_track && $cb_track eq 'THETRACK');
	check('seek: scanUrl swapped streamUrl to the cached CDN url',
		($song->streamUrl || '') eq $r1->{url});
	my ($meta_call) = grep { $_->[0] eq 'xmly://track/1012852891' } @{ Slim::Music::Info->remote_meta };
	check('seek: fast-path republished remote metadata (secs/bitrate/ct)',
		$meta_call && $meta_call->[1]{ct} eq 'audio/mp4'
		&& $meta_call->[1]{secs} == 1065
		&& $meta_call->[1]{bitrate} == int(8625530 * 8 / 1065 / 1000));

	# cleanup so later blocks start clean
	$api->_clear_resolve_cache;
	check('cache: clear wipes the entry', !defined $api->peek_resolve('1012852891'));
}

# ------------------------------------------------- Plugin albumHandler chain
# 0.1.16: mobile list FIRST (paid/VIP albums: exact totalCount + isPaid in
# one shot), its EMPTY reply (typical free album) falls to pc show (hasMore
# estimate), then web. Cooldown families: tracks_mobile / tracks /
# tracks_web. Single id-routed stub trio (no local re-overrides):
#   mobile: 555/999 -> ecb('empty') (free album, no cooling);
#           else    -> page1 ([2 tracks, first paid], total=1388)
#   pc:     555/999 -> fail('empty');  777 -> last page ([1], hasMore=0);
#           else    -> page1 ([2 tracks], hasMore=1)
#   web:    999     -> fail('1005');   else -> success ([1 track], total=1388)
# NOTE: cooldown-planting tests must stay in the LAST block below.
{
	$prefs->set('quality', 128);
	$prefs->set('mobile_channel', 1);   # initPlugin default (stub env skips init)
	my @calls;
	my @sizes;   # "album:page:size" the handler asked each tier for (0.1.51)
	local *Plugins::Ximalaya::API::albumTracksMobile = sub {
		my ($class, $albumId, $page, $size, $cb, $ecb) = @_;
		push @calls, "mobile:$albumId:$page";
		if ($albumId == 555 || $albumId == 777 || $albumId == 888 || $albumId == 999 || $albumId == 601) { $ecb->('empty'); return; }
		$cb->([
			{ id => 759074956, title => 'm1', paid => 1,
				cover => 'https://imagev2.xmcdn.com/group21/M0A/1A/1B/wKgJDFm1_T87x87.jpg',
				duration => 1065 },
			{ id => 759074957, title => 'm2', paid => 0,
				cover => 'https://imagev2.xmcdn.com/group21/M0A/1A/1B/wKgJDFm2_T250x250.jpg',
				duration => 977 },
		], 1388);
	};
	local *Plugins::Ximalaya::API::albumTracksShow = sub {
		my ($class, $albumId, $page, $size, $cb, $ecb) = @_;
		push @calls, "pc:$albumId:$page";
		push @sizes, "$albumId:$page:$size";
		if ($albumId == 601) {
			# realistic full pages: the pc tier honours size<=PC_SHOW_MAX, so a
			# wider UI window needs several requests (0.1.51)
			my @rows = map {
				{ id => ($page - 1) * $size + $_, title => "t$_", paid => 0,
				  cover => 'https://c/x.jpg', duration => 600 }
			} 1 .. $size;
			$cb->(\@rows, $page < 2 ? 1 : 0);
			return;
		}
		if ($albumId == 555 || $albumId == 999) { $ecb->('empty'); return; }
		if ($albumId == 777) { $cb->([ { id => 9, title => 'last', paid => 0, cover => '', duration => 840 } ], 0); return; }
		$cb->([
			{ id => 1, title => 't1', paid => 0, cover => '', duration => 600 },
			{ id => 2, title => 't2', paid => 0, cover => '', duration => 700 },
		], 1);
	};
	local *Plugins::Ximalaya::API::albumTracks = sub {
		my ($class, $albumId, $page, $size, $cb, $ecb) = @_;
		push @calls, "web:$albumId:$page:$size";
		if ($albumId == 999) { $ecb->('1005'); return; }
		$cb->([ { id => 5, title => 'vip track', paid => 1, cover => '' } ], 1388);
	};

	my ($out, $client) = ({}, bless({}, 'StubClient'));

	# VIP album: mobile one-shot list + EXACT total (no pc, no web, no meta)
	Plugins::Ximalaya::Plugin::albumHandler($client, sub { $out = shift },
		{ index => 0, quantity => 50 }, 83701277);
	check('album: VIP album served by mobile list, one request',
		"@calls" eq 'mobile:83701277:1' && $out->{offset} == 0
		&& @{ $out->{items} || [] } == 2);
	check('album: feed-level actions = *all only, NO plain play/add (web row poison, 0.1.40)',
		join('|', @{ $out->{actions}{playall}{command} || [] }) eq 'playlist|play|xmly://album/83701277'
		&& join('|', @{ $out->{actions}{addall}{command} || [] }) eq 'playlist|add|xmly://album/83701277'
		&& join('|', @{ $out->{actions}{insert}{command} || [] }) eq 'playlist|insert|xmly://album/83701277'
		&& !exists $out->{actions}{play}
		&& !exists $out->{actions}{add});
	check('album: feed image = album artwork at the top of the WEB page, UPSIZED to original (0.1.40/0.1.42)',
		($out->{image} || '') eq 'https://imagev2.xmcdn.com/group21/M0A/1A/1B/wKgJDFm1.jpg');
	check('cover: _cover_large strips _T<W>x<H> and legacy !<W>x<H> tiers only before the extension',
		Plugins::Ximalaya::API->_cover_large('https://imagev2.xmcdn.com/g/M0/1/2/!##pX_T600x600.jpg')
			eq 'https://imagev2.xmcdn.com/g/M0/1/2/!##pX.jpg'
		&& Plugins::Ximalaya::API->_cover_large('https://a/b/cover!250x250.jpg') eq 'https://a/b/cover.jpg'
		&& Plugins::Ximalaya::API->_cover_large('https://a/b/plain.jpg')     eq 'https://a/b/plain.jpg'
		&& Plugins::Ximalaya::API->_cover_large('//imagev2.xmcdn.com/x_T87x87.jpg')
			eq 'https://imagev2.xmcdn.com/x.jpg');
	check('album: track items carry DEFINED duration (itemsHaveAudio trigger, 0.1.40)',
		defined $out->{items}[0]{duration} && $out->{items}[0]{duration} == 1065
		&& defined $out->{items}[1]{duration} && $out->{items}[1]{duration} == 977);
	check('album: feed play = songinfo playUrl trigger (0.1.41)',
		($out->{play} || '') eq 'xmly://album/83701277');

	# 0.1.41: widened passthrough (id, title, announcer) -> songinfo header
	# labels via feed-level albumData (web calls coderefs with @pt spread).
	# 0.1.42: + cover - the ALBUM cover is the header image source (the
	# track list API's per-track covers vary in size tier).
	Plugins::Ximalaya::Plugin::albumHandler($client, sub { $out = shift },
		{ index => 0, quantity => 50 }, 83701277, '大明王朝', '王更新',
		'https://imagev2.xmcdn.com/group21/M0A/9C/9D/wKgJDalbum_T250x250.jpg');
	check('album: albumData labels ALBUM/ARTIST feed the songinfo header (0.1.41)',
		ref $out->{albumData} eq 'ARRAY'
		&& @{ $out->{albumData} } == 2
		&& ($out->{albumData}[0]{label} || '') eq 'ALBUM' && ($out->{albumData}[0]{name} || '') eq '大明王朝'
		&& ($out->{albumData}[1]{label} || '') eq 'ARTIST' && ($out->{albumData}[1]{name} || '') eq '王更新'
		&& ($out->{albumData}[0]{type} || '') eq 'text');
	check('album: header image = the ALBUM cover, upsized to original (0.1.42)',
		($out->{image} || '') eq 'https://imagev2.xmcdn.com/group21/M0A/9C/9D/wKgJDalbum.jpg');
	check('album: EXACT total=1388 from mobile totalCount, +1 for the trailing play-all row',
		$out->{total} == 1389);
	check('album: per-track isPaid restored ([VIP] prefix on mobile data)',
		($out->{items}[0]{name} || '') =~ /^\[VIP\]/ && ($out->{items}[1]{name} || '') !~ /VIP/);

	# page math still UI-width: index=50 -> page 2, offset 50, numbering 51
	# (m1 is paid -> [VIP] prefix precedes the number)
	@calls = ();
	Plugins::Ximalaya::Plugin::albumHandler($client, sub { $out = shift },
		{ index => 50, quantity => 50 }, 83701277);
	check('album: mobile page 2 at offset 50, numbering starts at 51',
		"@calls" eq 'mobile:83701277:2' && $out->{offset} == 50
		&& ($out->{items}[0]{name} || '') =~ /^\[VIP\] 51\./ && $out->{total} == 1389);

	# free album: mobile empty -> pc fail -> web success (quantity page math)
	@calls = ();
	Plugins::Ximalaya::Plugin::albumHandler($client, sub { $out = shift },
		{ index => 0, quantity => 50 }, 555);
	check('album: free album + pc failure falls through to web',
		"@calls" eq 'mobile:555:1 pc:555:1 web:555:1:50'
		&& $out->{offset} == 0 && @{ $out->{items} || [] } == 1 && $out->{total} == 1389);

	# free album served by pc show: hasMore=1 -> estimate off+n+qty (52)
	@calls = ();
	Plugins::Ximalaya::Plugin::albumHandler($client, sub { $out = shift },
		{ index => 0, quantity => 50 }, 888);
	check('album: free album (mobile empty) served by pc show, estimate total',
		"@calls" eq 'mobile:888:1 pc:888:1' && $out->{total} == 53);

	# free album last pc page: hasMore=0 -> exact off+n (1); the window
	# covers the trailing play-all position -> row renders on this page
	@calls = ();
	Plugins::Ximalaya::Plugin::albumHandler($client, sub { $out = shift },
		{ index => 0, quantity => 50 }, 777);
	check('album: free album last pc page -> exact total (off+n=1)',
		$out->{total} == 2 && "@calls" eq 'mobile:777:1 pc:777:1');
	check('album: trailing play-whole-album row with xmly://album play url',
		@{ $out->{items} || [] } == 2
		&& ($out->{items}[1]{name} || '') eq 'PLUGIN_XIMALAYA_PLAY_ALL'
		&& $out->{items}[1]{type} eq 'audio'
		&& ($out->{items}[1]{play} || '') eq 'xmly://album/777');

	# all three paths failing -> single error item (no dead feed)
	@calls = ();
	Plugins::Ximalaya::Plugin::albumHandler($client, sub { $out = shift },
		{ index => 0, quantity => 50 }, 999);
	check('album: mobile+pc+web failure surfaces one error item',
		"@calls" eq 'mobile:999:1 pc:999:1 web:999:1:50'
		&& $out->{items} && @{ $out->{items} } == 1 && $out->{items}[0]{type} eq 'text');

	# 0.1.51 WINDOW FILLING: the old code clamped the UI window to
	# PC_SHOW_MAX(50) and returned the clamped list, so a wider window came back
	# short and XMLBrowser padded the missing slots with EMPTY rows (no artwork,
	# no id -> "API error" when tapped; measured on device: 60-wide window on a
	# 211-track album -> 50 tracks + 10 empty rows). Album 601 serves realistic
	# full pages (size<=50, hasMore for page 1 only).
	{
		@calls = ();
		@sizes = ();
		Plugins::Ximalaya::Plugin::albumHandler($client, sub { $out = shift },
			{ index => 0, quantity => 60 }, 601);
		check('0.1.51: a 60-wide window is filled from two pc pages (no short window)',
			"@calls" eq 'mobile:601:1 pc:601:1 pc:601:2'
			&& "@sizes" eq '601:1:50 601:2:50'
			&& @{ $out->{items} || [] } == 60
			&& $out->{offset} == 0);

		@calls = ();
		@sizes = ();
		Plugins::Ximalaya::Plugin::albumHandler($client, sub { $out = shift },
			{ index => 0, quantity => 50 }, 601);
		check('0.1.51: a 50-wide window still costs exactly one pc request',
			"@calls" eq 'mobile:601:1 pc:601:1' && @{ $out->{items} || [] } == 50);

		@calls = ();
		@sizes = ();
		Plugins::Ximalaya::Plugin::albumHandler($client, sub { $out = shift },
			{ index => 60, quantity => 50 }, 601);
		check('0.1.51: index=60 skips inside the server page and fills the window',
			"@calls" eq 'mobile:601:2 pc:601:2 pc:601:3' && $out->{offset} == 60
			&& @{ $out->{items} || [] } == 51   # 50 tracks + the trailing play-all row
			&& ($out->{items}[0]{name} || '') =~ /^61\./
			&& ($out->{items}[50]{name} || '') eq 'PLUGIN_XIMALAYA_PLAY_ALL');
	}

	# pc off -> web-only (pre-0.1.12 behaviour), mobile+pc never touched
	{
		$prefs->set('pc_channel', 0);
		@calls = ();
		Plugins::Ximalaya::Plugin::albumHandler($client, sub { $out = shift },
			{ index => 0, quantity => 50 }, 83701277);
		check('album: pc off -> web only, web success path intact',
			"@calls" eq 'web:83701277:1:50' && $out->{total} == 1389);
		$prefs->set('pc_channel', 1);
	}

	# 0.1.17: user pref mobile_channel off -> straight to pc show (estimate)
	{
		$prefs->set('mobile_channel', 0);
		@calls = ();
		Plugins::Ximalaya::Plugin::albumHandler($client, sub { $out = shift },
			{ index => 0, quantity => 50 }, 83701277);
		check('album: mobile pref off -> straight to pc (no mobile call)',
			"@calls" eq 'pc:83701277:1' && $out->{total} == 53
			&& Plugins::Ximalaya::API->mobile_enabled == 0);
		$prefs->set('mobile_channel', 1);
		check('album: mobile pref restored -> enabled again',
			Plugins::Ximalaya::API->mobile_enabled == 1);
	}

	# ------------------------------------------------ ProtocolHandler metadata
	{
		check('handler: canTranscodeSeek declared (seek=2 -> $START$ passed to decoder)',
			Plugins::Ximalaya::ProtocolHandler->canTranscodeSeek() ? 1 : 0);
		Plugins::Ximalaya::ProtocolHandler->cache_metadata('xmly://track/759074956', {
			title => 't', cover => 'https://imagev2.xmcdn.com/storages/x/cover.jpg',
			duration => 624, bitrate => 96845, quality => 'm4a',
		});
		my $m = Plugins::Ximalaya::ProtocolHandler->getMetadataFor(undef, 'xmly://track/759074956');
		check('handler: getMetadataFor embeds rate into type string',
			$m && $m->{type} eq 'AAC 96kbps' && $m->{bitrate} eq '96kbps CBR'
			&& $m->{duration} == 624 && $m->{cover} =~ /cover\.jpg$/);
		my $e = Plugins::Ximalaya::ProtocolHandler->getMetadataFor(undef, 'xmly://track/none');
		check('handler: unknown url -> empty metadata', $e && !scalar keys %$e);

		# 0.1.30: ORIGIN-tier lossless streams (.flac uploads at 1000+ kbps)
		# must not be labelled AAC anymore
		check('handler: _suffix_quality reads codec from path suffix',
			Plugins::Ximalaya::API::_suffix_quality('http://x/aod.cos/a-48K.flac?sig=1') eq 'flac'
			&& Plugins::Ximalaya::API::_suffix_quality('http://x/a.mp3?sig=1') eq 'mp3'
			&& Plugins::Ximalaya::API::_suffix_quality('http://x/a.m4a?sig=1') eq 'm4a'
			&& Plugins::Ximalaya::API::_suffix_quality(undef) eq 'm4a');
		Plugins::Ximalaya::ProtocolHandler->cache_metadata('xmly://track/flac1', {
			title => 'flac t', cover => 'https://imagev2.xmcdn.com/storages/x/c.jpg',
			duration => 300, bitrate => 1058000, quality => 'flac',
		});
		my $f = Plugins::Ximalaya::ProtocolHandler->getMetadataFor(undef, 'xmly://track/flac1');
		check('handler: flac stream type shows FLAC not AAC',
			$f && $f->{type} eq 'FLAC 1058kbps' && $f->{bitrate} eq '1058kbps');
		{
			my $song = bless {}, 'XimaStubSong';
			*XimaStubSong::streamUrl = sub {
				my ($s, $u) = @_;
				$s->{u} = $u if defined $u;
				return $s->{u};
			};
			# 0.1.48/0.1.49 notify/bump target: a blessed client that records
			# the playlist-update stamp the polling Daphile skin watches.
			my $cli = bless { id => 'stubclient', stamps => [] }, 'XimaStubClient';
			*XimaStubClient::id = sub { $_[0]->{id} };
			*XimaStubClient::currentPlaylistUpdateTime = sub {
				my ($c, $t) = @_;
				push @{ $c->{stamps} }, $t if defined $t;
				return $c->{stamps}[-1];
			};
			*XimaStubSong::master = sub { $cli };
			Slim::Music::Info::reset_remote_meta();
			Slim::Control::Request::clear_notifications();
			Slim::Utils::Cache::clear_store();
			Plugins::Ximalaya::ProtocolHandler->_apply_resolve($song, 'xmly://track/flac2', {
				title => 'x', cover => 'https://imagev2.xmcdn.com/c.jpg',
				duration => 300, bitrate => 1058000, quality => 'flac',
				url => 'http://cdn/a.flac?t=1',
			});
			my $rm = Slim::Music::Info::remote_meta();
			my $last = $rm->[-1];
			check('handler: _apply_resolve publishes audio/flac ct + swaps stream url',
				$last && $last->[0] eq 'xmly://track/flac2' && $last->[1]{ct} eq 'audio/flac'
				&& $song->streamUrl eq 'http://cdn/a.flac?t=1');

			# 0.1.49: the Daphile skin (SqueezeJS) polls `status - 1 tags:uB`
			# and only re-reads the rich status when _needUpdate() spots a
			# change; playlist_timestamp is the only field we can move, so the
			# resolve must advance it or #ctrlBitrate stays empty until the
			# user does something (reload / pause).
			check('0.1.49: resolve advances the playlist-update stamp (polling UIs re-read status)',
				@{$cli->{stamps}} == 1 && $cli->{stamps}[0] > 0);

			# 0.1.48 kept for subscribing clients: the core's own late-metadata
			# signal 'playlist newmetadata' (SqueezePlayDirect::parseMetadata L107)
			my $notifs = Slim::Control::Request::notifications();
			check('0.1.48: resolve completion notifies playlist newmetadata (late-metadata signal)',
				@$notifs == 1
				&& $notifs->[0][0] eq 'stubclient'
				&& join('|', @{ $notifs->[0][1] }) eq 'playlist|newmetadata');

			# a seek re-runs _apply_resolve with everything already cached and
			# must NOT re-announce (no spurious client reloads)
			Plugins::Ximalaya::ProtocolHandler->_apply_resolve($song, 'xmly://track/flac2', {
				title => 'x', cover => 'https://imagev2.xmcdn.com/c.jpg',
				duration => 300, bitrate => 1058000, quality => 'flac',
				url => 'http://cdn/a.flac?t=2',
			});
			check('0.1.49: a re-resolve (seek) does not re-announce',
				@{$cli->{stamps}} == 1 && @{ Slim::Control::Request::notifications() } == 1);

			# 0.1.48: the codec/rate also go into the persistent cache, which is
			# the only place that survives a restart (the track row keeps
			# title/secs/cover, never the codec).
			my $tech = Slim::Utils::Cache->new->get('xmly_meta_xmly://track/flac2');
			check('0.1.48: resolve persists codec/rate for later processes',
				$tech && $tech->{type} eq 'FLAC 1058kbps'
				&& $tech->{bitrate} eq '1058kbps');

			# and the queue fallback serves them on an in-process cache miss
			# (fresh process / evicted entry) instead of an empty tech line
			Slim::Schema::clear_rows();
			Slim::Utils::Cache->new->set('xmly_meta_xmly://track/flac3',
				{ type => 'MP3 128kbps', bitrate => '128kbps CBR' }, '30 days');
			my $fb = Plugins::Ximalaya::ProtocolHandler->getMetadataFor(undef, 'xmly://track/flac3');
			check('0.1.48: queue fallback serves codec/rate from the persistent entry',
				$fb && $fb->{type} eq 'MP3 128kbps' && $fb->{bitrate} eq '128kbps CBR');
		}

		# 0.1.44: enqueue-time metadata publication + the getMetadataFor
		# queue fallback. The status query calls getMetadataFor for EVERY
		# queued row; without these, not-yet-played playlist rows rendered
		# blank (no title, no artwork, duration 0).
		{
			Slim::Music::Info::reset_remote_meta();
			Slim::Schema::clear_rows();
			Slim::Utils::Cache::clear_store();

			Plugins::Ximalaya::ProtocolHandler->_publish_queue_metadata([
				{ id => 101, title => 'ep1', paid => 0,
				  cover => 'https://c/101.jpg', duration => 600 },
				{ id => 102, title => '?', paid => 0, cover => '', duration => 0 },
			]);
			my $rm = Slim::Music::Info::remote_meta();
			check('handler: _publish_queue_metadata writes title/secs/cover, skips placeholder-only rows',
				@$rm == 1 && $rm->[0][0] eq 'xmly://101'
				&& $rm->[0][1]{title} eq 'ep1' && $rm->[0][1]{secs} == 600
				&& $rm->[0][1]{cover} eq 'https://c/101.jpg');

			# the stub Info mirrors the real persistence: row + remote_image_
			check('handler: publication persists into the track row + remote_image cache',
				Slim::Schema->get_row('xmly://101')->{title} eq 'ep1'
				&& Slim::Schema->get_row('xmly://101')->{secs} == 600
				&& Slim::Utils::Cache->new->get('remote_image_xmly://101') eq 'https://c/101.jpg');

			my $q = Plugins::Ximalaya::ProtocolHandler->getMetadataFor(undef, 'xmly://101');
			check('handler: getMetadataFor queue fallback rebuilds row + cached cover (no type until played)',
				$q && $q->{title} eq 'ep1' && $q->{duration} == 600
				&& $q->{cover} eq 'https://c/101.jpg' && !exists $q->{type});

			my $qb = Plugins::Ximalaya::ProtocolHandler->getMetadataFor(undef, 'xmly://never-published');
			check('handler: queue fallback for a never-published url stays empty',
				$qb && !scalar keys %$qb);

			# play-time publication still wins over the queue fallback
			Plugins::Ximalaya::ProtocolHandler->cache_metadata('xmly://101', {
				title => 'ep1', cover => 'https://c/101.jpg',
				duration => 600, bitrate => 128000, quality => 'mp3',
			});
			my $p = Plugins::Ximalaya::ProtocolHandler->getMetadataFor(undef, 'xmly://101');
			check('handler: resolve-time metadata still takes precedence over the fallback',
				$p && $p->{type} eq 'MP3 128kbps' && $p->{bitrate} eq '128kbps CBR');
			Slim::Schema::clear_rows();
			Slim::Utils::Cache::clear_store();
		}
	}
}

# -------------------------------------------- mobile track list (0.1.16)
{
	# parser: VIP shape -> tracks + EXACT total; empty -> (undef,undef,empty)
	my ($tracks, $total, $err) = $api->_parse_mobile_tracks($fx->{mobileTrack});
	check('mobile: parsed 2 tracks + EXACT totalCount (1388)',
		$tracks && @$tracks == 2 && $total == 1388 && !defined $err);
	check('mobile: trackId/title/isPaid mapping',
		$tracks->[0]{id} == 759074956 && $tracks->[0]{title} eq '第001集 VIP'
		&& $tracks->[0]{paid} == 1 && $tracks->[1]{paid} == 0);
	check('mobile: http cover upgraded to https',
		$tracks->[0]{cover} eq 'https://imagev2.xmcdn.com/storages/019c-audiofreehighqps/C7/E1/GKwRIasMxSA5AA.jpg');
	check('mobile: real duration carried (0.1.44 queue publication uses it)',
		$tracks->[0]{duration} == 624 && $tracks->[1]{duration} == 600);
	($tracks, $total, $err) = $api->_parse_mobile_tracks($fx->{mobileEmpty});
	check('mobile: empty list (free album) -> (undef, undef, empty)',
		!defined $tracks && !defined $total && $err eq 'empty');

	# wiring: URL/pageId/pageSize/order=0 + 30min cache + exact-total cb
	{
		my ($url, $expires, $via, $got_total);
		local *Plugins::Ximalaya::API::_json_get = sub {
			my ($class, $u, $h, $cb, $ecb, $cache) = @_;
			($url, $expires) = ($u, $cache);
			$cb->($fx->{mobileTrack});
			return;
		};
		$api->albumTracksMobile('83701277', 2, 50,
			sub { $via = 'cb'; (undef, $got_total) = @_; },
			sub { $via = 'ecb' });
		check('mobile: route pageId=2&pageSize=50&order=0 + 30min cache + cb(list,total)',
			$via eq 'cb' && $got_total == 1388 && $expires eq '30min'
			&& $url =~ m{^https://mobile\.ximalaya\.com/mobile/v1/album/track\?albumId=83701277&pageId=2&pageSize=50&order=0$}) if defined $url;
	}
}

# --------------------------------------------------------------- rank parsing
{
	my ($tabs, $err) = $api->_parse_rank_tabs($fx->{rankTabs});
	check('rankTabs: parsed 2 tabs, position order kept',
		$tabs && @$tabs == 2 && $tabs->[0]{name} eq '全站' && $tabs->[1]{name} eq '相声评书');
	check('rankTabs: channel ranks mapped with rankingId',
		@{ $tabs->[0]{ranks} } == 3 && $tabs->[0]{ranks}[0]{rankingId} == 100006
		&& $tabs->[0]{ranks}[1]{name} eq '免费' && $tabs->[1]{ranks}[1]{rankingId} == 100090);
	($tabs, $err) = $api->_parse_rank_tabs($fx->{rankTabsEmpty});
	check('rankTabs: empty payload -> (undef, empty)', !defined $tabs && $err eq 'empty');

	my ($albums, $ccode, $err2) = $api->_parse_rank_albums($fx->{rankElement});
	check('rankElement: parsed 2 albums (parser layer, method adds total)',
		$albums && @$albums == 2 && !defined $err2);
	check('rankElement: authoritative categoryCode harvested (youshengshu)',
		$ccode eq 'youshengshu');
	check('rankElement: title/announcer/tracksCount mapping',
		$albums->[0]{id} == 108239077 && $albums->[0]{announcer} eq '头陀渊讲故事'
		&& $albums->[0]{tracksCount} == 1183);
	check('rankElement: isPaid + isFinished flags',
		$albums->[0]{paid} == 1 && $albums->[0]{finished} == 1
		&& $albums->[1]{paid} == 0 && $albums->[1]{finished} == 0);
	check('rankElement: bare storages cover absolutized',
		$albums->[0]{cover} eq 'https://imagev2.xmcdn.com/storages/f5df-audiofreehighqps/96/70/GKwRIasMxSA5AAnJrQQizkhE.jpeg');
	($albums, $ccode, $err2) = $api->_parse_rank_albums($fx->{rankElementEmpty});
	check('rankElement: empty chart -> (undef, undef, empty)',
		!defined $albums && !defined $ccode && $err2 eq 'empty');
}

# --------------------------------------------------------------- rank wiring
{
	# master-switch off -> zero network todo
	{
		local $Plugins::Ximalaya::API::PC_CHANNEL_ENABLED = 0;
		my $sign_called = 0;
		local *Plugins::Ximalaya::Sign::gen = sub { $sign_called = 1 };
		my ($got, $via);
		$api->rankTabs(sub { $via = 'cb' }, sub { $got = shift; $via = 'ecb' });
		check('rank: master off -> ecb(todo), zero network', $via eq 'ecb' && $got eq 'todo' && !$sign_called);
	}

	my ($url, $headers, $expires);
	local *Plugins::Ximalaya::Sign::gen = sub {
		my ($class, $cb, $ecb) = @_;
		$cb->('STUBSIGN');
	};
	local *Plugins::Ximalaya::API::_json_get = sub {
		my ($class, $u, $h, $cb, $ecb, $cache) = @_;
		($url, $headers, $expires) = ($u, $h, $cache);
		$cb->($fx->{rankTabs});
		return;
	};
	my ($tabs, $via);
	$api->rankTabs(sub { $via = 'cb'; $tabs = shift; }, sub { $via = 'ecb' });
	check('rank: tabs callback path, 1h HTTP cache',
		$via eq 'cb' && $tabs && @$tabs == 2 && $expires eq '1h');
	check('rank: rankTabs route + sceneId=1 + sign + pc referer',
		$url =~ m{^https://pc\.ximalaya\.com/simple-revision-for-pc/rank/v4/rankTabs\?sceneId=1$}
		&& $headers->{'xm-sign'} eq 'STUBSIGN'
		&& $headers->{'Referer'} eq 'https://pc.ximalaya.com/') if defined $url;

	local *Plugins::Ximalaya::API::_json_get = sub {
		my ($class, $u, $h, $cb, $ecb, $cache) = @_;
		($url, $headers, $expires) = ($u, $h, $cache);
		$cb->($fx->{rankElement});
		return;
	};
	my ($albums, $total, $ccode);
	$api->rankAlbums('100006', sub { $via = 'cb'; ($albums, $total, $ccode) = @_; }, sub { $via = 'ecb' });
	check('rank: element route + rankingId + 30min cache + cb(albums,total,code)',
		$via eq 'cb' && $total == 2 && $ccode eq 'youshengshu'
		&& $url =~ m{^https://pc\.ximalaya\.com/simple-revision-for-pc/rank/v4/element\?rankingId=100006$}
		&& $expires eq '30min') if defined $url;
}

# ------------------------------------------------------- m-channel search 0.1.27
{
	# pure parser against the probe3 gold (legacy docs shape)
	my ($albums, $total, $err) = $api->_parse_search_albums($fx->{searchOk});
	check('search: parsed 2 albums + server total 1380',
		$albums && @$albums == 2 && $total == 1380 && !defined $err);
	check('search: id/title/announcer mapping (docs shape)',
		$albums->[0]{id} eq '82080513' && $albums->[0]{title} =~ /郭德纲/
		&& $albums->[0]{announcer} eq '喜马相声来乐');
	check('search: http cover_path absolutized to https',
		$albums->[0]{cover} =~ m{^https://imagev2\.xmcdn\.com/}
		&& $albums->[0]{cover} !~ m{^http://});
	check('search: string tracks count -> number',
		$albums->[0]{tracksCount} == 97 && $albums->[1]{tracksCount} == 143);
	check('search: string boolean is_paid "False" -> 0 (no false VIP tag)',
		$albums->[0]{paid} == 0 && $albums->[1]{paid} == 0);

	my ($empty, $etotal, $eerr) = $api->_parse_search_albums($fx->{searchEmpty});
	check('search: empty albums -> ([], total, undef)',
		ref $empty eq 'ARRAY' && @$empty == 0 && !defined $eerr);

	my ($sf, $sft, $sferr) = $api->_parse_search_albums($fx->{searchSoftFail});
	check('search: soft-fail (isIllegal + sq marker) -> risk, not empty',
		!defined $sf && $sferr eq 'risk');

	# wiring: anonymous -> fail fast with the login code, zero network
	{
		my $saved_cookie = $prefs->get('cookie');
		$prefs->set('cookie', '1&_device=win32&x&4.0.14');   # no 1&_token
		my ($net, $sign_called);
		local *Plugins::Ximalaya::API::_json_get = sub { $net = 1 };
		local *Plugins::Ximalaya::Sign::gen = sub { $sign_called = 1 };
		my ($got, $via);
		$api->searchAlbums('kw', 1, sub { $via = 'cb' }, sub { $got = shift; $via = 'ecb' });
		check('search: anonymous -> ecb(1001) before sign/network',
			$via eq 'ecb' && $got eq '1001' && !$net && !$sign_called);
		$prefs->set('cookie', $saved_cookie);
	}

	# wiring: signed path - route shape, fresh xm-sign, mobile UA, m referer
	{
		my $saved_cookie = $prefs->get('cookie');
		$prefs->set('cookie', '1&_token=98645391&STUBTOKEN; 1&_device=win32&x&4.0.14');
		local *Plugins::Ximalaya::Sign::gen = sub {
			my ($class, $cb, $ecb) = @_; $cb->('STUBSIGN');
		};
		my ($url, $headers);
		local *Plugins::Ximalaya::API::_json_get = sub {
			my ($class, $u, $h, $cb, $ecb, $cache) = @_;
			($url, $headers) = ($u, $h);
			$cb->($fx->{searchOk});
			return;
		};
		my ($via, $out, $out_total);
		$api->searchAlbums('郭德纲', 2,
			sub { $via = 'cb'; ($out, $out_total) = @_; },
			sub { $via = 'ecb' });
		check('search: m route + percent-encoded kw + page/rows protocol',
			$url =~ m{^https://m\.ximalaya\.com/m-revision/page/search\?kw=%E9%83%AD%E5%BE%B7%E7%BA%B2&core=all&page=2&rows=20$});
		check('search: fresh xm-sign + mobile UA + m referer + user cookie',
			$headers->{'xm-sign'} eq 'STUBSIGN'
			&& $headers->{'User-Agent'} =~ /Android/
			&& $headers->{'Referer'} eq 'https://m.ximalaya.com/search'
			&& $headers->{Cookie} =~ /1&_token=98645391&STUBTOKEN/);
		check('search: cb(albums, server total) pass-through',
			$via eq 'cb' && @$out == 2 && $out_total == 1380);

		# ret=303 needLogin (stale cookie) -> ecb(303) via _check_ret
		my $got303;
		local *Plugins::Ximalaya::API::_json_get = sub {
			my ($class, $u, $h, $cb, $ecb) = @_; $ecb->(undef) if 0; $cb->($fx->{searchNeedLogin});
		};
		$api->searchAlbums('kw', 1, sub {}, sub { $got303 = shift });
		check('search: ret=303 needLogin -> ecb(303)', $got303 == 303);

		$prefs->set('cookie', $saved_cookie);
	}

	# Plugin menu handler: windowing against the server page width (20)
	{
		local *Plugins::Ximalaya::API::searchAlbums = sub {
			my ($class, $kw, $page, $cb, $ecb) = @_;
			my ($al, $t) = $api->_parse_search_albums($fx->{searchOk});
			$cb->($al, $t);
		};
		my ($out, $client) = ({}, bless({}, 'StubClient'));
		Plugins::Ximalaya::Plugin::searchHandler($client,
			sub { $out = shift }, { search => 'kw', index => 20, quantity => 50 });
		check('menu: search windowing index=20 -> page2 offset=20 + total',
			$out->{offset} == 20 && $out->{total} == 1380
			&& @{ $out->{items} || [] } == 2);
		Plugins::Ximalaya::Plugin::searchHandler($client,
			sub { $out = shift }, { search => 'kw', index => 5, quantity => 50 });
		check('menu: search windowing index=5 stays in page1 (offset=0)',
			$out->{offset} == 0 && @{ $out->{items} || [] } == 2);
	}
}

# ------------------------------------------- my albums / favourites 0.1.28+
{
	require Slim::Utils::Favorites;

	# albumItem exposes the native favourites metadata (web UI renders the
	# star action from these - Slim::Web::XMLBrowser L1036-1040); 0.1.29: the
	# favourites URL is the absolute HTTP album feed (browsable), no longer a
	# dead xmly://album/<id> bookmark
	{
		my $it = Plugins::Ximalaya::Plugin::albumItem({
			id => 82080513, title => '郭德纲相声精选', announcer => '德云社',
			cover => 'https://x/y.jpg', paid => 0,
		});
		check('fav: albumItem exposes absolute album-feed favourites url + title + type',
			$it->{favorites_url} eq 'http://192.0.2.1:9000/plugins/Ximalaya/albumfeed.html?album=82080513'
			&& $it->{favorites_title} =~ /郭德纲相声精选/
			&& $it->{favorites_type} eq 'link');
		my $fb = Plugins::Ximalaya::Plugin::_albumFallbackItem(12345);
		check('fav: fallback item is favourites-capable too',
			$fb->{favorites_url} eq 'http://192.0.2.1:9000/plugins/Ximalaya/albumfeed.html?album=12345');
	}

	# myAlbums merge: pref ids + LMS favourites (both URL shapes), dedup,
	# pref order first
	{
		my $saved = $prefs->get('albums');
		$prefs->set('albums', "111\n222");

		Slim::Utils::Favorites::set_store_rows(
			['http://192.0.2.1:9000/plugins/Ximalaya/albumfeed.html?album=333', 'Fav Album 333', 'link'],
			['xmly://album/444', 'legacy bookmark 444', 'audio'],
			['xmly://album/111', 'dup of pref 111', 'link'],
			['xmly://track/999', 'not an album - ignored', 'link'],
		);
		local *Plugins::Ximalaya::API::albumInfo = sub {
			my ($class, $id, $cb, $ecb) = @_;
			$cb->({ id => $id, title => "Album $id" });
		};
		my ($out, $client) = ({}, bless({}, 'StubClient'));
		Plugins::Ximalaya::Plugin::myAlbumsHandler($client, sub { $out = shift });
		my $names = join('|', map { $_->{name} || '?' } @{ $out->{items} || [] });
		check('fav: myAlbums merges pref + feed-url + legacy favourites (dedup, pref first)',
			@{ $out->{items} || [] } == 4
			&& $names =~ /Album 111/ && $names =~ /Album 222/
			&& $names =~ /Album 333/ && $names =~ /Album 444/);

		$prefs->set('albums', '');
		Slim::Utils::Favorites::set_store_rows();
		Plugins::Ximalaya::Plugin::myAlbumsHandler($client, sub { $out = shift });
		check('fav: empty pref + empty favourites -> NOALBUMS hint',
			@{ $out->{items} || [] } == 1 && ($out->{items}[0]{name} || '') ne '');

		$prefs->set('albums', $saved);
		Slim::Utils::Favorites::set_store_rows();
	}

	# 0.1.45: dual-write favourites - _on_favorites_changed appends album
	# ids from the favourites store into the pref; track favourites stay out
	# 0.1.46: rows carry EXPLICIT types - the real OpmlFavorites::all()
	# defaults to a qr/audio|playlist/ filter and our web-UI album
	# favourites are type 'link' (device-verified root cause), so the
	# plugin must scan with all(qr//); the stub now mirrors that filter.
	{
		my $saved = $prefs->get('albums');
		$prefs->set('albums', "555");

		Slim::Utils::Favorites::set_store_rows(
			['xmly://album/666', 'starred 666 (web UI)', 'link'],
			['http://192.0.2.1:9000/plugins/Ximalaya/albumfeed.html?album=777', 'starred 777 (web UI)', 'link'],
			['xmly://album/888', 'cli-added 888', 'audio'],
			['xmly://track/999', 'track favourite - must stay out', 'link'],
			['http://example.com/radio', 'unrelated station', 'audio'],
		);
		check('favsync regression guard: stub all() default hides link rows (real OpmlFavorites semantics)',
			@{ Slim::Utils::Favorites->new(undef)->all() } == 2
			&& @{ Slim::Utils::Favorites->new(undef)->all(qr//) } == 5);
		Plugins::Ximalaya::Plugin::_on_favorites_changed();
		check('favsync: album favourites (link AND audio types) land in the pref, tracks/stations stay out',
			$prefs->get('albums') =~ /^555\n666\n777\n888$/);

		# idempotent: a second change notification (any save re-fires) -> no dup
		Plugins::Ximalaya::Plugin::_on_favorites_changed();
		check('favsync: repeated change notifications do not duplicate ids',
			$prefs->get('albums') =~ /^555\n666\n777\n888$/);

		# un-favouriting does NOT remove from the pref (independent store)
		Slim::Utils::Favorites::set_store_rows(
			['xmly://track/999', 'track favourite - must stay out', 'link'],
		);
		Plugins::Ximalaya::Plugin::_on_favorites_changed();
		check('favsync: un-favouriting leaves the pref untouched (my albums is its own store)',
			$prefs->get('albums') =~ /^555\n666\n777\n888$/);

		check('favsync: _album_id_from_url recognises both album shapes only',
			Plugins::Ximalaya::Plugin::_album_id_from_url('xmly://album/42') eq '42'
			&& Plugins::Ximalaya::Plugin::_album_id_from_url('http://h/plugins/Ximalaya/albumfeed.html?album=43') eq '43'
			&& !defined Plugins::Ximalaya::Plugin::_album_id_from_url('xmly://track/44')
			&& !defined Plugins::Ximalaya::Plugin::_album_id_from_url('xmly://759074956')
			&& !defined Plugins::Ximalaya::Plugin::_album_id_from_url(undef));

		$prefs->set('albums', $saved);
		Slim::Utils::Favorites::set_store_rows();
	}
}

# ---------------------------------------------- album feed (starred) 0.1.29
{
	# 0.1.31: the feed page width follows the same server preference the web
	# UI uses for slicing (Slim::Web::Pages::Common::pageInfo falls back to
	# preferences('server')->get('itemsPerPage'))
	preferences('server')->set('itemsPerPage', 50);

	# stub response object capturing content_type
	my $resp = bless {}, 'XimaStubResponse';
	local *XimaStubResponse::content_type = sub {
		my ($self, $ct) = @_;
		$self->{ct} = $ct;
		return;
	};

	# no album param -> bare OPML skeleton, xml content type
	{
		my ($body, $got) = (undef, undef);
		Plugins::Ximalaya::Plugin::albumFeedHandler(undef, {},
			sub { (undef, undef, my $b) = @_; $body = $$b; $got = 1; },
			undef, $resp);
		check('feed: missing album -> empty OPML + text/xml + callback form',
			$got && $resp->{ct} eq 'text/xml; charset=utf-8'
			&& $body =~ /^\Q<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\E/
			&& $body =~ /<opml version="1\.0">/ && $body !~ /<outline/);
	}

	# album with tracks: audio rows + XML escaping + self-referencing next
	# page link (mock: 1 track now, server total 2 -> one more page)
	{
		$prefs->set('mobile_channel', 1);   # albumHandler routes mobile-first
		local *Plugins::Ximalaya::API::albumTracksMobile = sub {
			my ($class, $albumId, $page, $size, $cb, $ecb) = @_;
			$cb->([ { id => 759074956, title => 'T&T <feat>', paid => 1, cover => '' } ], 2);
		};
		# 0.1.43: header labels come from album/simple, fetched before the
		# track feed
		local *Plugins::Ximalaya::API::albumInfo = sub {
			my ($class, $albumId, $cb, $ecb) = @_;
			$cb->({ title => 'Fav A&lbum', announcer => 'Fav Host', cover => 'https://c/1.jpg' });
		};
		my $body;
		Plugins::Ximalaya::Plugin::albumFeedHandler(undef, { album => '30816438', page => 1 },
			sub { (undef, undef, my $b) = @_; $body = $$b; },
			undef, $resp);
		check('feed: songinfo header labels (ALBUM/ARTIST outlines, xml-escaped) precede the rows',
			$body =~ m{\Q<outline text="Fav A&amp;lbum" type="text" label="ALBUM"/>\E}
			&& $body =~ m{\Q<outline text="Fav Host" type="text" label="ARTIST"/>\E}
			&& index($body, 'label="ALBUM"') < index($body, 'PLUGIN_XIMALAYA_NEXT_PAGE'));
		check('feed: nested playlist shell row carries play (-> feed-level playUrl = songinfo'
			. ' play/add = whole album) + upsized cover (-> feed-level image = header artwork)',
			$body =~ m{\Q<outline text="Fav A&amp;lbum" type="playlist" play="xmly://album/30816438"\E}
			&& $body !~ /_T\d+x\d+\.jpg/
			&& $body =~ m{\Q</outline>\E\s*</body>});
		check('feed: NO itemsHaveAudio trigger on the OPML channel (no duration/playall attrs'
			. ' - allcontrol would re-queue the page on top of the exploded album)',
			$body !~ /duration=/ && $body !~ /playall=/);
		check('feed: audio row with escaped title + xmly play url',
			$body =~ m{\Q<outline text="[VIP] 1. T&amp;T &lt;feat&gt;" URL="xmly://759074956" type="audio"/>\E});
		check('feed: NO play-all row anywhere (0.1.44: the shell header play button covers the whole album)',
			$body !~ /PLUGIN_XIMALAYA_PLAY_ALL/);
		check('feed: next-page link back at the route with escaped &page',
			$body =~ m{\QURL="http://192.0.2.1:9000/plugins/Ximalaya/albumfeed.html?album=30816438&amp;page=2" type="link"\E});

		# 0.1.43: album/simple failure degrades to the bare track list
		local *Plugins::Ximalaya::API::albumInfo = sub {
			my ($class, $albumId, $cb, $ecb) = @_;
			$ecb->('http');
		};
		Plugins::Ximalaya::Plugin::albumFeedHandler(undef, { album => '30816438', page => 1 },
			sub { (undef, undef, my $b) = @_; $body = $$b; },
			undef, $resp);
		check('feed: albumInfo failure -> no label rows, rows intact',
			$body !~ /label=/ && $body =~ m{\QURL="xmly://759074956" type="audio"/>\E});

		# last page (have == total) -> no next-page link
		local *Plugins::Ximalaya::API::albumInfo = sub {
			my ($class, $albumId, $cb, $ecb) = @_;
			$cb->({ title => 'Fav Album', announcer => 'Fav Host' });
		};
		local *Plugins::Ximalaya::API::albumTracksMobile = sub {
			my ($class, $albumId, $page, $size, $cb, $ecb) = @_;
			$cb->([ { id => 759074957, title => 'last', paid => 0, cover => '' } ], 2);
		};
		Plugins::Ximalaya::Plugin::albumFeedHandler(undef, { album => '30816438', page => 2 },
			sub { (undef, undef, my $b) = @_; $body = $$b; },
			undef, $resp);
		check('feed: last page has no next-page link',
			$body =~ /xmly:\/\/759074957/ && $body !~ /&amp;page=3/);
		check('feed: single-page album gets no jump-to-page row (total <= width)',
			$body !~ /mode=pages/);
	}

	# 0.1.31 ghost-page fix + 0.1.32 jump-to-page row + 0.1.44 width change.
	# The web UI slices a fetched feed per page (Slim::Web::XMLBrowser caches
	# the whole feed; Pages::Common::pageInfo slices; no re-fetch), so a feed
	# page must never exceed the UI page width: width = itemsPerPage - 2
	# (next-page + jump rows) - 2 (label slots) = 46 -> 46 tracks + next +
	# jump + 2 labels = 50 in-shell outlines = exactly ONE ui page (the
	# leading play-all row that 0.1.33-0.1.43 spent a slot on is gone - the
	# shell header's own play button plays the album; user request 0.1.44).
	# 0.1.43: everything lives INSIDE one nested playlist shell outline
	# (51 outline tags total) - the shell is not part of the second hop's
	# list, so the in-shell content is still exactly one UI page.
	{
		my (@sizes, @pages);
		local *Plugins::Ximalaya::API::albumTracksMobile = sub {
			my ($class, $albumId, $page, $size, $cb, $ecb) = @_;
			push @sizes, $size;
			push @pages, $page;
			$cb->([ map {
				{ id => 900000000 + $_, title => "t$_", paid => 0, cover => "https://img/$_" }
			} 1 .. $size ], 100);
		};
		local *Plugins::Ximalaya::API::albumInfo = sub {
			my ($class, $albumId, $cb, $ecb) = @_;
			$cb->({ title => 'Fav Album', announcer => 'Fav Host', cover => 'https://c/777_T250x250.jpg' });
		};
		my $body;
		Plugins::Ximalaya::Plugin::albumFeedHandler(undef, { album => '777', page => 1 },
			sub { (undef, undef, my $b) = @_; $body = $$b; }, undef, $resp);
		my $rows = () = $body =~ /<outline /g;
		check('feed: shell + 2 labels + 46 tracks + next + jump = 51 outline tags,'
			. ' in-shell content still one UI page (width 48-2 for the label slots)',
			$rows == 51 && $sizes[0] == 46 && $pages[0] == 1);
		check('feed: shell row = album card (cover upsized, play = whole album)',
			$body =~ m{\Q<outline text="Fav Album" type="playlist" play="xmly://album/777" image="https://c/777.jpg">\E});
		check('feed: no play-all row; tracks start right after the label rows (0.1.44)',
			$body !~ /PLUGIN_XIMALAYA_PLAY_ALL/
			&& $body =~ m{\Qlabel="ARTIST"/>\E\n\Q<outline text="1. t1"\E});
		check('feed: page-1 numbering 1..46, audio rows carry image cover attr',
			$body =~ /\Qtext="1. t1"\E/ && $body =~ /\Qtext="46. t46"\E/
			&& $body =~ m{\Qimage="https://img/1"\E} && $body =~ m{\Qimage="https://img/46"\E});
		check('feed: next-page row carries first-batch cover + page=2 url',
			$body =~ m{\Q<outline text="PLUGIN_XIMALAYA_NEXT_PAGE" URL="http://192.0.2.1:9000/plugins/Ximalaya/albumfeed.html?album=777&amp;page=2" type="link" image="https://img/1"/>\E});
		check('feed: jump-to-page row embeds total for the zero-API page list',
			$body =~ m{\Q<outline text="PLUGIN_XIMALAYA_JUMP_PAGES" URL="http://192.0.2.1:9000/plugins/Ximalaya/albumfeed.html?album=777&amp;mode=pages&amp;total=100" type="link" image="https://img/1"/>\E});

		Plugins::Ximalaya::Plugin::albumFeedHandler(undef, { album => '777', page => 2 },
			sub { (undef, undef, my $b) = @_; $body = $$b; }, undef, $resp);
		$rows = () = $body =~ /<outline /g;
		check('feed: page=2 keeps offset math (titles numbered 47..92) and still one page',
			$rows == 51 && $pages[1] == 2 && $sizes[1] == 46
			&& $body =~ /\Qtext="47. t1"\E/ && $body =~ /\Qtext="92. t46"\E/
			&& $body =~ /&amp;page=3/);
	}

	# 0.1.32: jump-to-page list layer - zero API calls, locally generated
	# from the embedded total; ceil edge cases; garbage total degrades to an
	# empty list. The whole list is one fetch -> the UI's own pager handles
	# it natively (bonus).
	{
		# any API call here would mean the page list is NOT zero-API: die loudly
		local *Plugins::Ximalaya::API::albumTracksMobile = sub { die "API called from pages layer" };
		my $body;
		Plugins::Ximalaya::Plugin::albumFeedHandler(undef,
			{ album => '777', mode => 'pages', total => '100' },
			sub { (undef, undef, my $b) = @_; $body = $$b; }, undef, $resp);
		my $rows = () = $body =~ /<outline /g;
		check('feed: pages layer for total=100 -> 3 page rows, zero API calls',
			$rows == 3
			&& $body =~ m{\Qalbumfeed.html?album=777&amp;page=1\E}
			&& $body =~ m{\Qalbumfeed.html?album=777&amp;page=2\E}
			&& $body =~ m{\Qalbumfeed.html?album=777&amp;page=3\E}
			&& $body !~ /type="audio"/);
		check('feed: pages layer names carry token (format applied in prod strings)',
			($body =~ m{text="(PLUGIN_XIMALAYA_PAGE_OF)"} ? $1 : '') eq 'PLUGIN_XIMALAYA_PAGE_OF');

		# ceil edge: exactly 2 full pages vs one track over (width 46 = 48-2
		# label slots; the play-all slot went away with 0.1.44)
		Plugins::Ximalaya::Plugin::albumFeedHandler(undef,
			{ album => '777', mode => 'pages', total => '92' },
			sub { (undef, undef, my $b) = @_; $body = $$b; }, undef, $resp);
		my $rows92 = () = $body =~ /<outline /g;
		Plugins::Ximalaya::Plugin::albumFeedHandler(undef,
			{ album => '777', mode => 'pages', total => '93' },
			sub { (undef, undef, my $b) = @_; $body = $$b; }, undef, $resp);
		my $rows93 = () = $body =~ /<outline /g;
		check('feed: pages layer ceil edges (92 -> 2 pages, 93 -> 3 pages)',
			$rows92 == 2 && $rows93 == 3);

		# missing/garbage total -> bare OPML, no rows
		Plugins::Ximalaya::Plugin::albumFeedHandler(undef,
			{ album => '777', mode => 'pages' },
			sub { (undef, undef, my $b) = @_; $body = $$b; }, undef, $resp);
		check('feed: pages layer without total -> empty OPML (no rows, no crash)',
			$body !~ /<outline/);
	}

	# width helper: follows itemsPerPage, clamped to the API cap, garbage-
	# proof (0.1.31; 0.1.32/0.1.33 kept TWO+ONE rows of room; 0.1.44 retires
	# the play-all slot -> TWO)
	{
		my $srv = preferences('server');
		$srv->set('itemsPerPage', 25);
		check('feed: width follows itemsPerPage=25 -> 23',
			Plugins::Ximalaya::Plugin::_feed_page_width() == 23);
		$srv->set('itemsPerPage', 200);
		check('feed: width capped at PC_SHOW_MAX for huge itemsPerPage',
			Plugins::Ximalaya::Plugin::_feed_page_width() == Plugins::Ximalaya::API::PC_SHOW_MAX());
		$srv->set('itemsPerPage', 1);
		check('feed: pathological itemsPerPage=1 falls back to default 50 -> 48',
			Plugins::Ximalaya::Plugin::_feed_page_width() == 48);
		$srv->set('itemsPerPage', 'abc');
		check('feed: non-numeric itemsPerPage falls back to default 50 -> 48',
			Plugins::Ximalaya::Plugin::_feed_page_width() == 48);

		# end-to-end at itemsPerPage=25: 21 tracks + next + jump = 23 in-shell
		# rows + shell = 24 tags (labels need album/simple -> absent here)
		$srv->set('itemsPerPage', 25);
		local *Plugins::Ximalaya::API::albumTracksMobile = sub {
			my ($class, $albumId, $page, $size, $cb, $ecb) = @_;
			$cb->([ map {
				{ id => 800000000 + $_, title => "u$_", paid => 0, cover => '' }
			} 1 .. $size ], 100);
		};
		my $body;
		Plugins::Ximalaya::Plugin::albumFeedHandler(undef, { album => '888', page => 1 },
			sub { (undef, undef, my $b) = @_; $body = $$b; }, undef, $resp);
		my $rows = () = $body =~ /<outline /g;
		check('feed: itemsPerPage=25 -> shell + 21 tracks + next + jump = 24 tags',
			$rows == 24 && $body =~ /\Qtext="21. u21"\E/
			&& $body =~ /&amp;mode=pages&amp;total=100/);

		$srv->set('itemsPerPage', 50);
	}

	# --------------------------------------- play whole album (0.1.34)
	# albumTracksAll chains the three list tiers into one ordered list (1h
	# in-memory cache); ProtocolHandler::explodePlaylist hands it to LMS's
	# playlist playtracks listRef - the native Spotify-album mechanism, and
	# the remote equivalent of the local whole-album enqueue.
	{
		Plugins::Ximalaya::API->_clear_alltracks_cache();

		# album rows gain the whole-album play url (0.1.34)
		{
			my $it = Plugins::Ximalaya::Plugin::albumItem({
				id => 30816438, title => 'A', announcer => 'x', paid => 1,
				cover => 'https://c/1',
			});
			check('albumItem: row keeps descend, gains whole-album play url',
				ref $it->{url} eq 'CODE'
				&& ($it->{play} || '') eq 'xmly://album/30816438'
				&& ($it->{favorites_url} || '') =~ /albumfeed\.html\?album=30816438/
				&& ($it->{name} || '') eq 'A - x [VIP]');
			check('albumItem: jive escape hatch asks album-styled window (0.1.36)',
				$it->{jive} && ref $it->{jive}{window} eq 'HASH'
				&& ($it->{jive}{window}{menuStyle} || '') eq 'album'
				&& ($it->{jive}{window}{'icon-id'} || '') eq 'https://c/1');
			check('albumItem: on_select=play -> touchToPlay item like TuneIn stations (0.1.37)',
				($it->{on_select} || '') eq 'play');
			check('albumItem: itemActions.info routes CM to ximalaya items with baked cmAlbum (0.1.38)',
				$it->{itemActions}
				&& $it->{itemActions}{info}
				&& ($it->{itemActions}{info}{command}[0] || '') eq 'ximalaya'
				&& ($it->{itemActions}{info}{command}[1] || '') eq 'items'
				&& ($it->{itemActions}{info}{fixedParams}{cmAlbum} || '') eq '30816438'
				&& ($it->{itemActions}{info}{fixedParams}{cmIcon} || '') eq 'https://c/1'
				&& ($it->{itemActions}{info}{fixedParams}{cmTitle} || '') eq 'A - x [VIP]');
		}

		# --------------------------------- Daphile pre-play page CM (0.1.38)
		# The big-artwork pre-play page renders its buttons from the row's
		# context menu, in the Slim::Menu::TrackInfo tile shape only.
		{
			my $ti = Plugins::Ximalaya::Plugin::trackItem(3,
				{ id => 549382127, title => 'T', paid => 0, cover => 'https://c/2' });
			check('trackItem: itemActions.info carries baked cmTrack/cmTitle/cmIcon (0.1.38)',
				$ti->{itemActions}
				&& ($ti->{itemActions}{info}{command}[1] || '') eq 'items'
				&& ($ti->{itemActions}{info}{fixedParams}{cmTrack} || '') eq '549382127'
				&& ($ti->{itemActions}{info}{fixedParams}{cmTitle} || '') eq 'T'
				&& ($ti->{itemActions}{info}{fixedParams}{cmIcon} || '') eq 'https://c/2');
			check('trackItem: explicit single-track play/add/insert beat base whole-album fallback (0.1.39)',
				join('|', @{ $ti->{itemActions}{play}{command}   || [] }) eq 'playlist|play|xmly://549382127'
				&& join('|', @{ $ti->{itemActions}{add}{command}    || [] }) eq 'playlist|add|xmly://549382127'
				&& join('|', @{ $ti->{itemActions}{insert}{command} || [] }) eq 'playlist|insert|xmly://549382127');

			my ($out, $client) = ({}, bless({}, 'StubClient'));
			Plugins::Ximalaya::Plugin::handleFeed($client, sub { $out = shift },
				{ menu => 1, cmTrack => '549382127', cmTitle => "A:B\nC", cmIcon => 'https://c/2' });
			my $tiles = $out->{items} || [];
			check('cm track: 4 tiles, TrackInfo shape (type text + playcontrol + jive aliases)',
				@$tiles == 4
				&& ($tiles->[0]{type}  || '') eq 'text'
				&& ($tiles->[0]{name}  || '') eq 'ADD_TO_END'
				&& ($tiles->[0]{playcontrol} || '') eq 'add'
				&& $tiles->[0]{jive}{actions}{go}
				&& $tiles->[0]{jive}{actions}{play}
				&& $tiles->[0]{jive}{actions}{add}
				&& join('|', @{ $tiles->[0]{jive}{actions}{go}{cmd} || [] }) eq 'playlist|add|xmly://track/549382127'
				&& ($tiles->[0]{jive}{actions}{go}{nextWindow} || '') eq 'parent');
			check('cm track: play tile is itemplay + nowPlaying; insert tile is parent',
				($tiles->[1]{playcontrol} || '') eq 'insert'
				&& join('|', @{ $tiles->[1]{jive}{actions}{go}{cmd} || [] }) eq 'playlist|insert|xmly://track/549382127'
				&& ($tiles->[2]{jive}{style} || '') eq 'itemplay'
				&& ($tiles->[2]{jive}{actions}{go}{nextWindow} || '') eq 'nowPlaying'
				&& join('|', @{ $tiles->[2]{jive}{actions}{go}{cmd} || [] }) eq 'playlist|play|xmly://track/549382127');
			check('cm track: favorites tile binds jivefavorites add with sanitized title + icon',
				($tiles->[3]{jive}{style} || '') eq 'item_fav'
				&& join('|', @{ $tiles->[3]{jive}{actions}{go}{cmd} || [] }) eq 'jivefavorites|add'
				&& ($tiles->[3]{jive}{actions}{go}{params}{url} || '') eq 'xmly://track/549382127'
				&& ($tiles->[3]{jive}{actions}{go}{params}{title} || '') eq 'A:B C'
				&& ($tiles->[3]{jive}{actions}{go}{params}{icon} || '') eq 'https://c/2'
				&& ($tiles->[3]{jive}{actions}{go}{params}{isContextMenu} || '') eq '1');

			Plugins::Ximalaya::Plugin::handleFeed($client, sub { $out = shift },
				{ menu => 1, cmAlbum => '12148879', cmTitle => 'AL', cmIcon => '' });
			$tiles = $out->{items} || [];
			check('cm album: play tile = whole album explodePlaylist; fav binds albumfeed URL',
				@$tiles == 5
				&& join('|', @{ $tiles->[2]{jive}{actions}{go}{cmd} || [] }) eq 'playlist|play|xmly://album/12148879'
				&& ($tiles->[3]{jive}{actions}{go}{params}{url} || '') =~ /albumfeed\.html\?album=12148879/
				&& !exists $tiles->[3]{jive}{actions}{go}{params}{icon});
			check('cm album: browse tile descends into the track list via cmBrowseAlbum (0.1.39)',
				($tiles->[4]{name} || '') eq 'PLUGIN_XIMALAYA_BROWSE_TRACKS'
				&& ($tiles->[4]{jive}{actions}{go}{cmd}[0] || '') eq 'ximalaya'
				&& ($tiles->[4]{jive}{actions}{go}{params}{cmBrowseAlbum} || '') eq '12148879');

			Plugins::Ximalaya::Plugin::handleFeed($client, sub { $out = shift },
				{ menu => 1, cmBrowseAlbum => '12148879', index => 0, quantity => 50 });
			check('cm browse: descends into the album track list feed (0.1.39)',
				exists $out->{items} && @{ $out->{items} || [] } >= 1);
		}

		# tier 1 happy path: mobile pages to the exact total; the observed
		# page width governs the short-page stop (server may clamp pageSize)
		{
			my @pages;
			local *Plugins::Ximalaya::API::albumTracksMobile = sub {
				my ($class, $aid, $page, $size, $cb, $ecb) = @_;
				push @pages, $page;
				if ($page == 1) {
					$cb->([ { id => 1, title => 'a', paid => 0, cover => '' },
					        { id => 2, title => 'b', paid => 1, cover => '' } ], 3);
				} elsif ($page == 2) {
					$cb->([ { id => 3, title => 'c', paid => 0, cover => '' } ], 3);
				} else {
					die "mobile over-paging";
				}
			};
			my ($list, $err);
			Plugins::Ximalaya::API->albumTracksAll('777', sub { $list = shift }, sub { $err = shift });
			check('m3u: mobile chain pages to exact total, album order kept',
				!defined $err && "@pages" eq '1 2'
				&& join(',', map { $_->{id} } @$list) eq '1,2,3');

			# served from the 1h cache afterwards: the API layer stays cold
			local *Plugins::Ximalaya::API::albumTracksMobile = sub { die "cache miss" };
			my $again;
			Plugins::Ximalaya::API->albumTracksAll('777', sub { $again = shift }, sub { $again = 'ERR' });
			check('m3u: repeat list served from the 1h cache (zero API calls)',
				ref $again eq 'ARRAY' && @$again == 3);
		}

		# tier fallback: mobile empty (free album) -> pc show chain; web untouched
		{
			Plugins::Ximalaya::API->_clear_alltracks_cache();
			local *Plugins::Ximalaya::API::albumTracksMobile = sub {
				my ($class, $aid, $page, $size, $cb, $ecb) = @_;
				$ecb->('empty');
			};
			local *Plugins::Ximalaya::API::albumTracksShow = sub {
				my ($class, $aid, $page, $size, $cb, $ecb) = @_;
				if ($page == 1) {
					$cb->([ { id => 11, title => 'p1', paid => 0, cover => '' },
					        { id => 12, title => 'p2', paid => 0, cover => '' } ], 1);
				} else {
					$cb->([ { id => 13, title => 'p3', paid => 0, cover => '' } ], 0);
				}
			};
			local *Plugins::Ximalaya::API::albumTracks = sub { die "web tier must not run" };
			my ($list, $err);
			Plugins::Ximalaya::API->albumTracksAll('555', sub { $list = shift }, sub { $err = shift });
			check('m3u: free album falls back mobile->pc show (web untouched)',
				!defined $err && join(',', map { $_->{id} } @$list) eq '11,12,13');
		}

		# the NATIVE expansion (0.1.34): ProtocolHandler::explodePlaylist
		# turns xmly://album/<id> into the ordered xmly:// track list (LMS
		# executes 'playlist playtracks listRef' with it - the Spotify
		# album mechanism); plain track URLs explode to themselves
		{
			Plugins::Ximalaya::API->_clear_alltracks_cache();
			Slim::Music::Info::reset_remote_meta();
			local *Plugins::Ximalaya::API::albumTracksMobile = sub {
				my ($class, $aid, $page, $size, $cb, $ecb) = @_;
				$cb->([ { id => 21, title => 'r1', paid => 0, cover => '' },
				        { id => 22, title => 'r2', paid => 0, cover => '' } ], 2);
			};
			my $urls;
			Plugins::Ximalaya::ProtocolHandler->explodePlaylist(undef, 'xmly://album/999',
				sub { $urls = shift });
			check('explode: album URL -> ordered xmly:// track list',
				ref $urls eq 'ARRAY' && join('|', @$urls) eq 'xmly://21|xmly://22');

			# 0.1.44: every exploded track gets its display metadata published
			# BEFORE the queue is filled - no more blank playlist rows
			my $rm = Slim::Music::Info::remote_meta();
			check('explode: enqueue-time metadata publication for every track (0.1.44)',
				(grep { $_->[0] eq 'xmly://21' && $_->[1]{title} eq 'r1' } @$rm)
				&& (grep { $_->[0] eq 'xmly://22' && $_->[1]{title} eq 'r2' } @$rm));

			my $self2;
			Plugins::Ximalaya::ProtocolHandler->explodePlaylist(undef, 'xmly://759074956',
				sub { $self2 = shift });
			check('explode: track URL -> itself (single-track play unchanged)',
				ref $self2 eq 'ARRAY' && "@$self2" eq 'xmly://759074956');

			# the first explode fed the 1h cache: repeat explode is zero-API
			local *Plugins::Ximalaya::API::albumTracksMobile = sub { die "cache miss" };
			my $urls2;
			Plugins::Ximalaya::ProtocolHandler->explodePlaylist(undef, 'xmly://album/999',
				sub { $urls2 = shift });
			check('explode: repeat album explode served from the 1h cache',
				ref $urls2 eq 'ARRAY' && @$urls2 == 2);
		}
	}
}

# --------------------------------------------------- Categories menu routing
{
	require Plugins::Ximalaya::Categories;
	local *Plugins::Ximalaya::API::rankTabs = sub {
		my ($class, $cb, $ecb) = @_;
		my ($tabs) = $api->_parse_rank_tabs($fx->{rankTabs});
		$cb->($tabs);
	};

	my ($out, $client) = ({}, bless({}, 'StubClient'));
	Plugins::Ximalaya::Categories->feed($client, sub { $out = shift });
	check('menu: top feed lists channels from rankTabs',
		@{ $out->{items} || [] } == 2
		&& $out->{items}[0]{name} eq '全站' && $out->{items}[1]{name} eq '相声评书');

	Plugins::Ximalaya::Categories::tabFeed($client, sub { $out = shift }, {}, 1);
	check('menu: tab feed lists charts of channel 1',
		@{ $out->{items} || [] } == 3
		&& $out->{items}[0]{name} eq '热播' && $out->{items}[2]{name} eq 'VIP');

	local *Plugins::Ximalaya::API::rankAlbums = sub {
		my ($class, $rankingId, $cb, $ecb) = @_;
		my ($albums, $ccode) = $api->_parse_rank_albums($fx->{rankElement});
		$cb->($albums, scalar @$albums, $ccode);
	};
	Plugins::Ximalaya::Categories::rankFeed($client, sub { $out = shift }, { index => 0, quantity => 50 }, 100006);
	check('menu: rank feed local windowing + full-catalog total (+1 entry)',
		@{ $out->{items} || [] } == 3 && $out->{offset} == 0 && $out->{total} == 3
		&& $out->{items}[0]{name} =~ /头陀渊讲故事/
		&& ($out->{items}[2]{name} || '') eq 'PLUGIN_XIMALAYA_ALL_ALBUMS'
		&& $out->{items}[2]{type} eq 'link');

	# entry lives at position @$albums: window 1..1 shows only album 2
	Plugins::Ximalaya::Categories::rankFeed($client, sub { $out = shift }, { index => 1, quantity => 1 }, 100006);
	check('menu: entry position respected (window 1..1 -> album only, no entry)',
		@{ $out->{items} || [] } == 1 && $out->{offset} == 1 && $out->{total} == 3
		&& ($out->{items}[0]{name} || '') =~ /蛊真人/);

	# window starting at the entry position renders just the entry
	Plugins::Ximalaya::Categories::rankFeed($client, sub { $out = shift }, { index => 2, quantity => 50 }, 100006);
	check('menu: window at entry position -> entry only, passthrough slug',
		@{ $out->{items} || [] } == 1
		&& ($out->{items}[0]{name} || '') eq 'PLUGIN_XIMALAYA_ALL_ALBUMS');

	# allFeed: web full catalog via authoritative slug (zero guessed slugs)
	my @all_args;
	local *Plugins::Ximalaya::API::categoryAlbums = sub {
		my ($class, $catId, $sortKey, $page, $perPage, $cb, $ecb) = @_;
		@all_args = ($catId, $sortKey, $page, $perPage);
		$cb->([
			{ id => 1, title => 'A', announcer => 'x', cover => '//imagev2.xmcdn.com/a', paid => 0 },
			{ id => 2, title => 'B', announcer => 'y', cover => '//imagev2.xmcdn.com/b', paid => 1 },
		], 1620831);
	};
	Plugins::Ximalaya::Categories::allFeed($client, sub { $out = shift }, { index => 50, quantity => 50 }, 'youshengshu');
	check('menu: allFeed pages web catalog with exact total',
		"@all_args" eq 'youshengshu hot 2 50'
		&& $out->{offset} == 50 && $out->{total} == 1620831
		&& @{ $out->{items} || [] } == 2
		&& ($out->{items}[0]{name} || '') =~ /^A - x/);
}

# ------------------------------------- cooldown family split (must be LAST)
{
	my @calls;
	local *Plugins::Ximalaya::API::albumTracksMobile = sub {
		my ($class, $albumId, $page, $size, $cb, $ecb) = @_;
		push @calls, 'mobile';
		$cb->([{ id => 8, title => 'm', paid => 0, cover => '' }], 60);
	};
	local *Plugins::Ximalaya::API::albumTracksShow = sub {
		my ($class, $albumId, $page, $size, $cb, $ecb) = @_;
		push @calls, 'pc';
		$cb->([], 0);
	};
	local *Plugins::Ximalaya::API::albumTracks = sub {
		my ($class, $albumId, $page, $size, $cb, $ecb) = @_;
		push @calls, 'web';
		$cb->([{ id => 7, title => 'w', paid => 0, cover => '' }], 50);
	};
	my ($out, $client) = ({}, bless({}, 'StubClient'));

	# pc family cooling -> mobile PRIMARY still serves (independent family)
	Plugins::Ximalaya::Plugin::note_risk_hit('tracks');
	check('cooling: pc family (tracks) is cooling', Plugins::Ximalaya::Plugin::_cooling('tracks'));
	Plugins::Ximalaya::Plugin::albumHandler($client, sub { $out = shift },
		{ index => 0, quantity => 50 }, 12148879);
	check('cooling: pc cooling does not touch mobile primary', "@calls" eq 'mobile' && @{ $out->{items} } == 1);

	# mobile family ALSO cooling -> skips mobile AND cooling pc -> web serves
	Plugins::Ximalaya::Plugin::note_risk_hit('tracks_mobile');
	check('cooling: mobile family is cooling', Plugins::Ximalaya::Plugin::_cooling('tracks_mobile'));
	@calls = ();
	Plugins::Ximalaya::Plugin::albumHandler($client, sub { $out = shift },
		{ index => 0, quantity => 50 }, 12148879);
	check('cooling: mobile cooling + pc cooling -> web serves', "@calls" eq 'web' && @{ $out->{items} } == 1);

	# web-only mode + its own family cooling -> cooldown hint, zero calls
	$prefs->set('pc_channel', 0);
	Plugins::Ximalaya::Plugin::note_risk_hit('tracks_web');
	Plugins::Ximalaya::Plugin::albumHandler($client, sub { $out = shift },
		{ index => 0, quantity => 50 }, 12148879);
	check('cooling: pc off + tracks_web cooling -> cooldown hint', "@calls" eq 'web'
		&& ($out->{items}[0]{name} || '') eq 'PLUGIN_XIMALAYA_COOLDOWN');
	$prefs->set('pc_channel', 1);
}

# ------------------------------------ render-time publication (0.1.47)
# User report: a track added with the album row's "+" button showed a queue
# row with no title and no artwork (playable), while the page's "play whole
# album" button produced fully labelled rows. Root cause: the row's add
# action is 'playlist add xmly://<id>', and explodePlaylist returns a
# non-album URL unchanged (ProtocolHandler L58-62), so nothing ever
# published metadata for it - an added-but-unplayed row has no DB row and
# getMetadataFor answers {}. Fix: trackItem publishes while the row is
# built. This guard pins the whole chain: render -> publish -> DB row +
# image cache -> getMetadataFor queue fallback.
{
	Slim::Music::Info::reset_remote_meta();
	Slim::Schema::clear_rows();
	Slim::Utils::Cache::clear_store();

	my $row = { id => 420000111, title => '第1集', paid => 0,
	            cover => 'https://c/1.jpg', duration => 601 };

	my $before = Plugins::Ximalaya::ProtocolHandler->getMetadataFor(undef, 'xmly://420000111');
	check('0.1.47: an added-but-unrendered track has NO queue metadata (the reported bug)',
		$before && !scalar keys %$before);

	# rendering the row IS the fix - zero API calls, data already in hand
	Plugins::Ximalaya::Plugin::trackItem(1, $row);

	check('0.1.47: trackItem publishes title/secs/cover into the track row + image cache',
		Slim::Schema->get_row('xmly://420000111')->{title} eq '第1集'
		&& Slim::Schema->get_row('xmly://420000111')->{secs} == 601
		&& Slim::Utils::Cache->new->get('remote_image_xmly://420000111') eq 'https://c/1.jpg');

	my $after = Plugins::Ximalaya::ProtocolHandler->getMetadataFor(undef, 'xmly://420000111');
	check('0.1.47: the row "+" queue row now renders title + duration + artwork',
		$after && $after->{title} eq '第1集' && $after->{duration} == 601
		&& $after->{cover} eq 'https://c/1.jpg');

	# control: never rendered, never played -> still empty, so the fix is
	# provably the render-time publication and not some global change
	my $ctrl = Plugins::Ximalaya::ProtocolHandler->getMetadataFor(undef, 'xmly://999000111');
	check('0.1.47: control - a never-rendered track still answers empty metadata',
		$ctrl && !scalar keys %$ctrl);

	# placeholder protection carried over from 0.1.44: nothing publishable
	Slim::Schema::clear_rows();
	Plugins::Ximalaya::Plugin::trackItem(2, { id => 420000112, title => '?', cover => '', duration => 0 });
	check('0.1.47: a placeholder-only row publishes nothing (no bogus DB row)',
		!Slim::Schema->get_row('xmly://420000112'));

	check('0.1.47: _publish_queue_metadata returns the published-url count',
		Plugins::Ximalaya::ProtocolHandler->_publish_queue_metadata(
			[ $row, { id => 420000113, title => '?', cover => '', duration => 0 } ]) == 1);

	Slim::Schema::clear_rows();
	Slim::Utils::Cache::clear_store();
	Slim::Music::Info::reset_remote_meta();
}

print $fail ? "\nPC STUB TESTS FAILED\n" : "\nALL PC STUB TESTS PASSED ($n)\n";
exit($fail ? 1 : 0);
