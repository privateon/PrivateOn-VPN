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
	NET_UNPROTECTED	=> 1,
	NET_PROTECTED	=> 2,
	NET_NEGATIVE	=> 3,
	NET_CONFIRMING	=> 4,
	NET_UNCONFIRMED	=> 5,
	NET_CRIPPLED	=> 6,
	NET_OFFLINE     => 7,
	NET_BROKEN	=> 8,
	NET_ERROR	=> 9,
	NET_UNKNOWN	=> 10
};

use constant {
	IPC_HOST        => '127.0.0.1',
	IPC_PORT        => 44244
};


################           Helper subroutines           ################

sub sendBackendCommand {
	my ($command, $debug_flag) = @_;

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

		if ( defined($debug_flag) && $debug_flag > 1 ) {
			print "\n\t\tCommand '" . $command . "' sent to vpn-monitor\n";
		}
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
	my $debug_flag = shift;
	sendBackendCommand("take-a-break", $debug_flag);
}

sub resumeIdling {
	my $debug_flag = shift;
	sendBackendCommand("resume-idling", $debug_flag);
}

sub removeDispatcher {
	my $debug_flag = shift;
	sendBackendCommand("remove-dispatcher", $debug_flag);
}

sub disableMonitor {
	my $debug_flag = shift;
	sendBackendCommand("disable-monitor", $debug_flag);
}

sub enableMonitor {
	my $debug_flag = shift;
	sendBackendCommand("enable-monitor", $debug_flag);
}

sub undoCrippling {
	my $debug_flag = shift;
	sendBackendCommand("undo-crippling", $debug_flag);
}

sub forceRefresh {
	my $debug_flag = shift;
	sendBackendCommand("force-refresh", $debug_flag);
}


################            Backend Queries             ################

sub getApiStatus {
	my $response = sendBackendQuery("get-api-status");

	# was response "say what?" for wrong command
	if ($response =~ /say/i) {
		print "\nError: backend did not understand query \"get-api-status\" \n";
		return NET_UNKNOWN;
	}
	# if not numeric
	unless ($response =~ /^\d+$/ ) {
		print "\nError: backend query \"get-api-status\" gave non-numeric response \"$response\" \n";
		return NET_UNKNOWN;
	} 
	return $response;
}


sub getNetStatus {
	my $response = sendBackendQuery("get-net-status");

	# was response "say what?" for wrong command
	if ($response =~ /say/i) {
		print "\nError: backend did not understand query \"get-net-status\" \n";
		return NET_UNKNOWN;
	}
	# if not numeric
	unless ($response =~ /^\d+$/ ) {
		print "\nError: backend query \"get-net-status\" gave non-numeric response \"$response\" \n";
		return NET_UNKNOWN;
	} 
	return $response;
}


sub getCripplingStatus {
	my $debug_flag = shift;

	my $response = sendBackendQuery("check-crippling");
	if ($response) {
		if ( defined($debug_flag) && $debug_flag > 0 ) {
 			print "\nDebug: check-crippling returned test result \"$response\" \n";
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
			print "\nError: monitor-state returned invalid result \"$response\" \n";
		}
		# if monitor is offline or unresponsive, mark all fields as unknown
		$response = "Unknown-unknown-UNKNOWN";
	}
	return $response;
}


sub removeRoute {
	my $response = sendBackendQuery("remove-route");
	if ($response =~ /not ok/) {
		print "\nError: could not remove bad route. Backend says: \"$response\"\n";
	}
	return $response;
}

sub writeDispatcher {
	my $response = sendBackendQuery("write-dispatcher");
	if ($response =~ /not ok/) {
		print "\nError: could not write dispatcher file. Backend says: \"$response\"\n";
	}
	return $response;
}

sub rereadConfig {
	sendBackendQuery("reread-config");
}

1;
