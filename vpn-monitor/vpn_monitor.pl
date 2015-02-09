#!/usr/bin/perl
#
# PrivateOn-VPN -- Because privacy matters.
#
# Author: Mikko Rautiainen <info@tietosuojakone.fi>
#
# Copyright (C) 2014-2015  PrivateOn / Tietosuojakone Oy, Helsinki, Finland
# All rights reserved. Use is subject to license terms.
#

#
#		/opt/PrivateOn-VPN/vpn-monitor/vpn_monitor.pl
#
#   This daemon verifies that a VPN connection is active and functioning.
#   If the vpn is inactive, the last used VPN connection is retried. 
#   If this fails, the network is crippled until the vpn connection is 
#   refreshed or turned off from the vpn-gui front-end.
#
#  Note: The vpn-gui requires that this daemon is running.
#


use strict;
use warnings;
use sigtrap qw(die normal-signals); 

use lib '/opt/PrivateOn-VPN/vpn-monitor/';
use Fcntl qw(:flock);
use File::Path qw(make_path);
use File::stat;
use IO::Interface::Simple;
use JSON qw(decode_json);
use JSON::backportPP;
use No::Worries::PidFile qw(pf_check pf_set pf_unset);
use Try::Tiny;
use UI::Dialog::Backend::KDialog;

use AnyEvent::Impl::POE;
use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket;
use AnyEvent::Log;
use AnyEvent::Fork;
use AnyEvent::Fork::RPC;
use AnyEvent::HTTP;
use POE;

use constant {
	PATH          => "/opt/PrivateOn-VPN/",
	STATUS_FILE   => "/var/run/PrivateOn/.status",
	LOCK_FILE     => "/var/run/PrivateOn/.lock",
	PID_FILE      => "/var/run/PrivateOn/vpn-monitor.pid",
	LOG_FILE      => "/var/log/PrivateOn.log",
	DISPATCH_FILE => "/etc/NetworkManager/dispatcher.d/vpn-up",
	INI_FILE      => "/opt/PrivateOn-VPN/vpn-default.ini",
	VERSION       => "0.9",
	DEBUG         => 2
};

use constant {
	NET_UNPROTECTED	=> 0,
	NET_PROTECTED	=> 1,
	NET_OFFLINE     => 2,
	NET_CRIPPLED	=> 3,
	NET_BROKEN	=> 4,
	NET_UNCONFIRMED => 5,
	NET_ERROR	=> 99,
	NET_UNKNOWN	=> 100
};

use constant {
	IPC_HOST	=> '127.0.0.1',
	IPC_PORT	=> 44244
};

use constant {
	API_CHECK_INTERVAL => 5,
	API_WAIT_TIMEOUT   => 0.5,
	API_CHECK_TIMEOUT  => 5,
};

################	  Package-Wide Globals		################

my $Monitor_Enabled;            # monitor state (set in run_once())
my $Temporary_Disable = 0;      # used to temporarily disable crippling
my $Current_Task = "idle";      # stores the current forked task, idle if no task
my $Current_Status = 999;       # used to cache network status for get_monitor_state responses
my $Current_Update_Time = 0;    # used to store epoch time of last network status update for cache aging
my $Previous_Status = 999;      # used to store status result of previous iteration for detecting change 
my $Skip_Cleanup = 0;           # used to prevent cleanup when process aborted due to other instance running
my $Url_For_Api_Check;          # URL for checking VPN-provider's VPN status API (set in run_once())

my $cv = AnyEvent->condvar;     # Event loop object
my $ctx;                        # global AE logging context object
my $Detect_Change_Timer;        # Timer for periodic network status check
my $Api_Check_Timer;            # Timer for periodic API status check
my $Lockfile_Handle;            # Keep exclusive lock alive until process exits
my $Temporary_Disable_Timer;    # Timer for re-enabling monitor after GUI tasks
my $TCP_Server_Handle;          # TCP server handle
my %TCP_Server_Connections;     # Keep TCP server alive after initialization


################	Network State subroutines	################

sub http_req_async
{
	my $url = shift;
	$Current_Status = NET_UNCONFIRMED;
	$Current_Update_Time = time();
	update_status_file($Current_Status);
	http_get $url, timeout => API_CHECK_TIMEOUT, sub {
		my ($data, $headers) = @_;
		return NET_CRIPPLED if $data =~ /<meta name="flag" content="1"\/>/g;
		my $reply = decode_json($data);
		my $status = $reply->{'status'};
		if ($status eq 'Unprotected') { 
			$Current_Status = NET_UNPROTECTED; 
		}
		elsif ($status eq 'Protected') { 
			$Current_Status = NET_PROTECTED; 
		}
		else {
			$Current_Status = NET_UNKNOWN;
		}
		$Current_Update_Time = time();
		update_status_file($Current_Status);
	};

	# We will wait for API_WAIT_TIMEOUT seconds so that if everything is allright,
	# some defined status is returned. If API does not reply in API_WAIT_TIMEOUT
	# this function will return NET_UNCONFIRMED.

	select undef, undef, undef, API_WAIT_TIMEOUT;
	return $Current_Status;
}

