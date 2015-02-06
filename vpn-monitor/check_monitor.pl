#!/usr/bin/perl

# Copyright (C) 2014-2015  PrivateOn / Tietosuojakone Oy, Helsinki, Finland
# All rights reserved. Use is subject to license terms.

# This script checks that the vpn monitor is up and starts/restarts it if needed. 
# It can also stop openvpn and restart network if anything is wrong with them.

use strict;
use warnings;

use File::Pid;
use IO::Socket;
use LWP::UserAgent;
use Net::Ping;
use POSIX;
use Proc::ProcessTable;
use Try::Tiny;

use constant {
	DEBUG   => 2, # verbosity level, 1 is WARNINGs only, 0 is no messages
	PIDFILE => '/var/run/vpn-monitor-checker.pid',  
	TIMEOUT_SINCE_LAST_START => 20, # seconds since the last start to allow new instance to run

	MAX_CHECK_ITERATIONS => 3, # try to make the system up and running for that many times
	
	QUERY_HOST => 'localhost',
	QUERY_PORT => 44244,
	QUERY_TIMEOUT => 2,   # timeout to wait for TCP reply from vpnmonitor
	MAX_QUERY_ITERATIONS => 3, # will try to query monitor for 3 times
	ACTION_TIMEOUT => 2,  # timeout after kills, system(), etc.
	API_CHECK_TIMEOUT => 5, # timeout to wait for API reply (check url)

	MONITOR_SERVICE_NAME => 'vpnmonitor',
	OPENVPN_BINARY => '/usr/sbin/openvpn',
	MONITOR_SCRIPT => '/opt/PrivateOn-VPN/vpn-monitor/vpn_monitor.pl',
	MONITOR_DEFAULT => '/opt/PrivateOn-VPN/vpn-default.ini',

	MONIT_SERVICE_NAME => 'monit',
	MONIT_BINARY => '/usr/bin/monit',
	MONIT_CONFIG => '/etc/monitrc',
	MONIT_PROCESS_NAME => 'vpnmonitor',

	DISPATCHER_FILE => '/etc/NetworkManager/dispatcher.d/vpn-up',
};

sub debug
{
	my ($verbosity, @printargs) = @_;
	if ($verbosity <= DEBUG) {
		printf STDERR @printargs;
		print STDERR "\n"
	}
}

sub exit_if_not_root
{
	my $euid = geteuid();
	if ($euid != 0) {
		debug(0, 'The script must be run as root.');
		exit(128);
	}
}

sub exit_if_another_instance_exists
{
	my $pidfile = File::Pid->new({ file => PIDFILE });
	
	my $filename = $pidfile->file;
	if (-r $filename) {
		my @stat = stat $filename;
		my $mtime = $stat[9];
		my $diff = time - $mtime;
		if ($diff < TIMEOUT_SINCE_LAST_START) {
			debug(1, 'WARNING: Last start was %d seconds ago, exiting.', $diff);
			exit(64);
		}
		debug(2, 'The script was last started %d seconds ago, will continue working.', $diff);
		my $existing_pid = $pidfile->running;
		if ($existing_pid) {
			debug(1, 'WARNING: Process with PID %d is already running, exiting.', $existing_pid);
			exit(64);
		}
		else {
			debug(2, 'No running process found, will continue working.');
			$pidfile->remove;
		}
	}

	$pidfile = File::Pid->new({ file => PIDFILE });
	my $wrote = $pidfile->write;
	if (!defined $wrote) {
		debug(1, 'WARNING: cannot save PID file %s.', $pidfile->file);
	}
}

