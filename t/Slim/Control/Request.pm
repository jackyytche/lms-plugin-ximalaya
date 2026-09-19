# t/Slim/Control/Request.pm - minimal stub for offline pc_stub_test.pl.
# The real module is the request/notification bus; the plugin uses
# subscribe() (initPlugin dual-write favourites sync, 0.1.45) and
# notifyFromArray() (0.1.48 late-metadata signal). Tests never call
# initPlugin, but the stub keeps require happy and records both so tests can
# assert the wiring.
package Slim::Control::Request;

use strict;
use warnings;

my @SUBSCRIPTIONS;    # [ [cb, requests] ]
my @NOTIFICATIONS;    # [ [clientid, [verbs]] ]

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

# Queues a notification; the real one is delivered once per idle loop.
sub notifyFromArray {
	my ($client, $verbs) = @_;
	my $id = (ref $client && $client->can('id')) ? $client->id : $client;
	push @NOTIFICATIONS, [ $id, $verbs ];
	return 1;
}

# test introspection
sub subscriptions { return \@SUBSCRIPTIONS; }
sub clear_subscriptions { @SUBSCRIPTIONS = (); return 1; }
sub notifications { return \@NOTIFICATIONS; }
sub clear_notifications { @NOTIFICATIONS = (); return 1; }

1;
