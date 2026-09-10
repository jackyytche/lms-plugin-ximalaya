# Plugins::Ximalaya::Settings
#
# Web settings page (Daphile: Settings -> Advanced Media Server Settings ->
# Plugins -> Ximalaya). Stores the user's own login cookie, preferred audio
# quality and the "my albums" id list.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License, version 2.

package Plugins::Ximalaya::Settings;

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.ximalaya');

sub name {
	return 'PLUGIN_XIMALAYA';
}

sub page {
	return 'plugins/Ximalaya/settings/basic.html';
}

sub prefs {
	return ($prefs, 'cookie', 'quality', 'albums', 'pc_channel', 'mobile_channel');
}

1;

__END__

=head1 NAME

Plugins::Ximalaya::Settings - web settings page

=cut
