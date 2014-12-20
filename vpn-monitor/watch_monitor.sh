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
#  vpn-monitor/watch_monitor.sh     Periodically displays response to 'monitor-state'
#


# move cursor to next line
echo -en "Starting VPN-monitor watcher.\n\n\n"


## Save cursor position:
# based on a script from http://invisible-island.net/xterm/xterm.faq.html
exec < /dev/tty
oldstty=$(stty -g)
stty raw -echo min 0
echo -en "\033[6n" > /dev/tty
IFS=';' read -r -d R -a pos
stty $oldstty
row=$((${pos[0]:2} - 2))    # strip off the esc-[ and remove 2 lines


## infinite loop 
while :
do
	## Restore cursor position:
	echo -en "\033["$row";0H"

	## clear line and display time
	echo -en "\r\033[K  `date +%H:%M:%S` \t"

	## send 'monitor-state' to monitor tcp-server
	if ! echo 'monitor-state' | nc 127.0.0.1 44244; then
		echo "Backend not responding"
	fi

	## clear lines and write text
	echo -en "\r\033[K \n\r\033[KPress CTRL+C to stop..."
	sleep 1
done
