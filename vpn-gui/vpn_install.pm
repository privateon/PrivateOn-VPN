package vpn_install;

#
# PrivateOn-VPN -- Because privacy matters.
#
# Author: Mikko Rautiainen <info@tietosuojakone.fi>
#
# Copyright (C) 2014  PrivateOn / Tietosuojakone Oy, Helsinki, Finland
# All rights reserved. Use is subject to license terms.
#

use strict;
#use warnings;
use Getopt::Long;
$::DEBUG = 1;

sub import{
	no strict 'refs';
	foreach (@_) {
	*{"MainWindow::$_"}=\&$_;
	 }
}

my $configfile = "https://nordvpn.com/api/files/zip";
#my $configfile = "https://nordvpn.com/files/config.zip";
my %list = ();

sub get_latest_server_list
{
	system("/usr/bin/rm -fr /tmp/vpn_install/");
	system("/usr/bin/mkdir -p /tmp/vpn_install/");
	system("/usr/bin/wget --output-document=/tmp/vpn_install/config.zip $configfile");
	system("/usr/bin/unzip /tmp/vpn_install/config.zip -d /tmp/vpn_install/");

	# rename files
	system("cd /tmp/vpn_install/ && rename -v _nordvpn .nordvpn *.ovpn");
	system("cd /tmp/vpn_install/ && rename -v  _ - *.ovpn");
	system("cd /tmp/vpn_install/ && rename -v  _ - *.ovpn");
	system("cd /tmp/vpn_install/ && rename -v  _ - *.ovpn");
	system("sync")
#	system("rename -v _nordvpn .nordvpn /tmp/vpn_install/*.ovpn");
#	system("rename -v  _ - /tmp/vpn_install/*.ovpn");
#	system("rename -v  _ - /tmp/vpn_install/*.ovpn");
#	system("rename -v  _ - /tmp/vpn_install/*.ovpn");
}

