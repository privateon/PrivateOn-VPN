#
# spec file for package privateon-vpn
#
# PrivateOn-VPN -- Because privacy matters.
#
# Author: Kimmo R. M. Hovi <kimmo@fairwarning.fi>,
#         Maksim A. Boyko <maksim.a.boyko@gmail.com>
#
# Copyright (C) 2015  PrivateOn / Tietosuojakone Oy, Helsinki, Finland
# All rights reserved. Use is subject to license terms.
#

Name:           privateon-vpn
Packager:       Tietosuojakone Oy <info@tietosuojakone.fi>
Version:        __VERSION__
Release:        __RELEASE__
Summary:        PrivateOn VPN package
License:        Artistic-2.0
Group:          Productivity/Networking/Security
Url:            http://www.privateon.net
Source:         privateon-vpn-%{version}.tar.gz
Distribution:   __DISTRIBUTION__
BuildArch:      noarch
BuildRequires:  systemd
BuildRequires:  systemd-rpm-macros
BuildRequires:  update-desktop-files
BuildRequires:  logrotate
BuildRequires:  sudo
Requires:       perl
Requires:       perl-qt4
Requires:       perl-POE
Requires:       perl-AnyEvent
Requires:       perl-HTTP-Lite
Requires:       perl-UI-Dialog
Requires:       perl-IO-Pty-Easy
Requires:       perl-IO-Interface
Requires:       perl-List-MoreUtils
Requires:       perl-Proc-ProcessTable
Requires:       perl-AnyEvent-HTTP
Requires:       perl-File-Pid
Requires:       perl-IO-FDPass
Requires:       perl-Proc-FastSpawn
Requires:       perl-AnyEvent-Fork
Requires:       perl-AnyEvent-Fork-RPC
Requires:       perl-No-Worries
Requires:       thttpd
Requires:       dnsmasq
Requires:       xhost
Requires:       systemd
Requires:       logrotate
Requires:       sudo
Suggests:       monit
%{?systemd_requires}

%description
PrivateOn VPN is a robust VPN monitor/manager bundle

%prep
%setup -q -n privateon-vpn-%{version}

%build

%install
mkdir -p %{buildroot}
cp -a * %{buildroot}
%suse_update_desktop_file -r VPN Qt Network X-SuSE-Core-Internet

%pre
%service_add_pre vpnmonitor.service

%post
rm -f /opt/PrivateOn-VPN/monitrc
mkdir -p /etc/ld.so.conf.d
cat > /etc/ld.so.conf.d/PrivateOn.conf << EOF
EOF
echo "%{perl_archlib}/CORE" | sed 's/i586/x86_64/g' >> /etc/ld.so.conf.d/PrivateOn.conf
echo "%{perl_archlib}/CORE" | sed 's/x86_64/i586/g' >> /etc/ld.so.conf.d/PrivateOn.conf
/sbin/ldconfig
mkdir -p  /var/run/PrivateOn
cd /opt/PrivateOn-VPN/vpn-monitor/htdocs/errors/
for i in $(seq 400 415) ; do
    [ ! -L  err${i}.html ] && ln -s ../index.html err${i}.html
done
[ ! -L  /usr/sbin/rcvpnmonitor ] && ln -s /usr/sbin/service /usr/sbin/rcvpnmonitor
if which monit &>/dev/null ; then
    if [ -f /etc/monitrc ] ; then
       if [ -n "$(grep 'include.*/etc/monit.d/' /etc/monitrc | grep '^#')" ] ; then
           cp /etc/monitrc /etc/monitrc.orig
           echo "include /etc/monit.d/*" >> /etc/monitrc
           sed -i "/^#.*include.*\/etc\/monit.d\/.*$/d" /etc/monitrc
       fi
    else    
        cp -f /opt/PrivateOn-VPN/monitrc /etc/monitrc
    fi
fi
systemd-tmpfiles --create /usr/lib/tmpfiles.d/PrivateOn.conf >/dev/null 2>&1 || :
systemctl daemon-reload >/dev/null 2>&1 || :
systemctl enable vpnmonitor.service >/dev/null 2>&1 || :
systemctl start vpnmonitor.service >/dev/null 2>&1 || :
%service_add_post vpnmonitor.service
exit 0

%preun
# 0 - uninstallation
# 1 - upgrade
%service_del_preun vpnmonitor.service
if [ $1 -eq 0 ] ; then
    systemctl stop vpnmonitor.service >/dev/null 2>&1 || :
    systemctl disable vpnmonitor.service >/dev/null 2>&1 || :
    rm -f /usr/sbin/rcvpnmonitor
    rm -f /opt/PrivateOn-VPN/vpn-monitor/htdocs/errors/*.html
    rm -f /etc/ld.so.conf.d/PrivateOn
fi

exit 0

%postun
# 0 - uninstallation
# 1 - upgrade
%service_del_postun vpnmonitor.service
if [ $1 -eq 0 ] ; then
    systemctl daemon-reload >/dev/null 2>&1 || :
    /sbin/ldconfig
fi
exit 0

%files
%defattr(0644,root,root,-)
%dir /etc/monit.d
%config %attr(0600,root,root) /etc/monit.d/PrivateOn
%config /etc/sudoers.d/PrivateOn
%config /etc/logrotate.d/PrivateOn
/usr/lib/tmpfiles.d/PrivateOn.conf
/usr/share/applications/VPN.desktop
%_unitdir/vpnmonitor.service
%_mandir/man8/vpn_*.gz
%attr(0755,root,root) /opt/PrivateOn-VPN/vpn-gui/*.sh
%attr(0755,root,root) /opt/PrivateOn-VPN/vpn-gui/*.pl
%attr(0755,root,root) /opt/PrivateOn-VPN/vpn-monitor/*.sh
%attr(0755,root,root) /opt/PrivateOn-VPN/vpn-monitor/*.pl
/opt/PrivateOn-VPN

%doc

%changelog
