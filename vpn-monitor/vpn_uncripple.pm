package vpn_uncripple;

#
# PrivateOn-VPN -- Because privacy matters.
#
# Copyright (C) 2014-2015  PrivateOn / Tietosuojakone Oy, Helsinki, Finland
# All rights reserved. Use is subject to license terms.
#


use strict;
use warnings;

use File::stat;

use AnyEvent;
use AnyEvent::Log;

use constant {
	LOG_FILE      => "/var/log/PrivateOn.log",
	VERSION       => "0.9",
	DEBUG         => 1
};


sub undo_crippling
{
	my $ctx = shift;
	$ctx->log(info => "Undoing all network crippling (vpn_uncripple child)");

	my @pid;
	@pid = `ps -ef | grep thttpd | grep -v grep | awk '{print \$2}'`;
	kill 'KILL', @pid;
	@pid = `ps -ef | grep dnsmasq | grep -v grep | awk '{print \$2}'`;
	kill 'KILL', @pid;
	system("/bin/pkill -9 openvpn");
	system("/sbin/route del default gw 127.0.0.1 lo");
	system("/usr/bin/rm -f /etc/resolv.conf");
	system("/sbin/service network restart");

	# wait for log updates to stop
	my $filename = '/var/log/NetworkManager';
	my ($mtime, $log_time);
	$mtime = stat($filename)->mtime;
	for (my $i = 0; $i < 4; $i ++) {
		$log_time = stat($filename)->mtime;
		if ($log_time != $mtime) {
			last;
		} else {
			sleep 5;
		}
	}
}

 
sub run 
{
	my ($done) = @_;

	my $ctx = new AnyEvent::Log::Ctx;
	$ctx->log_to_file(LOG_FILE);
	$ctx->log(debug => "Child process started (vpn_uncripple child)") if DEBUG > 0;

	undo_crippling($ctx);

	$ctx->log(debug => "Child process ended (vpn_uncripple child)") if DEBUG > 0;
	$done->(0);
	return 0;
}


1;
