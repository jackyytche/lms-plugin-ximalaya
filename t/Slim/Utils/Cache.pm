# t/Slim/Utils/Cache.pm - in-memory stub of the disk cache for offline tests.
# The real cache persists across restarts; the stub just keeps a hash. The
# queue-fallback chain under test (remote_image_ cover entries written by
# Slim::Music::Info::setRemoteMetadata, read back by the protocol handler's
# getMetadataFor) only needs set/get semantics.
package Slim::Utils::Cache;

use strict;
use warnings;

my %STORE;    # key => value

sub new { return bless {}, shift }

sub get {
	my ($self, $key) = @_;
	return exists $STORE{$key} ? $STORE{$key} : undef;
}

sub set {
	my ($self, $key, $val, @ttl) = @_;    # TTL accepted, ignored
	$STORE{$key} = $val;
	return 1;
}

# test introspection
sub clear_store { %STORE = (); return 1; }
sub dump_store  { return \%STORE; }

1;
