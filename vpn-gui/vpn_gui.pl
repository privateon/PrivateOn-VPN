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
#		/opt/PrivateOn-VPN/vpn-gui/vpn_gui.pl
#
#   Vpn-gui is the front-end for the vpn-monitor daemon.
#   This application is used to change the selected VPN server.
#   When you want to turn off the VPN, it must be done using the application,
#   otherwise the backend and dispatcher script will reconnect the VPN.
#
#  Note: This program must be run with root credentials, preferably using sudo.
#  Note: The vpn-gui requires that this daemon is running.
#


use strict;
use warnings;
use QtCore4;
use QtGui4;
use lib "/opt/PrivateOn-VPN/vpn-gui";
use vpn_window;
use vpn_tray;

sub main
{
	my $app = Qt::Application(\@ARGV);
	my $window = vpn_window();
	my $tray = vpn_tray($window);

	if ( defined($ARGV[0]) && ($ARGV[0] eq '1') ) {
		$window->show();
	}
	return $app->exec();
}

exit main();
