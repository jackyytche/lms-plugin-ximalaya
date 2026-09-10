# t/Slim/Player/ProtocolHandlers.pm - minimal stub for offline compile/run tests.
package Slim::Player::ProtocolHandlers;

use strict;
use warnings;

# Real LMS: registers handler subs/URL schemes. Offline: accept and ignore.
sub registerHandler { }
sub registerOggHandler   { }
sub registerFlacHandler  { }
sub registerPlayHandler  { }
sub registerProtocolHandler { }

1;
