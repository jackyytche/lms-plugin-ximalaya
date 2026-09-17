# Slim::Music::Info stub for offline pc_stub_test.pl.
# Records the bitrate/duration the plugin publishes so tests can assert on
# them; mirrors the real module's class API used by ProtocolHandler.
# 0.1.44: setRemoteMetadata also mirrors the real module's persistence
# (Info.pm L467-489): TITLE/SECS land in the track row via Slim::Schema and
# the cover goes into the remote_image_ cache - so the queue-fallback chain
# (publish at enqueue -> read back in getMetadataFor) is testable end to end.
package Slim::Music::Info;

use strict;
use warnings;

use Slim::Schema;
use Slim::Utils::Cache;

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

	if ($url =~ /^xmly:/) {
		my $prev = Slim::Schema->get_row($url) || {};
		Slim::Schema->set_row($url, {
			title   => defined $meta->{title}   ? $meta->{title}   : $prev->{title},
			secs    => defined $meta->{secs}    ? $meta->{secs}    : $prev->{secs},
			bitrate => defined $meta->{bitrate} ? $meta->{bitrate} : $prev->{bitrate},
		});
		Slim::Utils::Cache->new->set("remote_image_$url", $meta->{cover}, '30 days')
			if $meta->{cover};
	}

	return 1;
}

# test introspection
sub published { return \%published; }
sub reset_published { %published = (); return 1; }
sub remote_meta { return \@remote_meta; }
sub reset_remote_meta { @remote_meta = (); return 1; }

1;
