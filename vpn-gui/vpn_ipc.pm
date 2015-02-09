package vpn_ipc;

#
# PrivateOn-VPN -- Because privacy matters.
#
# Copyright (C) 2014-2015  PrivateOn / Tietosuojakone Oy, Helsinki, Finland
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
	NET_OFFLINE     => 2,
	NET_CRIPPLED    => 3,
	NET_BROKEN      => 4,
	NET_UNCONFIRMED => 5,
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

	# make INET connection refused nonfatal
	eval {	
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
	};
}


sub sendBackendQuery {
	my $command = shift;
	
	# make INET connection refused nonfatal
	eval {	
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
		$sock->recv($response, 40);
		$sock->close();
		chomp($response);
		return $response;
	};
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
	my $response = sendBackendQuery("get-api-status");

	# was response "say what?" for wrong command
	if ($response =~ /say/i) {
		print "Error: backend did not understand query \"get-api-status\" \n";
		return NET_UNKNOWN;
	}
	# if not numeric
	unless ($response =~ /^\d+$/ ) {
		print "Error: backend query \"get-api-status\" gave non-numeric response \"$response\" \n";
		return NET_UNKNOWN;
	} 
	return $response;
}


sub getNetStatus {
	my $response = sendBackendQuery("get-net-status");

	# was response "say what?" for wrong command
	if ($response =~ /say/i) {
		print "Error: backend did not understand query \"get-net-status\" \n";
		return NET_UNKNOWN;
	}
	# if not numeric
	unless ($response =~ /^\d+$/ ) {
		print "Error: backend query \"get-net-status\" gave non-numeric response \"$response\" \n";
		return NET_UNKNOWN;
	} 
	return $response;
}


sub getCripplingStatus {
	my $debug_flag = shift;

	my $response = sendBackendQuery("check-crippling");
	if ($response) {
		if ( defined($debug_flag) && $debug_flag > 0 ) {
 			print "Debug: check-crippling returned test result \"$response\" \n";
		}
		return 1;
	}
	return 0;
}


sub getMonitorState {
	my $debug_flag = shift;

	my $response = sendBackendQuery("monitor-state");
	unless ($response =~ /\S+-\S+-\S+/) {
		if ( defined($debug_flag) && $debug_flag > 0 ) {
 			print "Error: monitor-state returned invalid result \"$response\" \n";
		}
		# assume disabled and unknown
		$response = "Disabled-unknown-UNKNOWN";
	}
	return $response;
}


1;
