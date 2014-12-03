#!/bin/bash
#
# PrivateOn-VPN -- Because privacy matters.
#
# Author: Kimmo R. M. Hovi <kimmo@fairwarning.fi>
#
# Copyright (C) 2014  PrivateOn / Tietosuojakone Oy, Helsinki, Finland
# All rights reserved. Use is subject to license terms.
#

#
#  vpn-gui/kill_gui.sh     This script kills an existing instance of the vpn gui
#
#   Note: This script must be run with root credentials, preferably using sudo.
#

DAEMON=/opt/PrivateOn-VPN/vpn-gui/vpn_gui.pl

PID=`ps aux | grep $DAEMON | grep -v grep | awk 'NR<2 {print $2}'`
if [ ! -z "$PID" ]; then
	sudo /usr/bin/kill -9 $PID
fi
