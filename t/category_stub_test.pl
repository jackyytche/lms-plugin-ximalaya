#!/usr/bin/perl
# category_stub_test.pl - offline tests for the prewired category browse
# parsing (zero network). Covers Plugins::Ximalaya::API::_parse_category_albums
# against local fixtures plus the CATEGORY_API_ENABLED=0 'todo'
# short-circuit. Run before every release, together with compile_check.pl.
use strict;
use warnings;
no warnings qw(once redefine);   # test-only typeglob overrides below trip both
use constant INFOLOG => 0;
use constant WEBUI  => 1;    # main-package constant, mirrored like compile_check.pl

# UTF-8 literals below (fixture comparisons); without this pragma the
# eq comparisons against utf8-flagged decoded JSON would fail.
use utf8;

use FindBin;
use lib File::Spec->catdir($FindBin::Bin);
use lib File::Spec->catdir($FindBin::Bin, 'Plugins', 'Ximalaya');

use JSON::PP ();

require Slim::Player::ProtocolHandlers;   # stub; ProtocolHandler.pm registers at compile time
require Plugins::Ximalaya::API;
require Plugins::Ximalaya::Plugin;   # cooldown wiring lives there (P1-1)

my $fail = 0;
my $n    = 0;
sub check {
	my ($name, $ok) = @_;
	$n++;
	$fail++ unless $ok;
	print($ok ? "ok   - $name\n" : "FAIL - $name\n");
}

# load fixtures (decoded text, mirroring what from_json hands the parser)
my $fixfile = File::Spec->catfile($FindBin::Bin, 'fixtures_category.json');
open my $fh, '<:encoding(UTF-8)', $fixfile or die "cannot read $fixfile: $!";
local $/;
my $fixtures = JSON::PP->new->decode(<$fh>);
close $fh;

# --- parse: search-alike shape (data.albumsResult.docs)
my ($albums, $total) = Plugins::Ximalaya::API->_parse_category_albums($fixtures->{searchlike});
check('searchlike: parsed 3 albums',                $albums && @$albums == 3);
check('searchlike: total from data.total (42)',     defined $total && $total == 42);
check('searchlike: field mapping (id/title/paid)',  $albums->[0]{id} eq '111' && $albums->[0]{title} eq '刑侦冤家' && $albums->[0]{paid} == 1);
check('searchlike: tracksCount key fallback',       $albums->[2]{tracksCount} == 75);
check('searchlike: announcer mapping',              $albums->[1]{announcer} eq '播者B');

# --- parse: generic shape (data.docs, albumTitle/coverPath keys)
($albums, $total) = Plugins::Ximalaya::API->_parse_category_albums($fixtures->{generic});
check('generic: parsed 2 albums',                   $albums && @$albums == 2);
check('generic: total falls back to count (2)',     defined $total && $total == 2);
# 0.1.24: bare coverPath is absolutized by the unified _norm_cover
check('generic: albumTitle/coverPath mapping',      $albums->[0]{title} eq '史上特大案纪实' && $albums->[0]{cover} eq 'https://imagev2.xmcdn.com/a/b.jpg');
check('generic: paid mapping',                      $albums->[1]{paid} == 1);

# --- parse: real live shape captured 2026-09-10 (data.albums flat array,
#     albumId/anchorName/trackCount keys, protocol-relative coverPath)
($albums, $total) = Plugins::Ximalaya::API->_parse_category_albums($fixtures->{real2026});
check('real2026: parsed 2 albums',                  $albums && @$albums == 2);
check('real2026: total from data.total (1620831)',  defined $total && $total == 1620831);
check('real2026: albumId/anchorName mapping',       $albums->[0]{id} == 81519744 && $albums->[0]{announcer} eq '老宝玉_白玉京');
check('real2026: protocol-relative cover fixed',    $albums->[0]{cover} eq 'https://imagev2.xmcdn.com/storages/fbf9/1.jpeg');
check('real2026: isPaid bool -> paid flags',        $albums->[0]{paid} == 1 && $albums->[1]{paid} == 0);
check('real2026: second album tracksCount',         $albums->[1]{tracksCount} == 5922);

# --- soft risk control
my @r = Plugins::Ximalaya::API->_parse_category_albums($fixtures->{risk});
check('risk: returns (undef, risk)',                !defined $r[0] && $r[1] eq 'risk');

# --- empty / unknown shape
@r = Plugins::Ximalaya::API->_parse_category_albums($fixtures->{empty});
check('empty: returns (undef, empty)',              !defined $r[0] && $r[1] eq 'empty');

# --- enabled=0 short-circuit: categoryAlbums must fail with 'todo' via
#     ecb and never reach the network (Sign->gen is never called)
{
	# package variable since 0.1.11 (was a compile-time constant), so the
	# offline test can re-verify the zero-network short-circuit
	local $Plugins::Ximalaya::API::CATEGORY_API_ENABLED = 0;
	my ($got, $via);
	Plugins::Ximalaya::API->categoryAlbums('youshengshu', 'hot', 1, 30,
		sub { $via = 'cb'; },
		sub { $got = shift; $via = 'ecb'; },
	);
	check('enabled=0: ecb(todo), cb never called', $via eq 'ecb' && $got eq 'todo');
}

