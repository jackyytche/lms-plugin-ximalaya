# t/Slim/Networking/SimpleAsyncHTTP.pm
#
# Minimal stub of Slim::Networking::SimpleAsyncHTTP for OFFLINE unit tests
# only (t/ximacrypt_test.pl). Captures the POST body and replays a canned
# response instead of doing real network I/O.

package Slim::Networking::SimpleAsyncHTTP;

use strict;
use warnings;

our $CAPTURE;      # last POST body seen
our $RESPONSE;     # canned response body handed to the success callback

sub new {
	my ($class, $cb, $ecb, $params) = @_;
	return bless { cb => $cb, ecb => $ecb, params => $params }, $class;
}

sub post {
	my ($self, $url, @rest) = @_;
	my $body = pop @rest;              # content is the last argument
	$CAPTURE = $body;
	$self->{cb}->($self);
	return;
}

sub get {
	my ($self, $url, @rest) = @_;
	$self->{cb}->($self);
	return;
}

sub content {
	my ($self) = @_;
	return $RESPONSE;
}

sub params {
	my ($self, $key) = @_;
	return $self->{params}{$key};
}

1;
