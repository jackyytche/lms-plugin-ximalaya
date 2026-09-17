# Slim::Utils::Favorites - offline stub for the plugin test suite.
#
# Minimal in-memory implementation of the API surface the plugin uses
# (new / all / hasUrl / add / deleteUrl). 0.1.46: all() now mirrors the
# REAL OpmlFavorites::all semantics - it takes an optional type regex and
# defaults to qr/audio|playlist/, SKIPPING entries whose type does not
# match (the real module L285-296; folder recursion is not type-gated).
# This matters: our web-UI album favourites are stored with type 'link',
# so plugin code must call all(qr//) to see them - the stub previously
# returned everything unfiltered and masked exactly this bug.
#   - all(;$typeRE) -> arrayref of { url, name, type, icon }
#   - hasUrl($u) -> 1 if stored (real module returns 1/0)
#   - add($url, $title, $type, $parser, $fresh, $icon)
#   - deleteUrl($url)
# Tests seed state via Slim::Utils::Favorites::set_store(...) and read it
# back with get_store().

package Slim::Utils::Favorites;

use strict;
use warnings;

my @STORE;    # rows: [ url, name, type, icon ]

sub new {
	my ($class, $client) = @_;
	return bless { client => $client }, $class;
}

sub all {
	my ($self, $typeRE) = @_;
	$typeRE ||= qr/audio|playlist/;    # real-module default (OpmlFavorites L285)
	return [ map {
		my $t = $_->[2] // 'link';
		($t =~ /$typeRE/)
			? { url => $_->[0], name => $_->[1], type => $t, icon => $_->[3] }
			: ();
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
