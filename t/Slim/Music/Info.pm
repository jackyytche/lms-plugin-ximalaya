# Slim::Music::Info stub for offline pc_stub_test.pl.
# Records the bitrate/duration the plugin publishes so tests can assert on
# them; mirrors the real module's class API used by ProtocolHandler.
package Slim::Music::Info;

use strict;
use warnings;

my %published;    # url => { bitrate =>, duration => }
my @remote_meta;  # setRemoteMetadata calls: [ url, \%meta ]

sub setBitrate {
	my ($class, $url, $bitrate) = @_;
	$published{$url}{bitrate} = $bitrate;
	return 1;
}

sub setDuration {
	my ($class, $url, $duration) = @_;
	$published{$url}{duration} = $duration;
	return 1;
}

sub setRemoteMetadata {
	my ($url, $meta) = @_;
	push @remote_meta, [ $url, $meta ];
	return 1;
}

# test introspection
sub published { return \%published; }
sub reset_published { %published = (); return 1; }
sub remote_meta { return \@remote_meta; }
sub reset_remote_meta { @remote_meta = (); return 1; }

1;
