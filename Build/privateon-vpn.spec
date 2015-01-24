#
# spec file for package privateon-vpn
#
# PrivateOn-VPN -- Because privacy matters.
#
# Author: Kimmo R. M. Hovi <kimmo@fairwarning.fi>
#
# Copyright (C) 2015  PrivateOn / Tietosuojakone Oy, Helsinki, Finland
# All rights reserved. Use is subject to license terms.
#

Name:           privateon-vpn
Packager:       Tietosuojakone Oy <info@tietosuojakone.fi>
Version:        0.9
Release:        1
Summary:        PrivateOn VPN package
License:        Artistic-2.0
Group:          Productivity/Networking/Security
Url:            http://www.privateon.net
Source0:        privateon-vpn-0.9.tar
Distribution:   openSUSE 13.2
Requires:       perl-AnyEvent perl-qt4 thttpd dnsmasq perl-HTTP-Lite perl-List-MoreUtils perl-IO-Pty-Easy perl-UI-Dialog xhost
Suggests:       monit


# Sadly, openSUSE at this time provides only 3.72 (Workaround for perl 5.20 bug needs 3.73)
# perl-common-sense >= 3.73

# These are available from the standard perl devel repo;
# perl-UI-Dialog (UI::Dialog::Backend::KDialog)
# perl-IO-Pty-Easy (IO::Pty::Easy)

# Additional packages required, not found in base repos; To be built by us:
# perl-AnyEvent-Fork-RPC (AnyEvent::Fork::RPC)
# perl-No-Norries (No::Worries::PidFile)

# Additionally:
#"SvREFCNT_inc" is not exported by the Devel::Peek module
#Can't continue after import errors at /usr/lib/perl5/vendor_perl/5.20.1/x86_64-linux-thread-multi/QtGui4.pm line 25.
# To remedy this problem, simply remove the qw(svREFCNT_inc) from the line (It's not needed anyway)


%description
PrivateOn VPN is a robust VPN monitor/manager bundle

%prep
%setup

%install
mkdir -p %{buildroot}/opt/PrivateOn-VPN/vpn-gui/images %{buildroot}/opt/PrivateOn-VPN/vpn-monitor/htdocs/errors %{buildroot}/etc/systemd/system %{buildroot}/etc/sudoers.d %{buildroot}/var/run/PrivateOn
for file in vpn-default.ini LICENSE README.md $(find vpn-gui vpn-monitor -type f); do
    cp $file %{buildroot}/opt/PrivateOn-VPN/$file
done
cp install/vpnmonitor.service %{buildroot}/etc/systemd/system/
cp install/sudoers.d/PrivateOn %{buildroot}/etc/sudoers.d/

%post
grep /usr/lib/perl5/5.20.1/x86_64-linux-thread-multi/CORE /etc/ld.so.conf >/dev/null 2>&1 || (echo "/usr/lib/perl5/5.20.1/x86_64-linux-thread-multi/CORE" >> /etc/ld.so.conf && ldconfig)
systemctl daemon-reload
systemctl enable vpnmonitor.service
systemctl start vpnmonitor.service

%files
/etc/sudoers.d/PrivateOn
/etc/systemd/system/vpnmonitor.service
/opt/PrivateOn-VPN/LICENSE
/opt/PrivateOn-VPN/README.md
/opt/PrivateOn-VPN/vpn-default.ini
/opt/PrivateOn-VPN/vpn-gui/gui.sh
/opt/PrivateOn-VPN/vpn-gui/kill_gui.sh
/opt/PrivateOn-VPN/vpn-gui/vpn_countries.pm
/opt/PrivateOn-VPN/vpn-gui/vpn_gui.pl
/opt/PrivateOn-VPN/vpn-gui/vpn_install.pm
/opt/PrivateOn-VPN/vpn-gui/vpn_ipc.pm
/opt/PrivateOn-VPN/vpn-gui/vpn_tray.pm
/opt/PrivateOn-VPN/vpn-gui/vpn_window.pm
/opt/PrivateOn-VPN/vpn-gui/images/PrivateOn-icon.png
/opt/PrivateOn-VPN/vpn-gui/images/PrivateOn-logo.png  
/opt/PrivateOn-VPN/vpn-gui/images/tray-broken-guard.png
/opt/PrivateOn-VPN/vpn-gui/images/tray-broken-ignore.png  
/opt/PrivateOn-VPN/vpn-gui/images/tray-crippled-guard.png
/opt/PrivateOn-VPN/vpn-gui/images/tray-protected-guard.png  
/opt/PrivateOn-VPN/vpn-gui/images/tray-protected-ignore.png
/opt/PrivateOn-VPN/vpn-gui/images/tray-refresh-guard.png     
/opt/PrivateOn-VPN/vpn-gui/images/tray-unprotected-guard.png
/opt/PrivateOn-VPN/vpn-gui/images/tray-unprotected-ignore.png
/opt/PrivateOn-VPN/vpn-monitor/vpn_logger.sh
/opt/PrivateOn-VPN/vpn-monitor/vpn_monitor.pl
/opt/PrivateOn-VPN/vpn-monitor/vpn_retry.pm
/opt/PrivateOn-VPN/vpn-monitor/vpn_uncripple.pm
/opt/PrivateOn-VPN/vpn-monitor/watch_monitor.sh
/opt/PrivateOn-VPN/vpn-monitor/htdocs/index.html
%dir /opt/PrivateOn-VPN/vpn-monitor/htdocs/errors
%dir /var/run/PrivateOn

%doc


%changelog