sub tun_interface_exists
{
	my $sys_virtual_path = "/sys/devices/virtual/net/";
	my $net;
	my $exists = 0;
	unless (opendir $net, $sys_virtual_path) {
		$ctx->log(error => "Could not open directory: " . $sys_virtual_path . " Reason: " . $!);
		return undef;
	}
	while (my $file = readdir($net)) {
		if ($file =~ /^tun[0-9]+/) {
			$exists = 1;
			last;
		}
	}
	closedir $net;
	return $exists;
}

sub get_api_status 
# supposed to be called only from AnyEvent timer event
{
	# return NET_CRIPPLED if default route is interface lo or 127.0.0.1
	unless (open ROUTE, '<', '/proc/net/route') {
		$ctx->log(error => "Could not open /proc/net/route for reading.  Reason: " . $!);
		$Current_Status = NET_BROKEN;
		$Current_Update_Time = time();
		update_status_file($Current_Status);
		return NET_BROKEN;
	}
	while (<ROUTE>) {
		if ( (/^lo\s+00000000\s+/) || (/^\S+\s+00000000\s+0100007F\s+/i) ) {
			close ROUTE;
			$Current_Status = NET_CRIPPLED;
			$Current_Update_Time = time();
			update_status_file($Current_Status);
			return NET_CRIPPLED;
		}
	}
	close ROUTE;

	if (tun_interface_exists() && $Url_For_Api_Check ne 'none') {
		my $status = http_req_async($Url_For_Api_Check); # it will set $Current_Status
		return $status;
	}

	$Current_Status = quick_net_status();
	$Current_Update_Time = time();
	return $Current_Status;
}

sub quick_net_status
{
	my $net_status = NET_UNKNOWN;

	# return NET_CRIPPLED if default route is interface lo or 127.0.0.1
	unless (open ROUTE, '<', '/proc/net/route') {
		$ctx->log(error => "Could not open /proc/net/route for reading.  Reason: " . $!);
		return NET_BROKEN;
	}
	while (<ROUTE>) {
		if ( (/^lo\s+00000000\s+/) || (/^\S+\s+00000000\s+0100007F\s+/i) ) {
			close ROUTE;
			return NET_CRIPPLED;
		}
	}
	close ROUTE;

	my $tun_interface_exists = tun_interface_exists();
	unless (defined $tun_interface_exists) {
		return NET_BROKEN;
	}
	if ($tun_interface_exists) {
		if ($Current_Status == NET_UNCONFIRMED) {
			return NET_UNCONFIRMED;
		}
		return NET_PROTECTED;
	}

	my $sys_net_path = "/sys/class/net/";
	my $net;
	my @interface_array;

	unless (opendir $net, $sys_net_path) {
		$ctx->log(error => "Could not open directory: " . $sys_net_path . " Reason: " . $!);
		return NET_BROKEN;
	}
	while (my $file = readdir($net)) {
		next unless (-d $sys_net_path.$file);
		# skip loopback interface
		next if ($file eq "lo");
		# directory is read in reverse order, so push to beginning of array
		unshift(@interface_array, $file);
	}
	closedir $net;

	foreach my $interface (@interface_array) {
		# skip interfaces that do not have a hardware address
		next unless (-e $sys_net_path.$interface."/address");
		open my $address, $sys_net_path.$interface."/address";
		my @lines = <$address>;
		close $address;
		next if ($lines[0] =~ /00\:00\:00\:00\:00\:00/);
		next unless ($lines[0]);

		next unless (-e $sys_net_path.$interface."/operstate");
		open my $operstate, $sys_net_path.$interface."/operstate";
		my @line = <$operstate>;
		close $operstate;
		next if ($line[0] =~ /^unknown/);
		if ($line[0] =~ /^down/) {
			$net_status = NET_OFFLINE;
			next;
		} elsif ($line[0] =~ /^up/) {
			# check that the interface has an IP address
			my $if = IO::Interface::Simple->new($interface);
			if ( defined($if) && defined($if->address) ) {
				if ( $if->address =~ /\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/ ) {
					return NET_UNPROTECTED;
				}
			}
			# otherwise this interface is offline
			$net_status = NET_OFFLINE;
		}
	}
	return $net_status;
}


sub reversed_hex_to_octet
{
	my $hex = shift;
	my $octet = join('.', reverse map { hex($_); } ($hex =~ /([0-9a-f]{2})/gi));
	return $octet;
}


sub octet_to_reversed_hex
{
	my $octet = shift;
	my @octet = reverse split /\./, $octet;
	return sprintf '%02X%02X%02X%02X', @octet;
}


sub get_local_gateway_and_nic
{
	unless (open ROUTE, '<', '/proc/net/route') {
		$ctx->log(error => "Could not open /proc/net/route for reading.  Reason: " . $!);
		return (undef, undef);
	}
	chomp(my $firstline = <ROUTE>);
	my @headers = split /\s+/, $firstline;

	my $found_nic;
	my $found_hex;
	while (<ROUTE>) {
		chomp;
		next if /^\s*$/;
		my @values = split /\s+/, $_;
		my %line;
		@line{@headers} = @values;

		# if interface is not tun*/lo and entry has Gateway route flag 
		if ( ($line{Iface} !~ /^(tun\d|lo)$/) && (hex($line{Flags}) & 2) ) {
			$found_nic = $line{Iface};
			$found_hex = $line{Gateway};
			# end search if entry has Host route flag or entry is default route
			last if (hex($line{Flags}) & 4);
			last if ($line{Destination} eq '00000000');
			
		}
	}
	close ROUTE;

	if (!defined $found_nic || !defined $found_hex) {
		$ctx->log(error => "Could not find local gateway IP");
		return (undef, undef);
	}
	
	my $ip = reversed_hex_to_octet($found_hex);
	$ctx->log(debug => "Found local gateway IP: $ip on interface $found_nic") if DEBUG > 1;
	return ($ip, $found_nic);
}


