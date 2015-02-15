#!/bin/bash
#
# PrivateOn-VPN -- Because privacy matters.
#
# Author: Mikko Rautiainen <info@tietosuojakone.fi>
#         Kimmo R. M. Hovi <kimmo@fairwarning.fi>
#
# Copyright (C) 2014-2015  PrivateOn / Tietosuojakone Oy, Helsinki, Finland
# All rights reserved. Use is subject to license terms.
#

#
#  vpn-gui/gui.sh     This script closes other vpn-gui instances and starts a new instance
#


CHECK=/opt/PrivateOn-VPN/vpn-monitor/check_monitor.pl
DAEMON=/opt/PrivateOn-VPN/vpn-gui/vpn_gui.pl

# XAUTHORITY variable is not set if user is already root
if test "$(id -u)" -ne 0; then
	export XAUTHORITY=$HOME/.Xauthority
fi

export DISPLAY=:0.0
xhost SI:localuser:root

# Check network and vpn-monitor
echo -e "\nStarting check_monitor.pl in the background."
sudo DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY $CHECK &

# Kill existing instance of vpn-gui
PID=`ps aux | grep $DAEMON | grep -v grep | awk 'NR<2 {print $2}'`
if [ ! -z "$PID" ]; then
	sudo /opt/PrivateOn-VPN/vpn-gui/kill_gui.sh
fi

# Start vpn-gui
sudo DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY $DAEMON --show