# --- enabled=1 wiring, still zero network: stub Sign->gen and _json_get,
#     capture the built request, inject the real live fixture
{
	local *Plugins::Ximalaya::Sign::gen = sub {
		my ($class, $cb, $ecb) = @_;
		$cb->('STUBSIGN');
	};
	my ($url, $headers);
	local *Plugins::Ximalaya::API::_json_get = sub {
		my ($class, $u, $h, $cb, $ecb) = @_;
		($url, $headers) = ($u, $h);
		$cb->($fixtures->{real2026});
		return;
	};
	my ($albums2, $total2, $via);
	Plugins::Ximalaya::API->categoryAlbums('youshengshu', 'hot', 2, 50,
		sub { $via = 'cb'; ($albums2, $total2) = @_; },
		sub { $via = 'ecb'; },
	);
	check('enabled=1: callback path taken',            $via eq 'cb');
	check('enabled=1: route + real param names',       $url =~ m{/revision/category/queryCategoryPageAlbums\?category=youshengshu&meta=&page=2&perPage=50&sort=0$}) if defined $url;
	check('enabled=1: xm-sign header attached',        defined $headers && $headers->{'xm-sign'} eq 'STUBSIGN');
	check('enabled=1: Referer is the category page',   defined $headers && $headers->{'Referer'} eq 'https://www.ximalaya.com/youshengshu');
	check('enabled=1: cb gets parsed albums + total',  $via eq 'cb' && $albums2 && @$albums2 == 2 && $total2 == 1620831);
}

# --- local cooldown wiring (audit P1-1): the category family must enter
#     cooldown when a soft-risk hit is recorded
{
	Plugins::Ximalaya::Plugin::note_risk_hit('category');
	check('note_risk_hit: category family cooling', Plugins::Ximalaya::Plugin::_cooling('category'));
}

# ------------------------------------------- 0.1.50 chart slug harvest
# The trailing "browse ALL albums in this category" row opens the WEB catalog
# with the chart's categoryCode. Taking the FIRST album's code was wrong: the
# 全站 charts mix categories, and some codes are not valid web slugs at all
# (probed 2026-09-19: category=qita -> ret=404 for every page size, which the
# menu showed as "API error").
{
	my $api = 'Plugins::Ximalaya::API';

	my $mixed = { data => { rankList => [ { albums => [
		{ id => 1, categoryCode => 'lishi' },
		{ id => 2, categoryCode => 'youshengshu' },
		{ id => 3, categoryCode => 'youshengshu' },
		{ id => 4, categoryCode => 'qita' },
		{ id => 5, categoryCode => 'youshengshu' },
		{ id => 6, categoryCode => 'lishi' },
	] } ] } };
	my ($al, $code) = $api->_parse_rank_albums($mixed);
	check('0.1.50: category slug = DOMINANT code, not the first album\'s',
		$code && $code eq 'youshengshu');

	my $only_bad = { data => { rankList => [ { albums => [
		{ id => 1, categoryCode => 'qita' },
		{ id => 2, categoryCode => '' },
	] } ] } };
	my (undef, $code2) = $api->_parse_rank_albums($only_bad);
	check('0.1.50: a chart with only invalid/empty codes offers NO browse-all row',
		defined $code2 && $code2 eq '');

	my $deny_tie = { data => { rankList => [ { albums => [
		{ id => 1, categoryCode => 'qita' },
		{ id => 2, categoryCode => 'yinyue' },
	] } ] } };
	check('0.1.50: denied code is dropped even when it leads',
		($api->_parse_rank_albums($deny_tie))[1] eq 'yinyue');
}