sub monitor_replies
{
	for (1 .. MAX_QUERY_ITERATIONS) {
		if ($_ != 1) {
			sleep ACTION_TIMEOUT;
		}

		my $sock = IO::Socket::INET->new(PeerHost => QUERY_HOST, 
						 PeerPort => QUERY_PORT,
						 Timeout  => QUERY_TIMEOUT,
						);
		if (!$sock) {
			debug(1, 'WARNING: Cannot connect to %s:%d in %d seconds. Monitor looks bad.', QUERY_HOST, QUERY_PORT, QUERY_TIMEOUT);
			next;
		}

		print $sock "monitor-state\n";
		my $fileno = fileno($sock);
		my $readvector = '';
		vec($readvector, $fileno, 1) = 1;
		my $errorvector = $readvector;

		my $nfound = select($readvector, undef, $errorvector, QUERY_TIMEOUT);
		if ($nfound == 0) {
			debug(1, 'WARNING: No reply from monitor in %d seconds. Monitor looks bad.', QUERY_TIMEOUT);
			$sock->close;
			next;
		}

		if (vec($errorvector, $fileno, 1)) {
			debug(1, 'WARNING: Error reading from monitor connection. Monitor looks bad.');
			$sock->close;
			next;
		}

		if (vec($readvector, $fileno, 1)) {
			chomp(my $content = <$sock>);
			debug(2, 'Read from socket: %s', $content);
			$sock->close;
			return 1;
		}
		# was select interrupted by signal? anyway, check failed
		debug(1, 'WARNING: Could not get a reply from monitor. Monitor looks bad.');
		$sock->close;
		next;
	}

	debug(1, 'WARNING: could not get a reply from monitor in %d iterations. Monitor looks bad.', MAX_QUERY_ITERATIONS);
	return 0;
}

sub tun0_exists
{
	my $result = 0;
	open(my $iph, "ip link list |") or do {
		debug(1, 'WARNING: Cannot run list network interfaces.');
		return $result;
	};
	while (<$iph>) {
		if (/^\d+: (tun\d+):/) {
			debug(2, 'Found tun interface %s.', $1);
			$result = $1;
		}
	}
	close $iph;
	return $result;
}

sub find_pid
{
	my ($cmd_regex) = @_;
	my $process_table = Proc::ProcessTable->new(enable_ttys => 0);
	if (!defined $process_table) {
		debug(1, 'WARNING: Cannot load process table.');
		return 0;
	}
	foreach my $process (@{$process_table->table}) {
		if ($process->cmndline =~ $cmd_regex) {
			return $process->pid;
		}
	}
	return 0;
}

sub openvpn_is_running
{
	my $regex_line = '^' . quotemeta(OPENVPN_BINARY);
	my $regex = qr/$regex_line/;
	my $openvpn_pid = find_pid($regex);
	if ($openvpn_pid) {
		debug(2, 'Found openvpn process: pid %d.', $openvpn_pid);
		return $openvpn_pid;
	}
	return 0;
}

sub monitor_is_running
{
	my $regex_line = quotemeta(MONITOR_SCRIPT);
	my $regex = qr/$regex_line/;
	my $monitor_pid = find_pid($regex);
	if ($monitor_pid) {
		debug(2, 'Found vpn_monitor process: pid %d.', $monitor_pid);
		return $monitor_pid;
	}
	return 0;
}

sub monit_is_running
{
	my $regex_line = quotemeta(MONIT_BINARY);
	my $regex = qr/$regex_line/;
	my $monit_pid = find_pid($regex);
	if ($monit_pid) {
		debug(2, 'Found monit process: pid %d.', $monit_pid);
		return $monit_pid;
	}
	return 0;
}

sub monit_is_installed
{
	return -e MONIT_BINARY && -e MONIT_CONFIG ? 1 : 0;
}

sub monit_config_good
{
	if (system(MONIT_BINARY . " -t > /dev/null 2>&1") != 0) {
		debug(1, 'WARNING: Monit config seems broken.');
		return 0;
	};
	if ($? != 0) {
		debug(1, 'WARNING: Monit config seems broken.');
		return 0;
	}

	my $check_found = 0;
	open(my $fh, MONIT_CONFIG) or return 0;
	while (<$fh>) {
		my $regexline = sprintf '^check\sprocess\s%s.*(?:pidfile|matching)', MONIT_PROCESS_NAME;
		if (/$regexline/i) {
			$check_found = 1;
			last;
		}
	}
	close $fh;

	return $check_found;
}

