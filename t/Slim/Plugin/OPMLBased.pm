# t/Slim/Plugin/OPMLBased.pm - minimal stub for offline compile/run tests.
# The real class is a Class::C3 style base providing feed/menu plumbing;
# plugins only need it to exist and to provide ->new() at runtime.
package Slim::Plugin::OPMLBased;

use strict;
use warnings;

sub new {
	my ($class, %args) = @_;
	return bless { %args }, $class;
}

sub getDisplayName { return '' }

1;
