# t/Slim/Player/Protocols/HTTPS.pm - minimal stub for offline compile/run tests.
package Slim::Player::Protocols::HTTPS;

use strict;
use warnings;

sub new { return bless {}, $_[0] }
sub canDoAction { return 0 }

1;
