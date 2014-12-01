#
# spec file for package privateon
#
# Copyright (c) 2013 SUSE LINUX Products GmbH, Nuernberg, Germany.
#
# All modifications and additions to the file contributed by third parties
# remain the property of their copyright owners, unless otherwise agreed
# upon. The license for this file, and modifications and additions to the
# file, is the same license as for the pristine package itself (unless the
# license for the pristine package is not an Open Source License, in which
# case the license is the MIT License). An "Open Source License" is a
# license that conforms to the Open Source Definition (Version 1.9)
# published by the Open Source Initiative.

# Please submit bugfixes or comments via http://bugs.opensuse.org/
#


# See also http://en.opensuse.org/openSUSE:Specfile_guidelines

Name:           privateon
Packager:       Kimmo R. M. Hovi <kimmo@fairwarning.fi>
Version:        0.1
Release:        5
Summary:        PrivateOn VPN package
License:        Open Source
Group:          Productivity/Networking/Security
Url:            http://www.privateon.net
Source0:        privateon-0.1.tar
Distribution:   openSUSE 13.2
#BuildRequires:  
Requires:       perl-AnyEvent perl-qt4 thttpd dnsmasq monit perl-HTTP-Lite perl-List-MoreUtils perl-Guard perl-IO-Pty-Easy perl-UI-Dialog
# Sadly, openSUSE at this time provides only 3.72 (Workaround for perl 5.20 bug needs 3.73)
# perl-common-sense >= 3.73

# There are available from the standard perl devel repo;
# perl-UI-Dialog (UI::Dialog::Backend::KDialog)
# perl-Guard (Guard)
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
mkdir -p %{buildroot}/opt/PrivateOn-VPN/vpn-gui/{images,icons} %{buildroot}/opt/PrivateOn-VPN/vpn-monitor/htdocs/errors %{buildroot}/etc/systemd/system %{buildroot}/etc/sudoers.d %{buildroot}/var/run/PrivateOn
for file in vpn-default.ini LICENSE $(find vpn-gui vpn-monitor -type f); do
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
/opt/PrivateOn-VPN/vpn-default.ini
/opt/PrivateOn-VPN/vpn-gui/MainWindow.pm
/opt/PrivateOn-VPN/vpn-gui/gui.sh
/opt/PrivateOn-VPN/vpn-gui/icons/logo.png
/opt/PrivateOn-VPN/vpn-gui/images/broken.png
/opt/PrivateOn-VPN/vpn-gui/images/logo.png
/opt/PrivateOn-VPN/vpn-gui/images/protected.png
/opt/PrivateOn-VPN/vpn-gui/images/unprotected.png
/opt/PrivateOn-VPN/vpn-gui/vpn_gui.pl
/opt/PrivateOn-VPN/vpn-gui/vpn_install.pm
/opt/PrivateOn-VPN/vpn-gui/vpn_status.pm
/opt/PrivateOn-VPN/vpn-gui/vpn_tray.pm
/opt/PrivateOn-VPN/vpn-monitor/htdocs/index.html
/opt/PrivateOn-VPN/vpn-monitor/vpn_logger.sh
/opt/PrivateOn-VPN/vpn-monitor/vpn_monitor.pl
/opt/PrivateOn-VPN/vpn-monitor/vpn_retry.pm
/opt/PrivateOn-VPN/vpn-monitor/vpn_uncripple.pm
%dir /var/run/PrivateOn

%doc


%changelog
