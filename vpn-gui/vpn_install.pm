package vpn_install;

#
# PrivateOn-VPN -- Because privacy matters.
#
# Author: Mikko Rautiainen <info@tietosuojakone.fi>
#
# Copyright (C) 2014-2015  PrivateOn / Tietosuojakone Oy, Helsinki, Finland
# All rights reserved. Use is subject to license terms.
#

use strict;
use warnings;
use File::Copy qw(copy);
use File::Basename qw(basename dirname);
use File::Path qw(make_path);
use Getopt::Long;

sub import{
	no strict 'refs';
	foreach (@_) {
	   *{"vpn_window::$_"}=\&$_;
	 }
}

use constant {
        CONFIG_URL   => "http://www.tietosuojakone.fi/openvpn/serverlist-current.zip",
	INI_FILE     => "/etc/PrivateOn/vpn-default.ini",
	URL_FILE     => "Check-VPN-status-API.url",
	TMP_PATH     => "/tmp/vpn_install/",
	CUSTOMIZE    => 0,
	DEBUG        => 1
};


sub getLatestServerList
{
	if (CUSTOMIZE == 1) {
		system("/usr/bin/mkdir -p " . TMP_PATH);
		return 0;
	}

	system("/usr/bin/rm -fr " . TMP_PATH);
	system("/usr/bin/mkdir -p " . TMP_PATH);
	system("/usr/bin/wget --output-document=" . TMP_PATH . "serverlist.zip " . CONFIG_URL);
	system("/usr/bin/unzip " . TMP_PATH . "serverlist.zip -d " . TMP_PATH);
	system("sync");

	writeUrlToIniFile();

	return 0;
}


sub addOneConnection
{
	my ($configfile, $kind, $ccode, $comment, $type, $username, $password) = @_;
	my $return_code = 0;
	my $sysconnections = "/etc/NetworkManager/system-connections/";

	# Generate UUID
	my $uuid = `/usr/bin/uuidgen`;
	$uuid =~ s/\n$//;

	# Reuse old UUID if found
	if (-e $sysconnections."$kind-$ccode-$comment-$type") {
			open IN, $sysconnections."$kind-$ccode-$comment-$type" or $return_code = 1;
			while (<IN>) {
				if (/^uuid=(\S+)/) {
					$uuid = $1;
					print STDERR "     Reusing UUID $uuid\n" if DEBUG > 0;
					last;
				} else {
					next;
				}
			}
			close IN;
	}

	# Read openVPN file
	open my $config, $configfile or return 2;
	my %params = ();
	$params{id} = "$kind-$ccode-$comment-$type";
	$params{uuid} = $uuid;
	$params{type} = "vpn";
	$params{service_type} = "org.freedesktop.NetworkManager.openvpn";
	$params{ta_dir} = "1";
	$params{connection_type} = "password";
	$params{password_flags} = "0";
	$params{password} = $password;
	$params{username} = $username;
	$params{tap_dev} = "no";
	$params{ca} = "/etc/ca-certificates/$kind-$ccode-$comment-$type.ca";
	$params{ta} = "/etc/ca-certificates/$kind-$ccode-$comment-$type.auth";
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
	close $config;

	# Write ca file
	if ($content =~ /<ca>(.*)<\/ca>/s) {
		open my $ca_file, ">$params{ca}" or $return_code = 1;
		print $ca_file $1."\n";
		close $ca_file;
	}

	# Write auth file
 	if ($content =~ /<tls-auth>(.*)<\/tls-auth>/s) {
		open my $ta_file, ">$params{ta}" or $return_code = 1;
		print $ta_file $1."\n";
		close $ta_file;
	}

	# write NM system connection file
	open my $nmconfig, ">$sysconnections".$kind."-$ccode-$comment-$type" or $return_code = 1;
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
	system("/usr/bin/chmod 600 $sysconnections$kind-$ccode-$comment-$type");

	return $return_code;
}


