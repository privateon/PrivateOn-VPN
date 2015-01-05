#!/usr/bin/perl
#
# PrivateOn-VPN -- Because privacy matters.
#
# Author: Mikko Rautiainen <info@tietosuojakone.fi>
#
# Copyright (C) 2014  PrivateOn / Tietosuojakone Oy, Helsinki, Finland
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

use lib '/opt/PrivateOn-VPN/vpn-monitor/';
use Fcntl qw(:flock);
use File::Path qw(make_path);
use File::stat;
use HTTP::Lite;
use IO::Interface::Simple;
use JSON qw(decode_json);
use JSON::backportPP;
use No::Worries::PidFile qw(pf_set pf_unset);
use Try::Tiny;
use UI::Dialog::Backend::KDialog;

use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket;
use AnyEvent::Log;
use AnyEvent::Fork;
use AnyEvent::Fork::RPC;

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
	NET_ERROR	=> 99,
	NET_UNKNOWN	=> 100
};

use constant {
	IPC_HOST	=> '127.0.0.1',
	IPC_PORT	=> 44244
};


################	  Package-Wide Globals		################

my $Monitor_Enabled;            # monitor state (set in run_once())
my $Temporary_Disable = 0;      # used to temporarily disable crippling
my $Current_Task = "idle";      # stores the current forked task, idle if no task
my $Current_Status = 999;       # used to cache network status for get_monitor_state responses
my $Current_Update_Time = 0;    # used to store epoch time of last network status update for cache aging
my $Previous_Status = 999;      # used to store status result of previous iteration for detecting change 
my $Url_For_Api_Check;          # URL for checking VPN-provider's VPN status API (set in run_once())

my $cv = AE::cv;                # Event loop object
my $ctx;                        # global AE logging context object


################	Network State subroutines	################

sub http_req
{
	my $url = shift;

	my $http = HTTP::Lite->new;
	my $req = $http->request($url) or return;

	return $http->body();
}


