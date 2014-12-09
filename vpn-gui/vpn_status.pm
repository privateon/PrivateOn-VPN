package vpn_status;

#
# PrivateOn-VPN -- Because privacy matters.
#
# Copyright (C) 2014  PrivateOn / Tietosuojakone Oy, Helsinki, Finland
# All rights reserved. Use is subject to license terms.
#

#
#  vpn-gui/vpn_status.pm     Communication from GUI to the backend daemon
#


use strict;
use warnings;

use IO::Socket::INET;


sub import{
	no strict 'refs';
	foreach (@_) {
		*{"vpn_window::$_"}=\&$_;
		*{"vpn_tray::$_"}=\&$_;
	 }
}


use constant {
	NET_UNPROTECTED => 0,
	NET_PROTECTED   => 1,
	NET_BROKEN      => 2,
	NET_CRIPPLED    => 3,
	NET_ERROR       => 99,
	NET_UNKNOWN     => 100
};


sub getApiStatus {
	$| = 1;
	my $sock = IO::Socket::INET->new(
		PeerHost => '127.0.0.1',
		PeerPort => '44244',
		Proto => 'tcp',
	);
	return NET_ERROR unless $sock;
	$sock->send("get-api-status\n");
	shutdown($sock, 1);
	my $response = "";
	$sock->recv($response, 4);
	$sock->close();
	chomp($response);
	return $response;
}

sub getCripplingStatus {
	$| = 1;
	my $sock = IO::Socket::INET->new(
		PeerHost => '127.0.0.1',
		PeerPort => '44244',
		Proto => 'tcp',
	);
	return NET_ERROR unless $sock;
	$sock->send("check-crippling\n");
	shutdown($sock, 1);
	my $response = "";
	$sock->recv($response, 4);
	$sock->close();
	chomp($response);
	return $response;
}


sub getNetStatus {
	$| = 1;
	my $sock = IO::Socket::INET->new(
		PeerHost => '127.0.0.1',
		PeerPort => '44244',
		Proto => 'tcp',
	);
	return NET_ERROR unless $sock;
	$sock->send("get-net-status\n");
	shutdown($sock, 1);
	my $response = "";
	$sock->recv($response, 4);
	$sock->close();
	chomp($response);
	return $response;
}


sub takeABreak {
	$| = 1;
	my $sock = IO::Socket::INET->new(
		PeerHost => '127.0.0.1',
		PeerPort => '44244',
		Proto => 'tcp',
	);
	return NET_ERROR unless $sock;
	$sock->send("take-a-break\n");
	# response is not important
	shutdown($sock, 1);
	$sock->close();
}


sub removeDispatcher {
	$| = 1;
	my $sock = IO::Socket::INET->new(
		PeerHost => '127.0.0.1',
		PeerPort => '44244',
		Proto => 'tcp',
	);
	return NET_ERROR unless $sock;
	$sock->send("remove-dispatcher\n");
	# response is not important
	shutdown($sock, 1);
	$sock->close();
}


sub disableMonitor {
	$| = 1;
	my $sock = IO::Socket::INET->new(
		PeerHost => '127.0.0.1',
		PeerPort => '44244',
		Proto => 'tcp',
	);
	return NET_ERROR unless $sock;
	$sock->send("disable-monitor\n");
	# response is not important
	shutdown($sock, 1);
	$sock->close();
}


sub enableMonitor {
	$| = 1;
	my $sock = IO::Socket::INET->new(
		PeerHost => '127.0.0.1',
		PeerPort => '44244',
		Proto => 'tcp',
	);
	return NET_ERROR unless $sock;
	$sock->send("enable-monitor\n");
	# response is not important
	shutdown($sock, 1);
	$sock->close();
}


sub undoCrippling {
	$| = 1;
	my $sock = IO::Socket::INET->new(
		PeerHost => '127.0.0.1',
		PeerPort => '44244',
		Proto => 'tcp',
	);
	return NET_ERROR unless $sock;
	$sock->send("undo-crippling\n");
	# response is not important
	shutdown($sock, 1);
	$sock->close();
}


sub forceRefresh {
	$| = 1;
	my $sock = IO::Socket::INET->new(
		PeerHost => '127.0.0.1',
		PeerPort => '44244',
		Proto => 'tcp',
	);
	return NET_ERROR unless $sock;
	$sock->send("force-refresh\n");
	# response is not important
	shutdown($sock, 1);
	$sock->close();
}

1;
