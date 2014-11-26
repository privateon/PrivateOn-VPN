#!/bin/bash
#
# PrivateOn-VPN -- Because privacy matters.
#
# Author: Mikko Rautiainen <info@tietosuojakone.fi>
#
# Copyright (C) 2014  PrivateOn / Tietosuojakone Oy, Helsinki, Finland
# All rights reserved. Use is subject to license terms.
#

#
#  vpn-gui/gui.sh     This script closes other vpn-gui instances and starts a new instance
#
#   Note: This script must be run with root credentials, preferably using sudo.
#

DAEMON=/opt/PrivateOn-VPN/vpn-gui/vpn_gui.pl

PID=`ps aux | grep $DAEMON | grep -v grep | awk 'NR<2 {print $2}'`
if [ ! -z "$PID" ]; then
	kill -9 $PID
fi

$DAEMON 1 
