# Slim::Utils::Favorites - offline stub for the plugin test suite.
#
# Minimal in-memory implementation of the API surface the plugin uses
# (new / all / hasUrl / add / deleteUrl), mirroring the real module's
# semantics closely enough for the my-albums merge tests:
#   - all()      -> arrayref of { url, name, type, icon }
#   - hasUrl($u) -> 1 if stored (real module returns 1/0)
#   - add($url, $title, $type, $parser, $fresh, $icon)
#   - deleteUrl($url)
# Tests seed state via Slim::Utils::Favorites::set_store(...) and read it
# back with get_store().

package Slim::Utils::Favorites;

use strict;
use warnings;

my @STORE;

sub new {
	my ($class, $client) = @_;
	return bless { client => $client }, $class;
}

sub all {
	my ($self) = @_;
	return [ map {
		{ url => $_->[0], name => $_->[1], type => ($_->[2] || 'link'),
		  icon => $_->[3] }
	} @STORE ];
}

sub hasUrl {
	my ($self, $url) = @_;
	return (grep { $_->[0] eq $url } @STORE) ? 1 : 0;
}

sub add {
	my ($self, $url, $title, $type, $parser, $fresh, $icon) = @_;
	return if !defined $url || $self->hasUrl($url);
	push @STORE, [ $url, $title, $type, $icon ];
	return;
}

sub deleteUrl {
	my ($self, $url) = @_;
	@STORE = grep { $_->[0] ne $url } @STORE;
	return;
}

# ---- test hooks ----
# set_store_rows(@rows): each row is an [url, name, type?, icon?] arrayref
sub set_store_rows { @STORE = @_; return }
sub get_store { return map { [ @$_ ] } @STORE }

1;