### helper functions
sub writeUrlToIniFile
{
	my $url = 'none';
	if (-e TMP_PATH . URL_FILE) {
		print STDERR "Url file " . TMP_PATH . URL_FILE . " found\n" if DEBUG > 0;
		if (open(my $fh, '<:encoding(UTF-8)', TMP_PATH . URL_FILE)) {
			$url = <$fh>;
			chomp $url;
		} else {
			print STDERR "Could not open file " . TMP_PATH . URL_FILE . " Reason: " . $! . "\n";
			print STDERR "Updating url='none' to INI file.\n\n" if DEBUG > 0;
		}
	} else {
		print STDERR "Url file " . TMP_PATH . URL_FILE . " not found\n" if DEBUG > 0;
		print STDERR "Updating url='none' to INI file.\n\n" if DEBUG > 0;
	}

	# read ini file if it exists
	my $vpn_ini;
	my @vpn_ini_lines;
	if (open $vpn_ini, "<" . INI_FILE) {
		my @vpn_ini_lines = <$vpn_ini>;
		close $vpn_ini;
	} else {
		my $error = $!;
		if ( -e INI_FILE ) {
			print STDERR "Could not open " . INI_FILE . " for reading.  Reason: " . $error . "\n";
			print STDERR "Deleting old ini file.\n";
			unlink(INI_FILE);
		} else {
			print STDERR "Creating new ini file " . INI_FILE . "\n";
		}
		# make directory in case it is missing
		my $config_path = dirname(INI_FILE);
		unless ( -d $config_path ) {
			eval { make_path($config_path); };
		}
	}

	# update ini
	unless (open VPN_INI, ">" . INI_FILE) {
		print STDERR "Unable to open " . INI_FILE . " for writing. Reason: " . $! . "\n";
		return 1;
	}
	my $has_been_written = 0;
	foreach my $line (@vpn_ini_lines) {
		if ($line =~ /url/) {
			if ($has_been_written == 0) {
				print VPN_INI "url=$url\n";
				$has_been_written = 1;
			}
		} elsif ($line =~ /monitor/) {
			if ($has_been_written == 0) {
				print VPN_INI "url=$url\n";
				$has_been_written = 1;
			}
			print VPN_INI $line;
		} else {
			print VPN_INI $line;
		}
	}
	if ($has_been_written == 0) {
		print VPN_INI "url=$url\n";
	}
	close VPN_INI;

	print STDERR "Wrote $url to ini file.\n" if DEBUG > 0;

	return 0;
}


sub getCountryList
{
	my $return_code = getLatestServerList();
	return undef if ($return_code != 0);
	opendir my $dir, TMP_PATH or return;
	my @tmplist = readdir $dir;
	closedir $dir;

	return \@tmplist;
}


sub addConnections 
{
	my ($username, $password) = @_;
	my $return_code = 0;

	my $filelist = getCountryList();
	if (defined $filelist) {
		print STDERR "Filelist populated\n" if DEBUG > 0;
	} else {
		print STDERR "Filelist empty - exiting install\n" if DEBUG > 0;
		return 2
	} 
	system("/usr/bin/mkdir -p /etc/ca-certificates/");
	
	my $vpn_count = 0;
	foreach my $file (@$filelist) {
		if ($file =~ /(double|tor|vpn)-([a-z][a-z][0-9]?|[a-z][a-z]\+[a-z][a-z][0-9]?)-(.*)-(tcp|udp)\.ovpn/i) {
			system("/usr/bin/cp " . TMP_PATH . "$file /etc/openvpn/");
			my $kind = $1;
			my $countrycode = $2;
			my $comment = $3;
			my $stype = $4;
			print STDERR "Adding $file\n" if DEBUG > 0;
			my $return_tmp = addOneConnection("/etc/openvpn/$file", $kind, $countrycode, $comment, $stype, $username, $password);
			if ($return_tmp > $return_code) { 
				$return_code = $return_tmp; 
			}
			$vpn_count++;
		}
	}

	if ($vpn_count == 0) {
		print STDERR "No openVPN files found with the correct name scheme.\n" if DEBUG > 0;
		print STDERR "Check filenames in directory " . TMP_PATH . "\n" if DEBUG > 0;
		return 2
	} 

	return $return_code;
}

sub backupConnections {
	my @pathes = ('/etc/openvpn', '/etc/NetworkManger/system-connections');
	for my $path (@pathes) {
		my $path = shift;
		my $backup_path = $path . '/backup';
		if (-d $backup_path) {
			for my $file (glob($backup_path . '/*')) {
				unlink($file) if -e $file;
			}
		} else {
			make_path($backup_path);
		}
		for my $file (glob($path . '/*')) {
			my $filename = basename($file);
			if ($filename =~ /^(double|tor|vpn)/i) {
				my $bakfile = $backup_path . '/' . $filename . '.bak';
				copy($file, $bakfile);
			}
		}
	}
}

sub restoreConnections {
	my type = shift; # $type can be set to "all" or "missing"
	my @pathes = ('/etc/openvpn', '/etc/NetworkManger/system-connections');
	for my $path (@pathes) {
		my $backup_path = $path . '/backup';
		for my $bakfile (glob($backup_path . '/*.bak')) {
			my $bakfilename = basename($bakfile);
			my $filename = substr($bakfilename, 0, -4); # remove trailing .bak
			if ($filename =~ /^(double|tor|vpn)/i) {
				my $file = $path . '/' . $filename;
				if (-e $file) {
					next if $type eq "missing";
					unlink($file);
				}
				copy($bakfile, $file);
			}
		}
	}
}

1;
