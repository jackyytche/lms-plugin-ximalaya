# t/Slim/Schema.pm - minimal stub for offline pc_stub_test.pl.
# Models just what Plugins::Ximalaya::ProtocolHandler's queue fallback uses:
# track rows keyed by URL, holding the TITLE/SECS/BITRATE that
# Slim::Music::Info::setRemoteMetadata commits via updateOrCreate
# (Info.pm L467-472). objectForUrl returns a blessed row object or undef -
# the real one does NOT create rows unless asked.
package Slim::Schema;

use strict;
use warnings;

my %ROWS;    # url => { title =>, secs =>, bitrate => }

sub objectForUrl {
	my ($class, $args) = @_;
	my $url = ref $args ? ($args->{url} // '') : ($args // '');
	return undef unless exists $ROWS{$url};
	return bless {
		url     => $url,
		title   => $ROWS{$url}{title},
		secs    => $ROWS{$url}{secs},
		bitrate => $ROWS{$url}{bitrate},
	}, 'Slim::Schema::StubTrack';
}

# test hooks
sub set_row {
	my ($class, $url, $row) = @_;
	$ROWS{$url} = {
		title   => $row->{title},
		secs    => $row->{secs},
		bitrate => $row->{bitrate},
	};
	return 1;
}

sub get_row {
	my ($class, $url) = @_;
	return $ROWS{$url};
}

sub clear_rows { %ROWS = (); return 1; }

1;

package Slim::Schema::StubTrack;

use strict;
use warnings;

sub title   { $_[0]->{title} }
sub secs    { $_[0]->{secs} }
sub bitrate { $_[0]->{bitrate} }
sub url     { $_[0]->{url} }

1;