sub get_monitor_state
{
	my $output;

	# monitor part values = Enabled/Disabled
	if ($Monitor_Enabled) {
		$output = "Enabled-";
	} else {
		$output = "Disabled-";
	}

	# task part values = crippled/uncrippling/retrying/temporary/idle
	if ($Temporary_Disable) {
		$output = "Disabled-temporary";
	} else {
		$output .= $Current_Task;
	}

	# refresh network status if cached data is over 20 seconds old
	if ( time() - $Current_Update_Time > 20 ) {
		$Current_Status = quick_net_status();
		$Current_Update_Time = time();
	}

	# network part values = UNPROTECTED/PROTECTED/BROKEN/CRIPPLED/ERROR/UNKNOWN
	$output .= "-" . get_status_text($Current_Status);

	return $output
}


sub get_status_text
{
	my $status = shift;

	if ($status == NET_UNPROTECTED) { return "UNPROTECTED"; }
	elsif ($status == NET_PROTECTED) { return "PROTECTED"; }
	elsif ($status == NET_OFFLINE) { return "OFFLINE"; }
	elsif ($status == NET_CRIPPLED) { return "CRIPPLED"; }
	elsif ($status == NET_BROKEN) { return "BROKEN"; }
	elsif ($status == NET_ERROR) { return "ERROR"; }

	return "UNKNOWN";
}


sub log_net_status
{
	# for debug purposes
	my $status = shift;
	popup_dialog($status) if (DEBUG > 2);
	$ctx->log(debug => "Network status is " . get_status_text($status) );
}


################	    Helper subroutines		################

sub get_lock
{
	unless (open $Lockfile_Handle, ">>", LOCK_FILE) {
		$Skip_Cleanup = 1;
		$ctx->log(error => "Process " . $$ . " could not open lockfile " . LOCK_FILE . ": " . $!);
		$ctx->log(error => "$0 is already running. Exiting process " . $$ . ".");
		die "$0 is already running. Exiting.\n";
	}
	unless ( flock($Lockfile_Handle, LOCK_EX|LOCK_NB) ) {
		$Skip_Cleanup = 1;
		$ctx->log(error => "Process " . $$ . " could not open exclusive lock: " . $!);
		$ctx->log(error => "$0 is already running. Exiting process " . $$ . ".");
		die "$0 is already running. Exiting.\n";
	}

	return 1;
}


sub update_status_file
{
	my $status = shift;

	open my $sf, ">", STATUS_FILE or return;
	print $sf $status;
	close $sf;
}


sub get_previous_status_from_file
{
	unless (-e STATUS_FILE) {
		update_status_file(NET_UNPROTECTED);
		return NET_UNPROTECTED;
	}
	open my $sf, "<", STATUS_FILE or return 1;
	my @lines = <$sf>;
	close $sf;
	return $lines[0];
}


sub set_current_task_to_idle
{
	# restore task to "temporary" if Temporary_Disable_Timer still running
	if ($Temporary_Disable) {
		$Current_Task = "temporary";
	} else {
		$Current_Task = "idle";
	}
	return;
}


sub write_dispatcher 
{
	my $uuid;
	my $vpn_ini;
	unless (open $vpn_ini, "<" . INI_FILE) {
		$ctx->log(error => "Could not open " . INI_FILE . " for reading.  Reason: " . $!);
		return 1;
	}
	while (<$vpn_ini>) {
		if (/uuid=(.+)/) {
			$uuid = $1;
			last;
		}
	}
	close $vpn_ini;

	# write dispatcher file with "up|vpn-down" case
	my $dfh;
	unless (open $dfh, ">", DISPATCH_FILE) {
		$ctx->log(error => "Could not open " . DISPATCH_FILE . " for writing.  Reason: " . $!);
		return 2;
	}
	print $dfh "#!/bin/sh\n";
	print $dfh "ESSID=\"$uuid\"\n\n";
	print $dfh "interface=\$1 status=\$2\n";
	print $dfh "case \$status in\n";
	print $dfh "  up|vpn-down)\n";
	print $dfh "	sleep 3 && /usr/bin/nmcli con up uuid \"\$ESSID\" &\n";
	print $dfh "	;;\n";
	print $dfh "esac\n";
	close $dfh;
	$ctx->log(debug => "Dispatch file written") if DEBUG > 0;

	return 0;
}


