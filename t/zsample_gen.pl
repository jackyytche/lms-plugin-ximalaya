use strict; use warnings; use constant INFOLOG => 0;
use FindBin; use lib "$FindBin::Bin"; use lib "$FindBin::Bin/Plugins/Ximalaya";
require Plugins::Ximalaya::Sign;
open my $fh, '>', "$FindBin::Bin/zsample.bin" or die $!;
binmode $fh;
print $fh Plugins::Ximalaya::Sign::_zlib_store('{"deviceinfo":"test","Zf5":1725000000000}');
close $fh;
print "sample written\n";