sub stop_monitor
{
	my $result = 1;

	system(sprintf("/sbin/service %s stop > /dev/null 2>&1", MONITOR_SERVICE_NAME));
	my $pid = monitor_is_running();
	if ($pid) {
		kill('TERM', $pid);
		sleep ACTION_TIMEOUT;
		$pid = monitor_is_running();
		if ($pid) {
			kill('KILL', $pid);
			sleep ACTION_TIMEOUT;
			if (monitor_is_running()) {
				debug(1, 'WARNING: Cannot kill running monitor.');
			}
			else {
				debug(2, 'Monitor has been killed by SIGKILL.');
				$result = 1;
			}
		}
		else {
			debug(2, 'Monitor has been terminated by SIGTERM.');
			$result = 1;
		}
	}
	else {
		debug(2, 'Monitor has been stopped using /sbin/service.');
		$result = 1;
	}
	return $result;
}

sub start_monit
{
	my $result = 0;

	if (system(sprintf("/sbin/service %s start > /dev/null 2>&1", MONIT_SERVICE_NAME)) != 0) {
		debug(1, 'WARNING: Cannot execute "/sbin/service %s start".', MONIT_SERVICE_NAME);
	}
	if ($? != 0) {
		debug(1, 'WARNING: /sbin/service failed to start %s.', MONIT_SERVICE_NAME);
	}
	else {
		sleep ACTION_TIMEOUT;
		if (monit_is_running()) {
			debug(2, 'Successfully started service %s.', MONIT_SERVICE_NAME);
			$result = 1;
		}
		else {
			debug(1, 'WARNING: /sbin/service started %s but it did not start.', MONIT_SERVICE_NAME);
		}
	}

	return $result;
}

sub start_monitor
{
	if (monitor_is_running()) {
		debug(2, 'Will not start vpn-monitor as it is already running.');
		return 1;
	}
	my $result = 0;

	if (monit_is_installed()) {
		if (monit_config_good()) {
			if (!monit_is_running()) {
				debug(2, 'Will try to start monit as it is not running.');
				start_monit();
				sleep ACTION_TIMEOUT;
			}

			if (system(sprintf("%s start %s > /dev/null 2>&1", MONIT_BINARY, MONIT_PROCESS_NAME)) != 0) {
				debug(1, 'WARNING: Cannot execute %s to start %s.', MONIT_PROCESS_NAME);
			}
			if ($? != 0) {
				debug(1, 'WARNING: Monit failed to start %s.', MONIT_PROCESS_NAME);
			}
			else {
				sleep ACTION_TIMEOUT;
				if (monitor_is_running()) {
					debug(2, 'Successfully started %s using monit.', MONIT_PROCESS_NAME);
					$result = 1;
				}
				else {
					debug(1, 'WARNING: Monit started %s but it did not start.', MONIT_PROCESS_NAME);
				}
			}
		}
	}

	if (!$result) {
		if (system(sprintf("/sbin/service %s start > /dev/null 2>&1", MONITOR_SERVICE_NAME)) != 0) {
			debug(1, 'WARNING: Cannot execute "/sbin/service %s start".', MONITOR_SERVICE_NAME);
		}
		if ($? != 0) {
			debug(1, 'WARNING: /sbin/service failed to start %s.', MONITOR_SERVICE_NAME);
		}
		else {
			sleep ACTION_TIMEOUT;
			if (monitor_is_running()) {
				debug(2, 'Successfully started service %s.', MONITOR_SERVICE_NAME);
				$result = 1;
			}
			else {
				debug(1, 'WARNING: /sbin/service started %s but it did not start.', MONITOR_SERVICE_NAME);
			}
		}
	}

	return $result;
}

sub get_api_check_url
{
	my $url = undef;
	open(my $fh, MONITOR_DEFAULT) or do {
		debug(1, 'WARNING: Cannot open file %s: %s.', MONITOR_DEFAULT, $!);
		return undef;
	};
	while (<$fh>) {
		if (/^url=(\S+)/) {
			$url = $1;
			last;
		}
	}
	close $fh;

	return $url;
}