sub get_api_status
{
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

	my $reply;
	if ( $Url_For_Api_Check ne 'none') {
		try {
			my $json;
			if ( $json = http_req($Url_For_Api_Check) ) {
				return NET_CRIPPLED if $json =~ /<meta name="flag" content="1"\/>/g;
				$reply = decode_json($json);
			}
		} catch {
			undef $reply;
		};
	}

	unless (defined $reply or defined $reply->{'status'}) {
		return quick_net_status();
	}

	my $status = $reply->{'status'};
	if ($status eq 'Unprotected') { return NET_UNPROTECTED; }
	elsif ($status eq 'Protected') { return NET_PROTECTED; }

	return NET_UNKNOWN;
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

	my $sys_virtual_path = "/sys/devices/virtual/net/";
	my $sys_net_path = "/sys/class/net/";
	my $net;
	my @interface_array;

	unless (opendir $net, $sys_virtual_path) {
		$ctx->log(error => "Could not open directory: " . $sys_virtual_path . " Reason: " . $!);
		return NET_BROKEN;
	}
	while (my $file = readdir($net)) {
		return NET_PROTECTED if ($file =~ /^tun[0-9]+/);
	}
	closedir $net;

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
	my $lf;
	unless (open $lf, ">", LOCK_FILE) {
		my $error_msg = $!;
		$ctx->log(error => "Process " . $$ . " could not open lockfile " . LOCK_FILE . ": " . $error_msg);
		die "Cannot open file " . LOCK_FILE . ": " . $error_msg;
	}
	flock $lf, LOCK_EX | LOCK_NB or return 0;

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
	# restore task to "temporary" if take-a-break/timer2 still running
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
		$ctx->log(debug => "Using API check URL  $url") if DEBUG > 0;
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

sub redirect_page
{
	$ctx->log(warn => "Redirecting all web traffic to warning page" );
	# redirect the web page to a static page

	# make sure the file exists, set flag otherwise
	if (!(-e INI_FILE)) {
		print "File '" . INI_FILE . "' does not exist.\n";
		goto ROUTE_DEL;
	}

	# make sure the file is regular (i.e not a dir, fifo,
	# device file, etc) and is readable, set flag otherwise.
	if (!(-f INI_FILE) || !(-r INI_FILE)) {
		print "File '" . INI_FILE . "' is not regular or is not readable.\n";
		goto ROUTE_DEL;
	}

	my $MY_IP;

	# read the first 'remote' entry in the file
	open my $fh, "<", INI_FILE or goto ROUTE_DEL;
	while (<$fh>) {
		if (/^\s*remote\s*=\s*([1-9][0-9]*\.[1-9][0-9]*\.[1-9][0-9]*\.[1-9][0-9]*)\s*$/) {
		$MY_IP = $1;
		last;
		}
	}
	close $fh;

	goto ROUTE_DEL if !defined($MY_IP);

	my $DEF_ROUTE_NIC;

	# get active NIC
	my @CMD = `netstat -rn`;
	my @ARR;
	foreach (@CMD) {
		if (/^0\.0\.0\.0/ && $_ !~ m/127\.0\.0\.1/) {
			@ARR = split /\s+/;
			$DEF_ROUTE_NIC = $ARR[7];
		last;
		}
	}

	# remove routes to $MY_IP on other interfaces (other than lo)
	@CMD = `netstat -rn`;
	my $count = 0;
	foreach (@CMD) {
		# skip header (first two lines)
		if ($count < 2) {
			$count++;
			next;
		}
		@ARR = split /\s+/;
		if ($ARR[0] eq $MY_IP && $ARR[7] ne "lo") {
		system("/sbin/route del " . $MY_IP . " dev " . $_);
		}
	}

	# check if a route already exists on active NIC, add route if not.
	@CMD = `netstat -rn`;
	$count = 0;
	my $flag = 1;
	foreach (@CMD) {
		# skip header (first two lines)
		if ($count < 2) {
			$count++;
			next;
		}
		@ARR = split /\s+/;
		if ($ARR[0] eq $MY_IP && $ARR[7] eq $DEF_ROUTE_NIC) {
			$flag = 0;
		last;
		}
	}
	if ($flag) {
		system("/sbin/route add " . $MY_IP . " dev " . $DEF_ROUTE_NIC);
	}

ROUTE_DEL:
	# delete all default routes
	my $status = 0;
	while (!$status) {
		system("/sbin/route del default 2>/dev/null");
		$status = $? >> 8; # $? >> 8 is the exit status, see perldoc -f system
	}

	# set default route to localhost
	system("/sbin/route add default gw 127.0.0.1 lo");
	$status = $? >> 8;

	# if the command above succeeded then...
	if (!$status) {
		# start dnsmasq
		system("dnsmasq --address=/#/127.0.0.1 --listen-address=127.0.0.1 --bind-interfaces");
		$flag = 1;

		system("/usr/bin/cp /etc/resolv.conf /etc/resolv.conf.bak");
		# overwrite resolv.conf
		open my $fh, ">/etc/resolv.conf" or $flag = 0;
		if ($flag) {
			# file open succeeded
			print $fh "nameserver 127.0.0.1";
			close $fh;
		}
		# start httpd here
		system("thttpd -r -h localhost -d " . PATH . "vpn-monitor/htdocs");
	} else {
		return $status; # exit with the same error code generated by 'route'
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
	$Current_Status = get_api_status();
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
	$Current_Status = get_api_status();
	$Current_Update_Time = time();
	if ($Current_Status == NET_PROTECTED || $Current_Status == NET_UNPROTECTED) {
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
	};

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
	if (get_api_status() == NET_UNPROTECTED) {
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
	$Current_Status = get_api_status();
	$Current_Update_Time = time();
	if ($Current_Status == NET_PROTECTED) {
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

sub refresh
{
	if ( not defined($Monitor_Enabled) or $Monitor_Enabled == 0 or $Temporary_Disable == 1) {
		return;
	}

	$ctx->log(debug => "Refreshing network status") if DEBUG > 0;

	$Current_Status = get_api_status();
	$Current_Update_Time = time();
	log_net_status($Current_Status) if DEBUG > 0;
	$ctx->log(debug => "\tprevious_status = " . get_status_text($Previous_Status) . " current_status = " . get_status_text($Current_Status) ) if DEBUG > 1;

	my $tmp_previous = $Previous_Status;
	$Previous_Status = $Current_Status;

	# do not retry/redirect if previous state was CRIPPLED, redirect on next iteration
	if ($Current_Status == NET_UNPROTECTED and $tmp_previous != NET_CRIPPLED) {
		# spawn_retry_vpn calls retry_vpn_callback when it finishes
		spawn_retry_vpn();
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

	# make sure there is only one running script
	return unless get_lock();

	# remove stale / write pid 
	if ( -e PID_FILE ) {
		$ctx->log( info => "Removing stale PID file " . PID_FILE );
		system( "/usr/bin/rm -f " . PID_FILE );
	}
	pf_set( PID_FILE );

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
	
	if (defined $ARGV[0]) { spawn_undo_crippling(); };
}

# run initialization code
run_once();


my $timer;
$timer = AnyEvent->timer(
	after => 60, # run after 60 sec the first time
	interval => 60, # then every minute
	cb => \&refresh,
);


################		TCP server		################

my %connections;
my $handle;
my $timer2;

tcp_server(
	IPC_HOST, IPC_PORT, sub {
	my ($fh) = @_;
	
	$handle = AnyEvent::Handle->new(
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
				undef $timer2; 
				$timer2 = AnyEvent->timer(
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
				$self->push_write(get_api_status() . "\n");

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
				undef $timer; # destroy current timer
				$timer = AnyEvent->timer(
					after => 40, # run after 40 sec the first time
					interval => 60, # every minute
					cb => \&refresh,
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
	$connections{$handle} = $handle; # keep it alive.
	return;
	}
);

$ctx->log(info => "Daemon is listening on " . IPC_HOST . ":" . IPC_PORT);


################		Main Loop		################

$cv->recv;


################		Clean up		################

END {
	stop_systemv_logger();
	# remove pid file
	pf_unset( PID_FILE );
}