sub add_one_connection
{
	my ($configfile, $ccode, $type, $username, $password) = @_;
	my $return_code = 0;
	my $uuid = `/usr/bin/uuidgen`;
	$uuid =~ s/\n$//;
	my $reconfig = 1;
	my $sysconnections = "/etc/NetworkManager/system-connections/";
	my $kind = "vpn";
	if ($configfile =~ /(double-(\w{2})|vpn|tor)-[a-z][a-z][a-z0-9]?\.nordvpn/) {
		$kind = $1;
	}
	if (-e $sysconnections."$kind-$ccode.nordvpn-$type") {
			open IN, $sysconnections."$kind-$ccode.nordvpn-$type" or $return_code = 1;
			while (<IN>) {
				if (/^uuid=(\S+)/) {
					$uuid = $1;
					last;
				} else {
					next;
				}
			}
			close IN;
	}

	if ($reconfig == 1) {
		open my $config, $configfile or return 2;
		if ($configfile =~ /(double-(\w{2})|vpn|tor)-$ccode.nordvpn-$type/) {
			my $kind = $1;
			my %params = ();
			open my $nmconfig, ">$sysconnections".$kind."-$ccode.nordvpn-$type" or $return_code = 1;
			$params{id} = "$kind-$ccode.nordvpn-$type";
			$params{uuid} = $uuid;
			$params{type} = "vpn";
			$params{service_type} = "org.freedesktop.NetworkManager.openvpn";
			$params{ta_dir} = "1";
			$params{connection_type} = "password";
			$params{password_flags} = "0";
			$params{password} = $password;
			$params{username} = $username;
			$params{tap_dev} = "no";
			$params{ca} = "/etc/ca-certificates/$kind-$ccode.nordvpn-$type.ca";
			$params{ta} = "/etc/ca-certificates/$kind-$ccode.nordvpn-$type.auth";
			my @contents = <$config>;
			my $content = join('', @contents);
			foreach my $line (@contents) {
			   if ($line =~ /^comp-lzo/) {
				   $params{comp_lzo} = "yes";
			   } elsif ($line =~ /^proto\s(tcp|udp)/) {
				   if ($1 eq "tcp") {
					   $params{proto_tcp} = "yes";
				   } else {
					   $params{proto_tcp} = "no";
				   }
			   } elsif ($line =~ /^mssfix/) {
				   $params{mssfix} = "yes";
			   } elsif ($line =~ /^tun-mtu\s([0-9]+)/) {
				   $params{tun_mtu} = $1;
			   } elsif ($line =~ /^cipher\s(\S+)/) {
				   $params{cipher} = $1;
			   } elsif ($line =~ /^remote\s([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\s([0-9]+)/ ) {
				   $params{remote} = $1;
				   $params{port} = $2;
			   }
			}
			if ($content =~ /<ca>(.*)<\/ca>/s) {
				open my $ca_file, ">$params{ca}" or $return_code = 1;
				print $ca_file $1."\n";
				close $ca_file;
			}
			if ($content =~ /<tls-auth>(.*)<\/tls-auth>/s) {
				open my $ta_file, ">$params{ta}" or $return_code = 1;
				print $ta_file $1."\n";
				close $ta_file;
			}

			print $nmconfig "[connection]\n";
			print $nmconfig "id=$params{id}\n";
			print $nmconfig "uuid=$params{uuid}\n";
			print $nmconfig "type=vpn\n";
			print $nmconfig "autoconnect=false\n";
			print $nmconfig "zone=\n";
			print $nmconfig "\n";
			print $nmconfig "[vpn]\n";
			print $nmconfig "service-type=$params{service_type}\n";
			print $nmconfig "ta-dir=$params{ta_dir}\n";
			print $nmconfig "connection-type=$params{connection_type}\n";
			print $nmconfig "password-flags=$params{password_flags}\n";
			print $nmconfig "remote=$params{remote}\n";
			print $nmconfig "cipher=$params{cipher}\n";
			print $nmconfig "comp-lzo=$params{comp_lzo}\n";
			print $nmconfig "proto-tcp=$params{proto_tcp}\n";
			print $nmconfig "tap-dev=$params{tap_dev}\n";
			print $nmconfig "tunnel-mtu=$params{tun_mtu}\n";
			print $nmconfig "port=$params{port}\n";
			print $nmconfig "mssfix=$params{mssfix}\n";
			print $nmconfig "username=$params{username}\n";
			print $nmconfig "ca=$params{ca}\n";
			print $nmconfig "ta=$params{ta}\n";
			print $nmconfig "\n";
			print $nmconfig "[vpn-secrets]\n";
			print $nmconfig "password=$params{password}\n";
			print $nmconfig "\n";
			print $nmconfig "[ipv6]\n";
			print $nmconfig "method=ignore\n";
			print $nmconfig "ip6-privacy=0\n";
			print $nmconfig "\n";
			print $nmconfig "[ipv4]\n";
			print $nmconfig "method=auto\n";
			print $nmconfig "may-fail=false\n";
			close $nmconfig;
			system("/usr/bin/chmod 600 $sysconnections$kind-$ccode.nordvpn-$type");
		}
		close $config;
	}

	return $return_code;
}

### helper functions
sub getCountryList
{
	my $return_code = get_latest_server_list();
	return undef if ($return_code != 0);
	opendir my $dir, "/tmp/vpn_install/" or return;
	my @tmplist = readdir $dir;
	closedir $dir;

	return \@tmplist;
}

sub add_connections 
{
	my ($username, $password) = @_;
	my $return_code = 0;

	my $filelist = getCountryList();
	return 2 if (not defined $filelist);

	system("/usr/bin/mkdir -p /etc/ca-certificates/");
	
	foreach my $file (@$filelist) {
		if ($file =~ /(double-(\w{2})|tor|vpn)-([a-z][a-z][a-z0-9]?)\.nordvpn-(tcp|udp)\.ovpn/i) {
			system("/usr/bin/cp /tmp/vpn_install/$file /etc/openvpn/");
			my $countrycode = $3;
			my $stype = $4;
			print STDERR "Adding $file\n" if $::DEBUG > 1;
			my $return_tmp = add_one_connection("/etc/openvpn/$file", $countrycode, $stype, $username, $password);
			if ($return_tmp > $return_code) { 
				$return_code = $return_tmp; 
			}
			$list{"/etc/openvpn/$file"} = 1;
		}
	}

	return $return_code;
}

1;
