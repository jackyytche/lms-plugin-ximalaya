# t/Slim/Utils/Strings.pm - minimal stub for offline compile/run tests.
package Slim::Utils::Strings;

use strict;
use warnings;
use base qw(Exporter);

our @EXPORT    = qw();
our @EXPORT_OK = qw(cstring string);

sub cstring {
	my ($client, $token, @args) = @_;
	return string($token, @args);
}

sub string {
	my ($token, @args) = @_;
	# mirror real behavior for missing tokens: fall back to the raw token
	return $token;
}

1;
