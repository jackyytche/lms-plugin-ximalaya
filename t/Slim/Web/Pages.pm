# Slim::Web::Pages - offline stub for the plugin test suite.
# Only the registration surface the plugin touches; a no-op.

package Slim::Web::Pages;

use strict;
use warnings;

my @REGISTERED;

sub addPageFunction {
	my ($class, $path, $handler) = @_;
	push @REGISTERED, [ $path, $handler ];
	return;
}

# test hook: what routes were registered
sub get_registered { return map { [ @{ $_ } ] } @REGISTERED }
sub clear_registered { @REGISTERED = (); return }

1;
