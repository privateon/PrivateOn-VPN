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
Release:        0
Summary:        PrivateOn VPN package
License:        Open Source
Group:          Productivity/Networking/Security
Url:            http://www.privateon.net
Source0:        privateon-0.1.tar
Distribution:   openSUSE 13.2
#BuildRequires:  
Requires:       perl-AnyEvent perl-qt4 thttpd dnsmasq monit

%description
PrivateOn VPN is a robust VPN monitor/manager bundle

%prep

%install
mkdir -p %{buildroot}/opt/PrivateOn/vpn-gui/{images,icons} %{buildroot}/opt/PrivateOn/vpn-monitor/htdocs/errors %{buildroot}/etc/systemd/system %{buildroot}/etc/sudoers.d
for file in vpn-default.ini LICENSE $(find vpn-gui vpn-monitor -type f); do
    cp $file %{buildroot}/opt/PrivateOn/$file
done
cp install/vpnmonitor.service %{buildroot}/etc/systemd/system/
cp install/sudoers.d/PrivateOn %{buildroot}/etc/sudoers.d/

%files
/etc/sudoers.d/PrivateOn
/etc/systemd/system/vpnmonitor.service
/opt/PrivateOn/LICENSE
/opt/PrivateOn/vpn-default.ini
/opt/PrivateOn/vpn-gui/MainWindow.pm
/opt/PrivateOn/vpn-gui/gui.sh
/opt/PrivateOn/vpn-gui/icons/logo.png
/opt/PrivateOn/vpn-gui/images/broken.png
/opt/PrivateOn/vpn-gui/images/logo.png
/opt/PrivateOn/vpn-gui/images/protected.png
/opt/PrivateOn/vpn-gui/images/unprotected.png
/opt/PrivateOn/vpn-gui/vpn_gui.pl
/opt/PrivateOn/vpn-gui/vpn_install.pm
/opt/PrivateOn/vpn-gui/vpn_status.pm
/opt/PrivateOn/vpn-gui/vpn_tray.pm
/opt/PrivateOn/vpn-monitor/htdocs/index.html
/opt/PrivateOn/vpn-monitor/vpn_logger.sh
/opt/PrivateOn/vpn-monitor/vpn_monitor.pl
/opt/PrivateOn/vpn-monitor/vpn_retry.pm
/opt/PrivateOn/vpn-monitor/vpn_uncripple.pm

%doc


%changelog