sub read_api_url_from_inifile
{
	my $vpn_ini;
	unless (open $vpn_ini, "<" . INI_FILE) {
		$ctx->log(error => "Could not open " . INI_FILE . " for reading.  Reason: " . $!);
		$ctx->log(debug => "   Disabling API check.");
		$Url_For_Api_Check = 'none';
		return 2;
	}

	my $url = 'none';
	# read the first 'url' entry in the inifile
	while (<$vpn_ini>) {
		if (/^\s*url\s*=\s*(.*)\s*$/) {
		$url = $1;
		$ctx->log(debug => "Found URL $url") if DEBUG > 0;
		last;
		}
	}
	close $vpn_ini;
	
	if (not defined($url)) {
		$ctx->log(error => "Unexpected error while reading " . INI_FILE . ".  Reason: " . $!);
		$ctx->log(debug => "   Disabling API check.");
		$Url_For_Api_Check = 'none';
		return 2;
	} elsif ($url eq 'none') {
		$ctx->log(debug => "No URL entry found in " . INI_FILE) if DEBUG > 0;
		$ctx->log(debug => "   Disabling API check.") if DEBUG > 0;
		$Url_For_Api_Check = 'none';
		return 1;
	} elsif ($url eq '') {
		$ctx->log(debug => "URL entry empty in " . INI_FILE) if DEBUG > 0;
		$ctx->log(debug => "   Disabling API check.") if DEBUG > 0;
		$Url_For_Api_Check = 'none';
		return 1;
	} elsif ($url =~ /http\:.*/) {
		$ctx->log(debug => "Using API check URL $url") if DEBUG > 0;
		$Url_For_Api_Check = $url;
		return 0;
	} else {
		$ctx->log(error => "Error addind API check URL $url");
		$ctx->log(error => "   URL must start with \"http:\"   Disabling API check.");
		$Url_For_Api_Check = 'none';
		return 2;
	}
	return 2;
}


sub popup_dialog
{
	my $status_to_display = shift;
	my $msg;

	$ctx->log(debug => "Should display popup right about now ($status_to_display vs $Previous_Status)") if DEBUG > 1;
	if ($status_to_display == NET_UNPROTECTED) {
		$msg = 'VPN connection is DOWN';
	} elsif ($status_to_display == NET_PROTECTED) {
		$msg = 'VPN connection is UP!';
	} elsif ($status_to_display == NET_OFFLINE) {
		$msg = 'Network is OFFLINE';
	} elsif ($status_to_display == NET_CRIPPLED) {
		$msg = 'Unable to start VPN. Network put into safe mode';
	} elsif ($status_to_display == NET_BROKEN) {
		$msg = 'Network is BROKEN';
	} elsif ($status_to_display == NET_UNCONFIRMED) {
		$msg = 'VPN connection status is UNCONFIRMED';
	} else {
		$msg = 'Network is in an unknown status (' . $status_to_display . ')';
	}
	$ctx->log(debug => "Popup: " . $msg ) if DEBUG > 0;

	try {
		# find user with terminal :0
		my ($line, $username);
		open(WHO, "who -s |");
		while ($line = <WHO>) {
			if ($line =~ /^(\S+)\s+:0\s+.*/) {
				$username = $1;
				last;
			}
		}
		close(WHO);
		# if who parse fails, use username with ID 1000
		if (not defined($username)) {
			$username = getpwuid(1000);
			$ctx->log(debug => "Who parse failed. using user ($username) ID 1000." ) if DEBUG > 0;
		}

		# check is xhost already allows non-network local connections 
		my $remove_access = 0;
		if (system("su -l " . $username . " -c \"DISPLAY=:0 xhost \" | grep -i LOCAL >/dev/null")) {
			# add non-network local connections to X display access control list
			system("su -l " . $username . " -c \"DISPLAY=:0 xhost +local:\" >/dev/null");
			$remove_access = 1;
			$ctx->log(debug => "Non-network local connections added to X display access control list" ) if DEBUG > 0;
		}

		my $cmd=("kdialog --display :0 --title \"PrivateOn-VPN\" --passivepopup \"" . $msg . "\" 120 &");
		$ctx->log(debug => '<' . $cmd . '>') if DEBUG > 1;
		system($cmd);

		# undo xhost exception
		if ($remove_access) {
			system("su -l " . $username . " -c \"DISPLAY=:0 xhost -local:\" >/dev/null");
			$ctx->log(debug => "Non-network local connections removed from X display access control list" ) if DEBUG > 0;
		}
	} catch {
		$ctx->log(error => "Popup routine failed. Cause = $_" );
	};

	return;
}


sub fake_systemv_logger
{
	# do nothing if logger program already running
	if (`ps -ef | grep journalctl | grep -v grep | grep NetworkManager | wc -l` > 0) {
		return 0;
	}

	# check if system has systemd journal logging
	if ( system('pidof systemd-journald >/dev/null 2>&1') eq 0 ) {
		$ctx->log(debug => "Starting vpn_logger.sh background process" ) if DEBUG > 0;
		system( PATH . "vpn-monitor/vpn_logger.sh &");
		return 0;
	}

	return 1;
}


sub stop_systemv_logger
{
	# do nothing if system doesn't have systemd journal logging
	if ( system('pidof systemd-journald >/dev/null 2>&1') eq 0 ) {
		return 0;
	}

	$ctx->log(debug => "Stopping vpn_logger.sh background process" ) if DEBUG > 0;

	if (`ps -ef | grep vpn_logger.sh | grep -v grep | wc -l` > 0) {
		system("/bin/pkill -9 vpn_logger.sh &");
	}

	my @pid;
	@pid = `ps -ef | grep journalctl | grep -v grep | grep NetworkManager | awk '{print \$2}'`;
	kill 'KILL', @pid;

	# remove file since it is not updated anymore
	system( "/usr/bin/rm -f /var/log/NetworkManager");
}