# ------------------------------------------- 0.1.50 allFeed window assembly
# The catalog caps a response at 50 rows (perPage 51/60/100 all echo 50). A UI
# window wider than that used to come back short, and XMLBrowser padded the
# missing slots with EMPTY rows - the reported "no artwork / API error" rows.
{
	require Plugins::Ximalaya::Categories;

	# stub the web catalog: 50 rows per page, 1000 albums total
	my $calls;
	local *Plugins::Ximalaya::API::categoryAlbums = sub {
		my ($class, $cat, $sort, $page, $size, $cb, $ecb) = @_;
		push @$calls, "$page/$size";
		my $n = $size > 50 ? 50 : $size;
		my @albums = map {
			{ id => ($page - 1) * 50 + $_ + 1, title => "a", cover => 'https://c/x.jpg',
			  announcer => '', paid => 0 }
		} 0 .. $n - 1;
		$cb->(\@albums, 1000);
	};

	# 50-wide window: one server call, no holes
	$calls = [];
	my ($out, $client) = ({}, bless({}, 'StubClient'));
	Plugins::Ximalaya::Categories::allFeed($client, sub { $out = shift },
		{ index => 0, quantity => 50 }, 'youshengshu');
	check('0.1.50: a 50-row window is one server call',
		"@$calls" eq '1/50' && @{ $out->{items} } == 50 && $out->{offset} == 0
		&& $out->{total} == 1000);

	# helper: the album id survives in the row's favourites url
	my $ids = sub {
		my ($out) = @_;
		return join ',', map { (($_->{favorites_url} || '') =~ /album=(\d+)/) ? $1 : '?' }
			@{ $out->{items} };
	};

	# 100-wide window: assembled from two server pages, still no holes
	$calls = [];
	($out, $client) = ({}, bless({}, 'StubClient'));
	Plugins::Ximalaya::Categories::allFeed($client, sub { $out = shift },
		{ index => 0, quantity => 100 }, 'youshengshu');
	check('0.1.50: a 100-row window is filled from two server pages (no empty rows)',
		"@$calls" eq '1/50 2/50' && @{ $out->{items} } == 100
		&& $ids->($out) =~ /^1,2,.*,100$/);

	# window starting mid-server-page: first page dropped rows are skipped
	$calls = [];
	($out, $client) = ({}, bless({}, 'StubClient'));
	Plugins::Ximalaya::Categories::allFeed($client, sub { $out = shift },
		{ index => 60, quantity => 50 }, 'youshengshu');
	check('0.1.50: index=60 skips within the server page and fills the window',
		"@$calls" eq '2/50 3/50' && @{ $out->{items} } == 50
		&& $out->{offset} == 60 && $ids->($out) =~ /^61,62,.*,110$/);

	# the live endpoint intermittently answers pageSize=0/total=0 for a VALID
	# category: one retry at another page size must ride over it (and the
	# window still gets filled, here by continuing with the next page)
	$calls = [];
	my $seen = 0;
	local *Plugins::Ximalaya::API::categoryAlbums = sub {
		my ($class, $cat, $sort, $page, $size, $cb, $ecb) = @_;
		push @$calls, "$page/$size";
		if ($seen++ == 0) { $ecb->('empty'); return; }
		$cb->([ map { { id => $_, title => "a", cover => 'https://c/x.jpg' } } 1 .. $size ], 1000);
	};
	($out, $client) = ({}, bless({}, 'StubClient'));
	Plugins::Ximalaya::Categories::allFeed($client, sub { $out = shift },
		{ index => 0, quantity => 50 }, 'gerenchengzhang');
	check('0.1.50: an empty payload is retried once at another page size',
		"@$calls" =~ /^1\/50 1\/30 /
		&& @{ $out->{items} } == 50);

	# a genuine endpoint error (invalid slug -> ret 404) still surfaces, with a
	# dedicated message instead of a bare "API error"
	$calls = [];
	local *Plugins::Ximalaya::API::categoryAlbums = sub {
		my ($class, $cat, $sort, $page, $size, $cb, $ecb) = @_;
		push @$calls, "$page/$size";
		$ecb->(404);
	};
	($out, $client) = ({}, bless({}, 'StubClient'));
	Plugins::Ximalaya::Categories::allFeed($client, sub { $out = shift },
		{ index => 0, quantity => 50 }, 'qita');
	check('0.1.50: invalid slug -> one message row, no retry storm',
		@$calls == 1 && @{ $out->{items} } == 1
		&& ($out->{items}[0]{name} || '') eq 'PLUGIN_XIMALAYA_ERR_CATEGORY');
}

# ------------------------------------------- 0.1.52 cover directive stripping
# Some feeds append a CDN processing directive after the extension
# (!op_type=0&magick=webp&unlimited=0 on the web category feed). Those URLs are
# the only cover form the plugin hands out that carries an ampersand / asks for
# webp, while every form that renders in the Daphile UI is plain - so the
# directive is stripped and the plain original is served.
{
	my $api = 'Plugins::Ximalaya::API';
	check('0.1.52: category-feed cover directive stripped to the plain original',
		$api->_norm_cover('//imagev2.xmcdn.com/storages/a/b.jpeg!op_type=0&magick=webp&unlimited=0')
			eq 'https://imagev2.xmcdn.com/storages/a/b.jpeg');
	check('0.1.52: favourites cover directive stripped; plain forms untouched',
		$api->_norm_cover('//imagev2.xmcdn.com/s/c.png!op_type=3&columns=290&rows=290&magick=png')
			eq 'https://imagev2.xmcdn.com/s/c.png'
		&& $api->_norm_cover('storages/x/y.jpeg') eq 'https://imagev2.xmcdn.com/storages/x/y.jpeg'
		&& $api->_norm_cover('https://a/b/plain.jpg') eq 'https://a/b/plain.jpg'
		&& $api->_norm_cover('http://a/b/old.jpg') eq 'https://a/b/old.jpg');
}

print $fail ? "\nCATEGORY STUB TESTS FAILED\n" : "\nALL CATEGORY STUB TESTS PASSED ($n)\n";
exit($fail ? 1 : 0);
