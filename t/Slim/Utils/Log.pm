# t/Slim/Utils/Log.pm
#
# Minimal stub of Slim::Utils::Log for OFFLINE unit tests only.
# (LMS's real Slim::Utils::Log exports logger(); mirror that.)

package Slim::Utils::Log;

use strict;
use warnings;
use base qw(Exporter);

our @EXPORT    = qw(logger);
our @EXPORT_OK = qw(logger);

sub logger { return 'Slim::Utils::Log::Stub' }

sub addLogCategory {
	my ($class, $spec) = @_;
	return 'Slim::Utils::Log::Stub';
}

package Slim::Utils::Log::Stub;

use strict;
use warnings;

sub info     { }
sub warn     { }
sub error    { }
sub debug    { }
sub is_debug { 0 }
sub is_info  { 0 }
sub is_error { 1 }

1;
