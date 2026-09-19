# Plugins::Ximalaya::Categories
#
# 0.1.13: the whole browse tree lives on the PC-client rank endpoints
# (independent risk-control domain, authoritative dynamic table):
#
#   feed      -> rankTabs?sceneId=1   : channels (全站/小说/相声评书/...)
#   tabFeed   -> rankTabs (cached)    : charts per channel (热播/新品/免费/VIP...)
#   rankFeed  -> rank/v4/element      : one chart's albums, FULL details
#                                       (~100 entries, isPaid available),
#                                       no server paging - windowed locally.
#
# This replaces the 0.1.11 web category browse: its 8 category slugs were
# placeholders and 6 of them 404'd on device (only youshengshu/xiangsheng
# were ever verified), and the web endpoint's authoritative category-table
# route (queryAllCategory) is gone (verified 404 on 2026-09-10).
# The legacy web parser stays in API.pm (categoryAlbums) as a dormant
# fallback asset; Plugins::Ximalaya::API::categoryAlbums is no longer
# called from the menu.
#
# rankTabs is HTTP-cached 1h and rankAlbums 30min (SimpleAsyncHTTP cache),
# so menu navigation costs ONE network request per chart entry point.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License, version 2.

package Plugins::Ximalaya::Categories;

use strict;
use warnings;

# THIS FILE CONTAINS UTF-8 LITERALS (menu fallback names).
# Without this pragma Perl treats the source bytes as native (latin-1),
# and the menu output gets double-encoded -> mojibake on the device.
use utf8;

use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Log;

use Plugins::Ximalaya::API;

my $log = logger('plugin.ximalaya');

# Legacy static table - superseded by the dynamic rankTabs table above.
# Kept only as a reference of the 0.1.11 placeholders (compile_check
# asserts this method exists).
my @CATEGORIES = (
	{ id => 'youshengshu', name => '有声书' },
	{ id => 'xiangsheng',  name => '相声评书' },
	{ id => 'tansuo',      name => '探案推理' },
	{ id => 'lishi',       name => '历史' },
	{ id => 'renwen',      name => '人文' },
	{ id => 'yinyue',      name => '音乐' },
	{ id => 'ertong',      name => '儿童' },
	{ id => 'yingyu',      name => '外语' },
);

sub categories {
	return @CATEGORIES;
}

# ------------------------------------------------- top-level channel menu

sub feed {
	my ($class, $client, $cb) = @_;

	Plugins::Ximalaya::API->rankTabs(
		sub {
			my ($tabs) = @_;
			my @items = map {
				{
					name        => $_->{name},
					type        => 'link',
					url         => \&tabFeed,
					passthrough => [ $_->{id} ],
				}
			} @$tabs;
			$cb->({ items => \@items });
		},
		sub {
			$cb->({ items => [ Plugins::Ximalaya::Plugin::errItem($client, $_[0]) ] });
		},
	);

	return;
}

# -------------------------------------------------- chart menu per channel

sub tabFeed {
	# XMLBrowser calls coderef feeds as: handler($client, $cb, \%args, @passthrough)
	my ($client, $cb, $args, $tabId) = @_;
	$tabId ||= 0;

	Plugins::Ximalaya::API->rankTabs(
		sub {
			my ($tabs) = @_;
			my ($tab) = grep { ($_->{id} || 0) == $tabId } @$tabs;
			unless ($tab) {
				$cb->({ items => [ { name => cstring($client, 'PLUGIN_XIMALAYA_ERR_API'), type => 'text' } ] });
				return;
			}
			my @items = map {
				{
					name        => $_->{name},
					type        => 'link',
					url         => \&rankFeed,
					passthrough => [ $_->{rankingId} ],
				}
			} @{ $tab->{ranks} };
			$cb->({ items => \@items });
		},
		sub {
			$cb->({ items => [ Plugins::Ximalaya::Plugin::errItem($client, $_[0]) ] });
		},
	);

	return;
}

# --------------------------------------------- windowed album list per chart
# The endpoint returns the FULL chart (~100 albums) in one reply, so the
# XMLBrowser window (index/quantity) is sliced locally - offset and total
# are exact, no hasMore estimation needed.
#
# 0.1.14: charts are TOP-100 rankings by design, so a trailing "browse ALL
# albums" entry is appended at position @$albums when the chart carries an
# authoritative categoryCode - it opens the WEB full-catalog list
# (queryCategoryPageAlbums, verified zero risk-control on 2026-09-10,
# exact total), so nothing is capped at 100 anymore.

sub rankFeed {
	my ($client, $cb, $args, $rankingId) = @_;
	$rankingId ||= 0;

	my $quantity = $args->{quantity} || 50;
	$quantity = 1   if $quantity < 1;
	$quantity = 200 if $quantity > 200;
	my $index = $args->{index} || 0;

	Plugins::Ximalaya::API->rankAlbums($rankingId,
		sub {
			my ($albums, $total, $code) = @_;

			my @items;
			if ($index < @$albums) {
				my $last = $index + $quantity - 1;
				$last = $#$albums if $last > $#$albums;
				@items = map { Plugins::Ximalaya::Plugin::albumItem($_) } @{ $albums }[ $index .. $last ];
			}

			# trailing full-catalog entry at position @$albums (first window
			# that reaches past the last album renders it)
			if ($code && $index <= $#$albums + 1 && $index + $quantity > $#$albums + 1) {
				push @items, {
					name        => cstring($client, 'PLUGIN_XIMALAYA_ALL_ALBUMS'),
					type        => 'link',
					url         => \&allFeed,
					passthrough => [ $code ],
				};
			}

			$cb->({
				items  => \@items,
				offset => $index,
				total  => $total + ($code ? 1 : 0),
			});
		},
		sub {
			Plugins::Ximalaya::Plugin::note_risk_hit('category') if ($_[0] || '') eq 'risk';
			$cb->({ items => [ Plugins::Ximalaya::Plugin::errItem($client, $_[0]) ] });
		},
	);

	return;
}