sub check_api
{
	my $url = get_api_check_url();
	if (!defined $url) {
		debug(1, 'WARNING: Cannot determine API check URL.');
		return 0;
	}

	my $useragent = LWP::UserAgent->new;
	$useragent->timeout(API_CHECK_TIMEOUT);

	my $response = $useragent->get($url);
	if ($response->is_success) {
		my $content = $response->decoded_content;
		$content =~ s/[\s\n]+/ /g;
		debug(2, 'API check url: returned %s.', $content);
		if ($content =~ /Protected/) {
			return "protected";
		}
		return 0;
	}

	debug(1, 'WARNING: API check failed.');
	return 0;
}

sub find_vpn_gateway
{
	open(my $fh, "/proc/net/route") or do {
		debug(1, 'WARNING: Cannot open /proc/net/route: %s.', $!);
		return undef;
	};
	chomp(my $firstline = <$fh>);
	my @headers = split /\s+/, $firstline;

	my $found_hex;
	while (<$fh>) {
		chomp;
		next if /^\s*$/;
		my @values = split /\s+/, $_;
		my %line;
		@line{@headers} = @values;

		if ($line{Iface} =~ /^tun\d+$/ && (hex($line{Flags}) & (2 | 4)) && $line{Mask} eq 'FFFFFFFF') {
			$found_hex = $line{Destination};
			last;
		}
	}
	close $fh;

	if (!defined $found_hex) {
		return undef;
	}
	
	my $ip = join('.', reverse map { hex($_); } ($found_hex =~ /([0-9a-f]{2})/gi));
	debug(2, 'Found gateway IP: %s.', $ip);
	return $ip;
}

sub ping_vpn_gateway
{
	my $ip = find_vpn_gateway();
	if (!defined $ip) {
		debug(1, 'Cannot determine VPN gateway IP.');
		return 0;
	}

	my $np = Net::Ping->new('icmp');
	if (!$np->ping($ip)) {
		debug(1, 'WARNING: VPN gateway %s does not respond to ping.', $ip);
		return 0;
	}

	debug(2, 'Successfully pinged VPN gateway %s.', $ip);
	return 1;
}

sub kill_openvpn
{
	my $result = 0;

	my $pid = openvpn_is_running();
	if ($pid) {
		kill('TERM', $pid);
		sleep ACTION_TIMEOUT;
		$pid = openvpn_is_running();
		if ($pid) {
			kill('KILL', $pid);
			sleep ACTION_TIMEOUT;
			if (openvpn_is_running()) {
				debug(1, 'WARNING: Cannot kill running openvpn.');
			}
			else {
				debug(2, 'openvpn has been killed by SIGKILL.');
				$result = 1;
			}
		}
		else {
			debug(2, 'openvpn has been terminated by SIGTERM.');
			$result = 1;
		}
	}
	else {
		$result = 1;
	}

	return $result;
}

sub restart_network
{
	my $result = 0;
	if (system("/sbin/service network restart > /dev/null 2>&1") != 0) {
		debug(1, 'WARNING: Cannot execute "/sbin/service network restart".');
	}
	if ($? != 0) {
		debug(1, 'WARNING: /sbin/service failed to restart network.', MONITOR_SERVICE_NAME);
	}
	else {
		debug(2, 'Network restarted successfully.');
		$result = 1;
	}

	return $result;
}

sub erase_dispatcher_file
{
	my $result = 0;
	if (-e DISPATCHER_FILE) {
		if (unlink DISPATCHER_FILE) {
			debug(2, 'Successfully erased dispatcher file.');
			$result = 1;
		}
		else {
			debug(1, 'WARNING: Dispatcher file has not been deleted.');
		}
	}
	else {
		$result = 1;
	}

	return $result;
}

