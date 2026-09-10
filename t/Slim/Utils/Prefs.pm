# t/Slim/Utils/Prefs.pm - minimal stub for offline compile/run tests.
package Slim::Utils::Prefs;

use strict;
use warnings;
use base qw(Exporter);

our @EXPORT    = qw(preferences);
our @EXPORT_OK = qw(preferences);

my %instances;

sub preferences {
	my ($ns) = @_;
	$instances{$ns} ||= Slim::Utils::Prefs::Stub->new($ns);
	return $instances{$ns};
}

package Slim::Utils::Prefs::Stub;

use strict;
use warnings;

sub new {
	my ($class, $ns) = @_;
	return bless { ns => $ns, data => {} }, $class;
}

sub init { my ($self, $defaults) = @_; $self->{data} = { %{$self->{data} || {}}, %{$defaults || {}} }; return }
sub get  { my ($self, $k) = @_; return $self->{data}{$k} }
sub set  { my ($self, $k, $v) = @_; $self->{data}{$k} = $v; return }
sub client { return Slim::Utils::Prefs::Stub->new('client') }

1;