# -------------------------------------- full catalog list per category (web)
# Powered by the authoritative categoryCode harvested from the chart
# (no guessed slugs). queryCategoryPageAlbums verified zero risk-control
# (2026-09-10, m0/diag_category.py) with exact data.total and stable
# 50/page - this is the FULL browse, unlike the 100-cap charts.
#
# 0.1.50 - two live-endpoint behaviours this has to absorb (probed 2026-09-19):
#
#  1. The catalog serves at most 50 rows per request whatever perPage says
#     (perPage=51/60/100 all echo pageSize=50). The UI window is normally
#     itemsPerPage (50), but ANY window wider than the cap made XMLBrowser pad
#     the short window with EMPTY rows - no artwork, and tapping one opened an
#     album with no id, i.e. the reported "no artwork / API error" rows. So the
#     window is now assembled from as many server pages as it needs.
#  2. A page occasionally comes back with pageSize=0/total=0 (an empty payload
#     for a perfectly valid category: gerenchengzhang perPage=48 did this, next
#     attempt was fine). That surfaced as "empty" -> an error row. One retry
#     with a different page size rides over it.
use constant CATALOG_SERVER_MAX => 50;   # observed pageSize cap
use constant CATALOG_RETRY_SIZE => 30;   # second chance for a short payload
use constant CATALOG_MAX_PAGES  => 8;    # safety: never fan out further

sub allFeed {
	# XMLBrowser windowing: index = first wanted item, quantity = items/page
	my ($client, $cb, $args, $catId) = @_;
	$catId ||= '';

	my $quantity = $args->{quantity} || 50;
	$quantity = 1   if $quantity < 1;
	$quantity = 200 if $quantity > 200;
	my $index = $args->{index} || 0;

	my $page_size  = $quantity > CATALOG_SERVER_MAX ? CATALOG_SERVER_MAX : $quantity;
	my $first_page = int($index / $page_size) + 1;
	my $skip       = $index % $page_size;   # rows to drop from the first page

	my $items_ref = [];    # every row fetched from $first_page on
	my ($total, $page, $batches);
	$page    = $first_page;
	$batches = 0;

	my $emit = sub {
		# @items holds every row fetched from $first_page on; the UI window is
		# [$skip, $skip + $quantity) inside that accumulation.
		my $last = $skip + $quantity - 1;
		$last = $#$items_ref if $last > $#$items_ref;
		my @window = $last >= $skip ? @$items_ref[ $skip .. $last ] : ();
		my $no_cover = grep { !($_->{cover} || '') } @window;
		$log->debug("Ximalaya: category $catId window=$index+$quantity -> "
			. scalar(@window) . " row(s), without-cover=$no_cover");
		$cb->({
			items  => [ map { Plugins::Ximalaya::Plugin::albumItem($_) } @window ],
			offset => $index,
			(defined $total ? (total => $total) : ()),
		});
		return;
	};

	my $fail = sub {
		my ($code) = @_;
		Plugins::Ximalaya::Plugin::note_risk_hit('category') if ($code || '') eq 'risk';
		$log->debug("Ximalaya: category $catId page $page failed ("
			. ($code // '?') . ") after $batches batch(es)");
		$cb->({ items => [ Plugins::Ximalaya::Plugin::errItem($client, $code) ] });
		return;
	};

	my $next;
	$next = sub {
		my ($size, $retried) = @_;
		Plugins::Ximalaya::API->categoryAlbums($catId, 'hot', $page, $size,
			sub {
				my ($albums, $t) = @_;
				my $got = scalar @$albums;

				$log->debug("Ximalaya: category $catId page $page/$size -> $got album(s), "
					. 'total=' . (defined $t ? $t : '?') . ", window=$index+$quantity");

				if ($got) {
					$total = $t if defined $t && !defined $total;
					push @$items_ref, @$albums;
					$batches++;
					$page++;

					# enough for the window, the server ran out, or the guard
					my $enough = @$items_ref >= $skip + $quantity;
					if ($enough || $got < $size || $batches >= CATALOG_MAX_PAGES) {
						$emit->();
						return;
					}
					$next->($page_size, 0);
					return;
				}

				# zero rows: either the flaky payload (retry once with another
				# page size) or simply the end of the catalogue
				if (!$retried) {
					$log->debug("Ximalaya: category $catId page $page empty - retry with "
						. CATALOG_RETRY_SIZE);
					$next->(CATALOG_RETRY_SIZE, 1);
					return;
				}
				if (@$items_ref) { $emit->(); return; }   # end of list
				$fail->('empty');
			},
			sub {
				my ($code) = @_;
				# the live endpoint sometimes reports an empty payload as an
				# error code - one retry at another size rides over it
				if (($code || '') eq 'empty' && !$retried) {
					$next->(CATALOG_RETRY_SIZE, 1);
					return;
				}
				if (@$items_ref) { $emit->(); return; }    # partial window beats an error row
				$fail->($code);
			},
		);
		return;
	};

	$next->($page_size, 0);

	return;
}

1;

__END__

=head1 NAME

Plugins::Ximalaya::Categories - pc rank based browse tree for Plugins::Ximalaya

=head1 SEE ALSO

Probes: _research/ximalaya-daphile-plugin/m0/pc_ranktabs.json,
pc_rank_element.json (both verified 2026-09-10)

=cut