################	   Cripple subroutines		################

sub add_route_to_vpn_server
{
	# get local gateway and active NIC before removing routes 
	my ($local_gateway_ip, $active_nic) = get_local_gateway_and_nic();
	unless ( defined $local_gateway_ip && defined $active_nic ) { return 1; };

	# read vpn server ip
	my $vpn_server_ip;
	my $vpn_ini;
	if (open $vpn_ini, "<" . INI_FILE) {
		while (<$vpn_ini>) {
			if (/^\s*remote\s*=\s*([1-9][0-9]*\.[1-9][0-9]*\.[1-9][0-9]*\.[1-9][0-9]*)\s*$/) {
				$vpn_server_ip = $1;
				last;
			}
		}
		close $vpn_ini;
	} else {
		$ctx->log(error => "Could not open " . INI_FILE . " for reading.  Reason: " . $!);
		return 1;
	}
	unless ( defined $vpn_server_ip) { return 1; };

	# remove old routes to vpn server
	my $status = 0;
	my $iteration = 0; # prevent deadlock in case of route error
	while ( !$status && $iteration < 5 ) {
		system("/sbin/route del " . $vpn_server_ip . " 2>/dev/null");
		$status = $? >> 8; # $? >> 8 is the exit status, see perldoc -f system
		$iteration++;
	}

	# add route to vpn server so we can retry the vpn without leaving crippled state 
	system("/sbin/route add " . $vpn_server_ip . " gw " . $local_gateway_ip . " dev " . $active_nic . " 2>/dev/null");
	$status = $? >> 8; # $? >> 8 is the exit status, see perldoc -f system
	if ($status) {
		$ctx->log(error => "Failed to add route, error($status): dest=$vpn_server_ip gw=$local_gateway_ip dev=$active_nic" );
	}

	return $status;
}


sub redirect_page
{
	# redirect web traffic to a static page
	$ctx->log(warn => "Redirecting all web traffic to warning page" );

	add_route_to_vpn_server();
	
	# delete all default routes
	my $status = 0;
	my $iteration = 0; # prevent deadlock in case of route error
	while ( !$status && $iteration < 5 ) {
		system("/sbin/route del default 2>/dev/null");
		$status = $? >> 8; # $? >> 8 is the exit status, see perldoc -f system
		$iteration++;
	}

	# set default route to localhost
	system("/sbin/route add default gw 127.0.0.1 lo");
	$status = $? >> 8;

	# if the command above succeeded then...
	if (!$status) {
		# start dnsmasq
		system("dnsmasq --address=/#/127.0.0.1 --listen-address=127.0.0.1 --bind-interfaces");

		system("/usr/bin/cp /etc/resolv.conf /etc/resolv.conf.bak");
		# overwrite resolv.conf
		if (open my $fh, ">", "/etc/resolv.conf") {
			print $fh "nameserver 127.0.0.1";
			close $fh;
		} else {
			$ctx->log(error => "Could not open /etc/resolv.conf for writing.  Reason: " . $!);
		}

		# start web server that listens to localhost
		system("thttpd -r -h localhost -d " . PATH . "vpn-monitor/htdocs");
	} else {
		return $status;
	}

	$Current_Task = "crippled";
	$ctx->log(debug => "redirect_page successfull" ) if DEBUG > 0;
}


################	    Undo Crippling fork		################

sub spawn_undo_crippling
{
	$Current_Task = "uncrippling";
	$ctx->log(info => "Undoing all network crippling" );
	$ctx->log(debug => "Spawning undo_crippling") if DEBUG > 0;

	# kill previous instance or vpn_retry if still running
	system("/bin/pkill -9 vpn_uncripple");
	system("/bin/pkill -9 vpn_retry");

	# vpn_uncripple requires a NetworkManager log file
	fake_systemv_logger();

	my $rpc = AnyEvent::Fork
		->new     
		->require ("AnyEvent::Fork::RPC::Async","vpn_uncripple")
		->AnyEvent::Fork::RPC::run ("vpn_uncripple::run",
			async      => 1,
			on_error   =>  \&undo_crippling_on_error,
			on_event   => sub { 
					$ctx->log(debug => "undo_crippling sent event $_[0]") if DEBUG > 0; 
				},
			on_destroy => sub { 
					$ctx->log(debug => "undo_crippling child process destoyed") if DEBUG > 0; 
				},
		);

	$rpc->( \&undo_crippling_callback);
}


sub undo_crippling_callback
{
	set_current_task_to_idle();
	$Current_Status = quick_net_status();
	$Current_Update_Time = time();
	update_status_file($Current_Status);
	popup_dialog($Current_Status);
	return 0;
}


sub undo_crippling_on_error
{
	set_current_task_to_idle();
	my $msg = shift;
	$ctx->log( error => "undo_crippling child process died unexpectedly: " . $msg );
	$Current_Status = quick_net_status();
	$Current_Update_Time = time();
	if ($Current_Status == NET_PROTECTED || $Current_Status == NET_UNPROTECTED || $Current_Status == NET_UNCONFIRMED) {
		return 0;
	} else {
		system("/usr/bin/rm -f /etc/resolv.conf");
		system("/sbin/rcnetwork restart");
	}
	return 0;
}


