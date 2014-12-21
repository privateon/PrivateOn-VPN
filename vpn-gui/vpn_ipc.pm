package vpn_ipc;

#
# PrivateOn-VPN -- Because privacy matters.
#
# Copyright (C) 2014  PrivateOn / Tietosuojakone Oy, Helsinki, Finland
# All rights reserved. Use is subject to license terms.
#

#
#  vpn-gui/vpn_ipc.pm     Communication from GUI to the backend daemon
#


use strict;
use warnings;
use English;

use IO::Socket::INET;


sub import {
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

use constant {
	IPC_HOST        => '127.0.0.1',
	IPC_PORT        => 44244
};


################           Helper subroutines           ################

sub sendBackendCommand {
	my $command = shift;
	
	$OUTPUT_AUTOFLUSH = 1;
	my $sock = IO::Socket::INET->new(
		PeerHost => IPC_HOST,
		PeerPort => IPC_PORT,
		Proto => 'tcp',
	);
	
	return unless $sock;
	$sock->send( $command . "\n" );
	shutdown($sock, 1);
	$sock->close();
}


sub sendBackendQuery {
	my $command = shift;
	
	$OUTPUT_AUTOFLUSH = 1;
	my $sock = IO::Socket::INET->new(
		PeerHost => IPC_HOST,
		PeerPort => IPC_PORT,
		Proto => 'tcp',
	);
	
	return NET_ERROR unless $sock;
	$sock->send( $command . "\n" );
	shutdown($sock, 1);
	my $response = "";
	$sock->recv($response, 4);
	$sock->close();
	chomp($response);

	# was response "say what?" for wrong command
	if ($response =~ /say/i) {
		print "Error: backend did not understand Command \"$command\" \n";
		return NET_UNKNOWN;
	}
	return $response;
}


################            Backend Commands            ################

sub takeABreak {
	sendBackendCommand("take-a-break");
}

sub removeDispatcher {
	sendBackendCommand("remove-dispatcher");
}

sub disableMonitor {
	sendBackendCommand("disable-monitor");
}

sub enableMonitor {
	sendBackendCommand("enable-monitor");
}

sub undoCrippling {
	sendBackendCommand("undo-crippling");
}

sub forceRefresh {
	sendBackendCommand("force-refresh");
}


################            Backend Queries             ################

sub getApiStatus {
	return sendBackendQuery("get-api-status");
}

sub getNetStatus {
	return sendBackendQuery("get-net-status");
}

sub getCripplingStatus {
	return sendBackendQuery("check-crippling");
}

sub getMonitorState {
	return sendBackendQuery("monitor-state");
}


1;
