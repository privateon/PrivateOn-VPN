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
		*{"MainWindow::$_"}=\&$_;
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


sub get_api_status
{
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


sub get_net_status()
{
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


sub take_a_break()
{
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


sub remove_dispatcher()
{
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


sub disable_monitor()
{
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


sub enable_monitor()
{
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


sub undo_crippling()
{
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


sub force_refresh()
{
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