sub check_crippled
{
	# Returns true if crippling is on

	# Process check
	my $pslist = qx!/usr/bin/ps -aef!;
	my @pslist = split("\n", $pslist);
	my $line;
	my $thttpd_pid  = undef;
	my $dnsmasq_pid = undef;
	while ( defined($line = shift(@pslist))) {
		if ($line =~ /^[^\d]+\s*(\d+).*thttpd/) {
			$thttpd_pid = $1;
		} elsif ($line =~ /^[^\d]+\s*(\d+).*dnsmasq/) {
			$dnsmasq_pid = $1;
		}
	}
	return $thttpd_pid  if (defined($thttpd_pid ));
	return $dnsmasq_pid if (defined($dnsmasq_pid));

	# Route check
	unless (open ROUTE, '<', '/proc/net/route') {
		$ctx->log(error => "Could not open /proc/net/route for reading.  Reason: " . $!);
	}
	while (<ROUTE>) {
		if ( (/^lo\s+00000000\s+/) || (/^\S+\s+00000000\s+0100007F\s+/i) ) {
			close ROUTE;
			return "Default route";
		}
	}
	close ROUTE;

	# Nameserver check
	my $nameservers = qx!/usr/bin/grep nameserver /etc/resolv.conf!;
	my @nameservers = split("\n", $nameservers);
	my @resolvers = ();
	my $resolver;
	while (defined($line = shift(@nameservers))) {
		if ($line =~ /^nameserver\s*(\d+\.\d+\.\d+\.\d+)/) {
			$resolver = $1;
			push @resolvers, $resolver;
			return "Localhost as DNS" if $resolver eq '127.0.0.1';
		}
	}
	
	# if not crippled, change task to idle or temporary
	if ( $Current_Task eq "crippled" || $Current_Task eq "uncripling" ) { 
		set_current_task_to_idle();
	}

	return 0;
}


################	     VPN Retry fork		################

sub spawn_retry_vpn
{
	$Current_Task = "retrying";
	$ctx->log(debug => "Spawning retry_vpn") if DEBUG > 0;

	# kill previous instance if still running
	system("/bin/pkill -9 vpn_retry");

	# vpn_retry requires a NetworkManager log file
	fake_systemv_logger();

	my $rpc = AnyEvent::Fork
		->new     
		->require ("AnyEvent::Fork::RPC::Async","vpn_retry")
		->AnyEvent::Fork::RPC::run ("vpn_retry::run",
			async      => 1,
			on_error   =>  \&retry_vpn_on_error,
			on_event   => sub { 
					$ctx->log(debug => "Retry_vpn sent event $_[0]") if DEBUG > 0; 
				},
			on_destroy => sub { 
					$ctx->log(debug => "Retry_vpn child process destoyed") if DEBUG > 0; 
				},
		);

	$rpc->( \&retry_vpn_callback);
}


sub retry_vpn_callback
{
	set_current_task_to_idle();
	if (quick_net_status() == NET_UNPROTECTED) {
		redirect_page();
		update_status_file(NET_CRIPPLED);
		popup_dialog(NET_CRIPPLED);
	}
	return 0;
}


sub retry_vpn_on_error
{
	set_current_task_to_idle();
	my $msg = shift;
	$ctx->log( error => "Retry_vpn child process died unexpectedly: " . $msg );
	$Current_Status = quick_net_status();
	$Current_Update_Time = time();
	if ($Current_Status == NET_PROTECTED || $Current_Status == NET_UNCONFIRMED) {
		return 0;
	} elsif ($Current_Status == NET_UNPROTECTED) {
		redirect_page();
		update_status_file(NET_CRIPPLED);
		popup_dialog(NET_CRIPPLED);
	} else {
		system("/usr/bin/rm -f /etc/resolv.conf");
		system("/sbin/rcnetwork restart");
	}
	return 0;
}


################     Detect Change in Network State	################

sub detect_change
{
	if ( not defined($Monitor_Enabled) or $Monitor_Enabled == 0 or $Temporary_Disable == 1) {
		return;
	}

	$ctx->log(debug => "Refreshing network status") if DEBUG > 0;

	$Current_Status = quick_net_status();
	$Current_Update_Time = time();
	log_net_status($Current_Status) if DEBUG > 0;
	$ctx->log(debug => "\tprevious_status = " . get_status_text($Previous_Status) . " current_status = " . get_status_text($Current_Status) ) if DEBUG > 1;

	my $tmp_previous = $Previous_Status;
	$Previous_Status = $Current_Status;

	# do not retry/redirect if previous state was CRIPPLED, redirect on next iteration
	if ($Current_Status == NET_UNPROTECTED and $tmp_previous != NET_CRIPPLED) {
		# spawn_retry_vpn calls retry_vpn_callback when it finishes
		spawn_retry_vpn();
		return(0);
	}

	# update Current_Task in case callbacks failed to be called
	if ($Current_Task ne "idle") {
		if ($Current_Task eq "uncrippling" && $Current_Status != NET_CRIPPLED) { 
			unless ( check_crippled() ) { $Current_Task = "idle"; };
		} elsif ($Current_Task eq "retrying") {
			if (`ps -ef | grep vpn_retry | grep -v grep | grep root | wc -l` == 0) { $Current_Task = "idle"; };
		}
	}

	if ($Current_Status eq $tmp_previous) {
		return(0);
	} else {
		$ctx->log(warn => "State changed from " . get_status_text($tmp_previous) . " to " . get_status_text($Current_Status) );
		popup_dialog($Current_Status);
		return(999) if ($tmp_previous == 999);
		return(1) if ($Current_Status == NET_ERROR);
		return(1) if ($Current_Status == NET_BROKEN);
		update_status_file($Current_Status);
	}
}


