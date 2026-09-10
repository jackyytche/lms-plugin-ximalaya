# t/JSON/XS/VersionOneAndTwo.pm
#
# Offline-test stand-in for the LMS-bundled JSON::XS::VersionOneAndTwo.
# On a real LMS/Daphile the bundled module is found first (@INC order), so
# this stub only ever loads in the unit-test environment (Strawberry Perl).

package JSON::XS::VersionOneAndTwo;

use strict;
use warnings;
use base qw(Exporter);

our @EXPORT_OK = qw(from_json to_json);
our @EXPORT    = qw(from_json to_json);

use JSON::PP ();

sub from_json {
	my ($json) = @_;
	return JSON::PP->new->decode($json);
}

sub to_json {
	my ($data) = @_;
	return JSON::PP->new->canonical->encode($data);
}

1;
