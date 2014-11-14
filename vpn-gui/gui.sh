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
# /opt/PrivateOn/vpn-gui/gui.sh		This script closes other vpn-gui instances and starts a new instance
#
#  Note: This script must be run with root credentials, preferably using sudo.
#


PID=`ps aux | grep /opt/PrivateOn/vpn-gui/vpn_gui.pl | grep -v grep | awk 'NR<2 {print $2}'`
if [ ! -z "$PID" ]; then
	kill -9 $PID
fi

/opt/PrivateOn/vpn-gui/vpn_gui.pl 1 