################	  Initialize subroutine		################

sub run_once
{
	system("/usr/bin/mkdir -p /var/run/PrivateOn");

	$ctx = new AnyEvent::Log::Ctx;
	$ctx->log_to_file(LOG_FILE);
	$ctx->log(info => "PrivateOn VPN-monitor daemon ".VERSION." starting up.");

	# make sure there is only one instance running
	return unless get_lock();

	# write pid if stale or missing
	if ( -e PID_FILE ) {
		# pf_check returns empty string if pid is OK
		my $action = 0;
		eval { $action = pf_check( PID_FILE ); };
		$ctx->log(debug => "PID check: " . $@) if ($@ && DEBUG > 1);
		if (length $action) {
			$ctx->log( info => "Removing stale PID file " . PID_FILE );
			system( "/usr/bin/rm -f " . PID_FILE );
			pf_set( PID_FILE );
		}
	} else {
		pf_set( PID_FILE );
	}

	if ( !-e STATUS_FILE) {
		my $vpn_ini;
		unless (open $vpn_ini, "<" . INI_FILE) {
			$ctx->log(error => "Could not open " . INI_FILE . " for reading.  Reason: " . $!);
			if (defined $ARGV[0]) { spawn_undo_crippling(); };
			return -1;
		}
		my @vpn_ini_lines = <$vpn_ini>;
		close $vpn_ini;

		unless (open VPN_INI, ">" . INI_FILE) {
			$ctx->log(error => "Could not open " . INI_FILE . " for writing.  Reason: " . $!);
			if (defined $ARGV[0]) { spawn_undo_crippling(); };
			return -1;
		}
		my $has_been_written = 0;
		foreach my $line (@vpn_ini_lines) {
			if ($line =~ /monitor/) {
				print VPN_INI "monitor=enabled\n";
				$has_been_written = 1;
			} else {
				print VPN_INI $line;
			}
		}
		if ($has_been_written == 0) {
			print VPN_INI "monitor=enabled\n";
		}
		close VPN_INI;

		# write uuid from INI file to dispatcher file
		write_dispatcher();

	} else { # status file exists
		# assign variable from file
		$Previous_Status = get_previous_status_from_file();

		my $vpn_ini;
		unless (open $vpn_ini, "<" . INI_FILE) {
			$ctx->log(error => "Could not open " . INI_FILE . " for reading.  Reason: " . $!);
			if (defined $ARGV[0]) { spawn_undo_crippling(); };
			return -1;
		}
		while (<$vpn_ini>) {
			if (/monitor=([a-zA-Z]+)/) {
				if ($1 =~ /disabled/) {
					$Monitor_Enabled = 0;
				} else { # any value other than "disabled" is "enabled"
					$Monitor_Enabled = 1;
				}
			}
		}
		close $vpn_ini;
	}

	# read API check URL from inifile to global variable
	read_api_url_from_inifile();

	# Start periodic network status checking
	$Detect_Change_Timer = AnyEvent->timer(
		after => 60, # run after 60 sec the first time
		interval => 60, # then every minute
		cb => \&detect_change,
	);

	# Start periodic API check status
	$Api_Check_Timer = AnyEvent->timer(
		after => 0,
		interval => API_CHECK_INTERVAL,
		cb => \&get_api_status,
	);

	if (defined $ARGV[0]) { spawn_undo_crippling(); };
}


# run initialization code
run_once();


################		TCP server		################

