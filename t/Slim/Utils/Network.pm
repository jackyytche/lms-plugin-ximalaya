# Slim::Utils::Network - offline stub for the plugin test suite.
# Only serverURL(); the real one is 'http://' . serverAddr() . ':' . httpport.

package Slim::Utils::Network;

use strict;
use warnings;

my $SERVER_URL = 'http://192.0.2.1:9000';

sub serverURL { return $SERVER_URL }

# test hook
sub set_server_url { $SERVER_URL = $_[0] || $SERVER_URL; return }

1;
