#!/usr/bin/perl
# compile_check.pl - offline equivalent of LMS's Slim::bootstrap::tryModuleLoad.
# Requires every plugin module in dependency order; any compile-time error
# (missing deps, undefined subs at compile time, syntax) fails here exactly
# like it does on the device. Run before EVERY release build.
use strict;
use warnings;
use constant INFOLOG => 0;

# mirror main-package constants normally defined by slimserver.pl
use constant WEBUI => 1;

use FindBin;
use lib File::Spec->catdir($FindBin::Bin);                     # Slim::* stubs
use lib File::Spec->catdir($FindBin::Bin, 'Plugins', 'Ximalaya');  # plugin files (Plugins::Ximalaya::*)

# make sure the real plugin files (not stub copies) are loaded
# LMS loads Slim::Player::ProtocolHandlers before any plugin; mirror that.
require Slim::Player::ProtocolHandlers;
print "ok   - Slim::Player::ProtocolHandlers loaded from: $INC{'Slim/Player/ProtocolHandlers.pm'}\n";

my @modules = (
	'Plugins::Ximalaya::XimaCrypt',
	'Plugins::Ximalaya::Sign',
	'Plugins::Ximalaya::API',
	'Plugins::Ximalaya::Categories',
	'Plugins::Ximalaya::ProtocolHandler',
	'Plugins::Ximalaya::Settings',
	'Plugins::Ximalaya::Plugin',
);

my $fail = 0;
for my $mod (@modules) {
	eval "require $mod";
	if ($@) {
		$fail++;
		print "FAIL - require $mod\n$@\n";
	} else {
		print "ok   - require $mod\n";
	}
}

# smoke: entry points exist per class role
my %expected = (
	'Plugins::Ximalaya::Plugin'          => 'initPlugin',
	'Plugins::Ximalaya::Categories'      => 'categories',
	'Plugins::Ximalaya::Settings'        => 'name',        # Slim::Web::Settings subclass
	'Plugins::Ximalaya::ProtocolHandler' => 'scanUrl',     # handler class, registered at compile time
);
for my $mod (sort keys %expected) {
	my $meth = $expected{$mod};
	my $ok   = $mod->can($meth) ? 1 : 0;
	$fail++ unless $ok;
	print($ok ? "ok   - $mod->$meth defined\n" : "FAIL - $mod->$meth missing\n");
}

print $fail ? "\nCOMPILE CHECK FAILED\n" : "\nCOMPILE CHECK PASSED\n";
exit($fail ? 1 : 0);