sub popup_dialog
{
	# Depending on your system, the popup may fail to be rendered if this script is run from the command-line.
	my ($msg) = @_;
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
		}

		# check is xhost already allows non-network local connections 
		my $remove_access = 0;
		if (system("su -l $username -c \"DISPLAY=:0 xhost \" 2> /dev/null | grep -i LOCAL >/dev/null 2>&1")) {
			# add non-network local connections to X display access control list
			system("su -l $username -c \"DISPLAY=:0 xhost +local:\" >/dev/null 2>&1");
			$remove_access = 1;
		}

		my $cmd=("kdialog --display :0 --title \"PrivateOn-VPN\" --passivepopup \"$msg\" 120 &");
		system($cmd);

		# undo xhost exception
		if ($remove_access) {
			system("su -l $username -c \"DISPLAY=:0 xhost -local:\" >/dev/null 2>&1");
		}
	} catch {
		debug(1, 'WARNING: exception when trying to display popup dialog: %s.', $_);
	};
}

sub main
{
	my $need_monitor_stop = 0;
	my $need_openvpn_stop = 0;
	my $need_network_restart = 0;
	my $need_monitor_start = 0;
	my $exitcode = 0;
	my @popup_messages;

	# Initial checks
	if (!monitor_is_running()) {
		$need_monitor_start = 1;
	}
	else {
		if (!monitor_replies()) {
			$need_monitor_stop = 1;
			if (tun0_exists() || openvpn_is_running()) {
				if (!check_api() && !ping_vpn_gateway()) {
					$need_openvpn_stop = 1;
					$need_network_restart = 1;
				}
			}
			$need_monitor_start = 1;
		}
	}

	my $iteration = 0;
	while ($need_monitor_stop || $need_openvpn_stop || $need_network_restart || $need_monitor_start) {
		++$iteration;
		if ($iteration == MAX_CHECK_ITERATIONS) {
			last;
		}

		if ($need_monitor_stop) {
			debug(2, 'Will stop vpn-monitor.');
			$need_monitor_stop = 0;
			if (!stop_monitor()) {
				push @popup_messages, 'Could not stop running vpnmonitor.';
				$exitcode ||= 1;
				$need_monitor_stop = 1;
			}
		}
		if ($need_openvpn_stop) {
			debug(2, 'Will stop openvpn.');
			$need_openvpn_stop = 0;
			if (!kill_openvpn()) {
				push @popup_messages, 'Could not stop running openvpn.';
				$exitcode ||= 2;
				$need_openvpn_stop = 1;
			}
			push @popup_messages, 'VPN has stopped.';
		}
		if ($need_network_restart) {
			debug(2, 'Will restart network.');
			$need_network_restart = 0;
			if (!erase_dispatcher_file()) {
				push @popup_messages, 'Could not erase dispatcher file.';
				$exitcode ||= 4;
				$need_network_restart = 1;
			}
			if (!restart_network()) {
				push @popup_messages, 'Could not restart network.';
				$exitcode ||= 8;
				$need_network_restart = 1;
			}
		}
		if ($need_monitor_start) {
			$need_monitor_start = 0;

			if ($exitcode & 16 == 0 && monit_is_installed() && !monit_config_good()) {
				push @popup_messages, 'Monit configuration error, please check ' . MONIT_CONFIG . '.';
				$exitcode ||= 16;
				$need_monitor_start = 1;
			}

			debug(2, 'Will start vpn-monitor.');
			if (!start_monitor()) {
				push @popup_messages, 'Could not start vpnmonitor.';
				$exitcode ||= 32;
				$need_monitor_start = 1;
			}

			if (monitor_is_running()) {
				if (!monitor_replies()) {
					$need_monitor_stop = 1;
					$need_openvpn_stop = 1;
					$need_network_restart = 1;
					$need_monitor_start = 1;
				}
			}
			else {
				$need_monitor_start = 1;
			}
		}
	}

	if (@popup_messages) {
		if (monitor_is_running()) {
			push @popup_messages, 'VPN Monitor is running.';
		}
		my $popup_message = join("\n", @popup_messages);
		popup_dialog($popup_message);
	}

	debug(2, 'Exiting with code %d.', $exitcode);
	return $exitcode;
}

exit_if_not_root();
exit_if_another_instance_exists();
exit(main());

