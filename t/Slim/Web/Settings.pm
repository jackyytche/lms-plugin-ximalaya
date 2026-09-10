# t/Slim/Web/Settings.pm - minimal stub for offline compile/run tests.
package Slim::Web::Settings;

use strict;
use warnings;

sub new { return bless {}, $_[0] }
sub name { return 'stub' }
sub page { return 'stub.html' }

1;
