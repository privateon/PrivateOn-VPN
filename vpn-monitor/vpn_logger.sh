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
# /opt/PrivateOn/vpn-monitor/vpn_logger.sh	Writes system V style log file on systemd distributions
#


#
# Only root should use
#
if test "$(id -u)" -ne 0; then
   echo "${0##*/}: only root can use ${0##*/}" 1>&2
   exit 1
fi

journalctl -u NetworkManager -f -o short > /var/log/NetworkManager