tcp_server(
	IPC_HOST, IPC_PORT, sub {
	my ($fh) = @_;

	$TCP_Server_Handle = AnyEvent::Handle->new(
		fh => $fh,
		poll => 'r',
		on_read => sub {
			my ($self) = @_;
			my $buf = $self->{rbuf};
			chomp($buf);
			$self->rbuf = ""; # clear buffer

			print "Received: " . $buf . "\n" if DEBUG > 2;

			if ($buf eq "force-refresh") {
				# force get_monitor_state to update Current_Status by time traveling to the age of disco
				$Current_Update_Time = 0;
				$self->push_write("refresh ok\n");

			} elsif ($buf eq "take-a-break") {
				$Temporary_Disable = 1; # disable crippling

				# kill vpn_retry instance if running
				system("/bin/pkill -9 vpn_retry");
				$Current_Task = "temporary";

				# destroy timer / re-enable crippling after 1 minute
				undef $Temporary_Disable_Timer; 
				$Temporary_Disable_Timer = AnyEvent->timer(
					after => 60, 
					cb => sub {
						$Temporary_Disable = 0;
						$Current_Task = "idle";
						$ctx->log(debug => "Temporary disable_crippling ended") if DEBUG > 0;
					},
				);
				$self->push_write("monitoring disabled for 1 minute\n");
				$ctx->log(debug => "Take-a-break requested, Temporary disable_crippling") if DEBUG > 0;

			} elsif ($buf eq "get-api-status") {
				# if, for any reason, the saved status is older than needed we'll re-request it
				if ($Current_Update_Time + API_CHECK_INTERVAL < time()) {
					$Current_Status = get_api_status();
					$Current_Update_Time = time();
				}
				$self->push_write($Current_Status . "\n");

			} elsif ($buf eq "get-net-status") {
				$self->push_write(quick_net_status() . "\n");

			} elsif ($buf eq "write-dispatcher") {
				if (write_dispatcher() == 0) {
					$self->push_write("ok - dispatch file written\n");
				} else {
					$self->push_write("not ok - see error log\n");
				}

			} elsif ($buf eq "remove-dispatcher") {
				unlink(DISPATCH_FILE);
				$self->push_write("ok - dispatch file unlinked\n");
				$ctx->log(debug => "Dispatch file unlinked") if DEBUG > 0;

			} elsif ($buf eq "check-crippling") {
				$self->push_write(check_crippled());

			} elsif ($buf eq "undo-crippling") {
				spawn_undo_crippling();
				$self->push_write("ok - called spawn_undo_crippling()\n");

			} elsif ($buf eq "enable-monitor") {
				# enable check
				$Temporary_Disable = 0;

				# kill vpn_retry instance if running
				system("/bin/pkill -9 vpn_retry");

				my $vpn_ini;
				unless (open $vpn_ini, "<" . INI_FILE) {
					$self->push_write("not ok - see error log\n");
					$ctx->log(error => "Could not open " . INI_FILE . " for reading.  Reason: " . $!);
					return;
				}
				my @vpn_ini_lines = <$vpn_ini>;
				close $vpn_ini;
				unless (open VPN_INI, ">" . INI_FILE) {
					$self->push_write("not ok - see error log\n");
					$ctx->log(error => "Could not open " . INI_FILE . " for writing.  Reason: " . $!);
					return;
				}

				# update ini
				my $has_been_written = 0;
				foreach my $line (@vpn_ini_lines) {
					if ($line =~ /monitor/) {
						print VPN_INI "monitor=enabled\n";
						$has_been_written = 1;
					} else {
						print VPN_INI $line;
					}
				}
				if ($has_been_written == 0) {
					print VPN_INI "monitor=enabled\n";
				}
				close VPN_INI;

				# restart timer
				undef $Detect_Change_Timer; # destroy current timer
				$Detect_Change_Timer = AnyEvent->timer(
					after => 40, # run after 40 sec the first time
					interval => 60, # every minute
					cb => \&detect_change,
				);
				$Monitor_Enabled = 1;
				$self->push_write("ok - monitor enabled\n");
				$ctx->log(debug => "Monitor enabled, first check after 40 seconds") if DEBUG > 0;

			} elsif ($buf eq "disable-monitor") {
				$Temporary_Disable = 0;
				$Monitor_Enabled = 0;

				# kill vpn_retry instance if running
				system("/bin/pkill -9 vpn_retry");

				update_status_file(999);
				my $vpn_ini;
				unless (open $vpn_ini, "<" . INI_FILE) {
					$self->push_write("not ok - see error log\n");
					$ctx->log(error => "Could not open " . INI_FILE . " for reading.  Reason: " . $!);
					return 0;
				}
				my @vpn_ini_lines = <$vpn_ini>;
				close $vpn_ini;
				unless (open VPN_INI, ">" . INI_FILE) {
					$self->push_write("not ok - see error log\n");
					$ctx->log(error => "Could not open " . INI_FILE . " for writing.  Reason: " . $!);
					return 0;
				}

				# update ini
				my $has_been_written = 0;
				foreach my $line (@vpn_ini_lines) {
					if ($line =~ /monitor/) {
						print VPN_INI "monitor=disabled\n";
						$has_been_written = 1;
					} else {
						print VPN_INI $line;
					}
				}
				if ($has_been_written == 0) {
					print VPN_INI "monitor=disabled\n";
				}
				close VPN_INI;
				$self->push_write("ok - monitor disabled\n");
				$ctx->log(debug => "Monitor disabled") if DEBUG > 0;

			} elsif ($buf eq "monitor-state") {
				$self->push_write(get_monitor_state() . "\n");

			} else {
				$self->push_write("say what?\n");
				$ctx->log(debug => "Unrecognized command: " . $buf) if DEBUG > 0;
			}
			$self->push_shutdown;
		},
		on_eof => sub {
			my ($hdl) = @_;
			$hdl->destroy();
		},
		on_error => sub {
			my ($hdl, $fatal, $msg) = @_;
			$ctx->log(error => "tcp_server error :" . $msg);
			$hdl->destroy;
		}
	);
	$TCP_Server_Connections{$TCP_Server_Handle} = $TCP_Server_Handle; # keep it alive.
	return;
	}
);

$ctx->log(info => "Daemon is listening on " . IPC_HOST . ":" . IPC_PORT);


################		Main Loop		################

$cv->recv;


################		Clean up		################

END {
	unless ($Skip_Cleanup) {
		$ctx->log(debug => "PrivateOn VPN-monitor daemon shutting down.") if DEBUG > 0;
		stop_systemv_logger();
		# remove pid file
		pf_unset( PID_FILE );
		$ctx->log(info => "PrivateOn VPN-monitor daemon stopped.");
		print("PrivateOn VPN-monitor daemon stopped.");		# print daemon stopped to systemd journal 
	}
}
