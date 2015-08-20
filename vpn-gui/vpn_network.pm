package vpn_network;

#
# PrivateOn-VPN -- Because privacy matters.
#
# Author: Mikko Rautiainen <info@tietosuojakone.fi>
#
# Copyright (C) 2014-2015  PrivateOn / Tietosuojakone Oy, Helsinki, Finland
# All rights reserved. Use is subject to license terms.
#


use strict;
use warnings;


sub import{
	no strict 'refs';
	foreach (@_) {
		*{"vpn_window::$_"}=\&$_;
	}
}


################           Helper subroutines           ################
sub getConnections {
	my $object = Net::DBus->system
	    ->get_service("org.freedesktop.NetworkManager")
	        ->get_object("/org/freedesktop/NetworkManager/Settings",
	            "org.freedesktop.NetworkManager.Settings");

	return $object->ListConnections();
}


################          Exported subroutines          ################
sub getVpnConnection {
	my ($connections) = getConnections();
	my @return_conns = ();

	foreach my $connection (@{$connections}) {
		my $object = Net::DBus->system
		    ->get_service("org.freedesktop.NetworkManager")
		        ->get_object($connection,
		            "org.freedesktop.NetworkManager.Settings.Connection");
		my $settings = $object->GetSettings();
		push(@return_conns, $settings) if ($settings->{connection}->{type} eq "vpn");
	}
	return \@return_conns;
}


sub isVpnActive {
	return </sys/devices/virtual/net/tun*> ? 1 : 0;
}


sub isNetworkManagerEnabled {
	my $response = `/usr/bin/nmcli --nocheck networking`;

	if ($response =~ /enabled/i) {
		return 1;
	} else {
		return 0;
	}
}


sub explainNetworkManagerProblem {
	my $status_text;

	# check NetworkManager process
	if (system("pgrep NetworkManager >/dev/null 2>&1")) {
		$status_text = "\nError: NetworkManager service is not running!\n";
		$status_text .= "Start service and restart this program.\n";
		return $status_text;
	}

	# check nmcli binary
	unless (-e '/usr/bin/nmcli') {
		$status_text = "\nError: \'nmcli\' command missing!\n";
		$status_text .= "Locate or install \'nmcli\' command and symlink to \'/usr/bin/nmcli\'\n";
		return $status_text;
	}

	my $response = `/usr/bin/nmcli --nocheck networking 2>&1`;
	
	unless ($response) {
		$status_text = "\nError: \'nmcli\' gave empty response!\n";
		$status_text .= "Check your NetworkManager installation and restart this program.\n";
		return $status_text;
	}

	chomp $response;
	$status_text = "\nError: Networking is not enabled!\n";
	$status_text .= "\'nmcli networking\' returned \"" . $response . "\"\n";
	return $status_text;
}


1;