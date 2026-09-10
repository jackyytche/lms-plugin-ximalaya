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
check('generic: albumTitle/coverPath mapping',      $albums->[0]{title} eq '史上特大案纪实' && $albums->[0]{cover} eq 'a/b.jpg');
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

print $fail ? "\nCATEGORY STUB TESTS FAILED\n" : "\nALL CATEGORY STUB TESTS PASSED ($n)\n";
exit($fail ? 1 : 0);
