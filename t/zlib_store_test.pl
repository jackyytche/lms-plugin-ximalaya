#!/usr/bin/perl
# Offline verification for Sign.pm's pure-Perl zlib (stored blocks) builder.
use strict;
use warnings;
use constant INFOLOG => 0;

use FindBin;
use lib "$FindBin::Bin";
use lib "$FindBin::Bin/Plugins/Ximalaya";

require Plugins::Ximalaya::Sign;
use Compress::Zlib qw(uncompress);

my $pass = 0; my $fail = 0;
sub check {
	my ($name, $ok) = @_;
	if ($ok) { $pass++; print "ok   - $name\n"; }
	else     { $fail++; print "FAIL - $name\n"; }
}

my $z = \&Plugins::Ximalaya::Sign::_zlib_store;

# 1) empty payload (plugin always sends >0 bytes, but must not crash)
{
	my $in = '';
	my $out = $z->($in);
	check('empty: produced zlib stream', length($out) > 2);
	my $rt = uncompress($out);
	check('empty: inflate roundtrip', defined $rt && $rt eq $in);
}

# 2) typical device_info-sized payload
{
	my $in = join('', map { chr(int(rand(256))) } 1 .. 800);
	my $out = $z->($in);
	my $rt = uncompress($out);
	check('800 random bytes: roundtrip', defined $rt && $rt eq $in);
	check('800 random bytes: header 78 01', substr($out, 0, 2) eq "\x78\x01");
}

# 3) multi-block boundary (65535 / 65536 / 130000)
for my $size (65534, 65535, 65536, 130000) {
	my $in = join('', map { chr(int(rand(256))) } 1 .. $size);
	my $out = $z->($in);
	my $rt = uncompress($out);
	check("$size bytes: roundtrip", defined $rt && $rt eq $in);
}

# 4) binary-safe incl. NUL and 0xFF
{
	my $in = "\x00\xff\x00\x00\x78\x39\x00\xff" x 100;
	my $rt = uncompress($z->($in));
	check('binary NUL/FF safe', defined $rt && $rt eq $in);
}

# 5) utf8 payload identical to what gen() feeds it
{
	my $json = '{"deviceinfo":"喜马拉雅","Zf5":1725000000000}';
	require Encode;
	my $bytes = Encode::encode_utf8($json);
	my $rt = uncompress($z->($bytes));
	check('utf8 bytes roundtrip', defined $rt && $rt eq $bytes);
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
