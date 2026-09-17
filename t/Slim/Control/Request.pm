# t/Slim/Control/Request.pm - minimal stub for offline pc_stub_test.pl.
# The real module is the request/notification bus; the plugin only uses
# subscribe() (initPlugin dual-write favourites sync, 0.1.45). Tests never
# call initPlugin, but the stub keeps require happy and records
# subscriptions should a test want to assert the wiring.
package Slim::Control::Request;

use strict;
use warnings;

my @SUBSCRIPTIONS;    # [ [commands], [requests] ]

sub subscribe {
	my ($cb, $requests) = @_;
	push @SUBSCRIPTIONS, [ $cb, $requests ];
	return 1;
}

sub unsubscribe {
	my ($cb) = @_;
	@SUBSCRIPTIONS = grep { $_->[0] ne $cb } @SUBSCRIPTIONS;
	return 1;
}

# test introspection
sub subscriptions { return \@SUBSCRIPTIONS; }
sub clear_subscriptions { @SUBSCRIPTIONS = (); return 1; }

1;
