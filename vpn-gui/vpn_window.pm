package vpn_window;

#
# PrivateOn-VPN -- Because privacy matters.
#
# Authors: Mikko Rautiainen & Lei Xue     <info@tietosuojakone.fi>
#
# Copyright (C) 2014-2015  PrivateOn / Tietosuojakone Oy, Helsinki, Finland
# All rights reserved. Use is subject to license terms.
#

use strict;
use warnings;
no warnings 'experimental::smartmatch';
use feature 'state';
use Socket;
use QtCore4;
use QtGui4;
use QtCore4::isa qw( Qt::MainWindow);
use QtCore4::slots
	closeEvent => ['Qt::CloseEvent'],
	reenableRefreshButton => [],
	setCountry => ['int'],
	setServerType => ['int'],
	setUserInfo => [],
	updateDefaultVpn => [],
	updateDefaultVpnResume => [],
	turnOffVpn => [],
	turnOffVpnResume => [],
	fixConnectionResume => [],
	updateStatus => [];
use File::Basename;
use File::Copy qw(copy);
use File::Path qw(make_path);
use IO::Interface::Simple;
use IO::Pty::Easy;
use Net::DBus qw(:typing);
use Try::Tiny;
use vpn_countries qw(getCountryCodes getCountryList);
use vpn_install qw(addConnections);
use vpn_ipc qw(getApiStatus getNetStatus getCripplingStatus getMonitorState takeABreak removeDispatcher disableMonitor enableMonitor undoCrippling forceRefresh);
#use QtCore4::debug qw(ambiguous);
#use Data::Dumper;

use constant {
	DISPATCH_FILE => "/etc/NetworkManager/dispatcher.d/vpn-up",
	INI_FILE => "/opt/PrivateOn-VPN/vpn-default.ini",
	DEBUG => 2,
	ENABLE_VPN => 1,
	ENABLE_DUAL_VPN => 1,
	ENABLE_TOR_VPN => 0
};

use constant {
	NET_UNPROTECTED => 0,
	NET_PROTECTED   => 1,
	NET_OFFLINE     => 2,
	NET_CRIPPLED    => 3,
	NET_BROKEN      => 4,
	NET_UNCONFIRMED => 5,
	NET_ERROR       => 99,
	NET_UNKNOWN     => 100	
};


################              Setup Window              ################
sub NEW {
	my ($class) = @_;
	$class->SUPER::NEW();
	this->{id_country} = 0;
	this->{country} = '';
	this->{id_serverType} = 0;
	this->{vpnType} = 'vpn';
	this->{protocol} = 'tcp';

	# update statut text timer
	this->{internalTimer} = Qt::Timer(this);  # create internal timer
	this->connect(this->{internalTimer}, SIGNAL('timeout()'), SLOT('updateStatus()'));
	this->{internalTimer}->start(5000);	  # emit signal every 5 second

	# button enable/disable timer
	this->{buttonTimer} = Qt::Timer(this);
	this->connect(this->{buttonTimer}, SIGNAL('timeout()'), SLOT('reenableRefreshButton()'));

	# Resume timer to continue processing after vpn disabled
	this->{resumeVpnTimer} = Qt::Timer(this);
	this->connect(this->{resumeVpnTimer}, SIGNAL('timeout()'), SLOT('updateDefaultVpnResume()'));

	# Resume timer to continue processing after displaying starting text
	this->{resumeTurnOffTimer} = Qt::Timer(this);
	this->connect(this->{resumeTurnOffTimer}, SIGNAL('timeout()'), SLOT('turnOffVpnResume()'));

	# Resume timer to continue processing after displaying starting text
	this->{resumeFixTimer} = Qt::Timer(this);
	this->connect(this->{resumeFixTimer}, SIGNAL('timeout()'), SLOT('fixConnectionResume()'));

	# initialize main widget and make it transparent
	my $centralWidget = Qt::Widget();
	setWindowFlags( Qt::Tool() | Qt::FramelessWindowHint() );
	setAttribute( Qt::WA_TranslucentBackground() );

	# get system default background color
	# note: in QT4 palette Constant QPalette::Midlight = value 3
	my $systemBackgroundColor = $centralWidget->style->standardPalette->color(3)->name;
	if (not defined $systemBackgroundColor) {
		# use opensuse 13.2 default if background color detection failed
		$systemBackgroundColor = "#e9e7e3";
	}
	print "\nsystemBackgroundColor = ".$systemBackgroundColor."\n" if DEBUG > 1;

	my $frameLayout = Qt::Frame( this, 0);
	$frameLayout->setGeometry( Qt::Rect( 0, 0, 280, 240 ) );
	$frameLayout->setStyleSheet("QFrame{background-color: " . $systemBackgroundColor . "; border-radius: 5px}");

	my $image = Qt::Label();
	$image->setPixmap(Qt::Pixmap(dirname($0).'/images/PrivateOn-logo.png'));

	this->{turnoffButton} = Qt::PushButton(this->tr('Turn off'));
	this->{refreshButton} = Qt::PushButton(this->tr('Refresh'));
	this->{userpassButton} = Qt::PushButton(this->tr('Servers')); 	# Update server list and user/password
	this->{turnoffButton}->setFont(Qt::Font("Times", 12, Qt::Font::Bold()));
	this->{refreshButton}->setFont(Qt::Font("Times", 12, Qt::Font::Bold()));
	this->{userpassButton}->setFont(Qt::Font("Times", 12, Qt::Font::Bold()));
	this->connect(this->{userpassButton}, SIGNAL "clicked()", this, SLOT "setUserInfo()");
	this->connect(this->{refreshButton}, SIGNAL "clicked()", this, SLOT 'updateDefaultVpn()');
	this->connect(this->{turnoffButton}, SIGNAL "clicked()", this, SLOT 'turnOffVpn()');

	my $status = Qt::TextEdit();
	$status->setReadOnly(1);
	$status->setMinimumHeight(75);
	$status->setMaximumHeight(75);
	this->{statusOutput} = $status;

	# show VPN/network/monitor status and retrieve api_status
	my $api_status = showNetStatus();
	if ($api_status == NET_UNCONFIRMED) {
		this->{internalTimer}->start(1000);
	}

	# set default values to be used if values not found in ini file 
	my $default_protocol = "tcp";
	if (-e INI_FILE) {
		open my $vpn_ini, "<", INI_FILE;
		while (my $line = <$vpn_ini>) {
			if ($line =~ /^id=(\S+)/) {
				my $id = $1;
				if ($id =~ /(double|tor|vpn)-([a-z][a-z][0-9]?|[a-z][a-z]\+[a-z][a-z][0-9]?)-(.*)-(tcp|udp)/i) {
					this->{vpnType} = $1;
					this->{country} = $2;
					this->{protocol} = $4;
					$default_protocol = $4;
					print "Read vpnType = $1\tccode = $2\tserverType = $4\n" if DEBUG > 1;
				}
				last;
			}
		}
	} else {
		my $status_text = "No previous configuration file.\n";
		setStatusText($status_text);
	}

	my $serverCountryLabel = Qt::Label(this->tr('Server Country: '));
	this->{serverCountryCombo} = Qt::ComboBox();
	this->{serverCountryCombo}->setMinimumContentsLength(16);
	this->{countrylist} = getComboboxCountries();
	this->connect(this->{serverCountryCombo}, SIGNAL 'activated(int)', this, SLOT 'setCountry(int)');

	my $serverTypeLabel = Qt::Label(this->tr('Server Type: '));
	my $serverTypeCombo = Qt::ComboBox();

	$serverTypeCombo->setMinimumContentsLength(16);
	$serverTypeCombo->addItem('TCP');
	$serverTypeCombo->addItem('UDP');

	if ($default_protocol eq "udp") {
		$serverTypeCombo->setCurrentIndex(1);
		this->{id_serverType} = 1;
	} else {
		$serverTypeCombo->setCurrentIndex(0);
		this->{id_serverType} = 0;
	}
	this->connect($serverTypeCombo, SIGNAL 'activated(int)', this, SLOT 'setServerType(int)');
	
	my $titleLayout = Qt::HBoxLayout();
	$titleLayout->addWidget($image);
	$titleLayout->addStretch(1);
	my $statusLayout = Qt::HBoxLayout();
	$statusLayout->addWidget($status);
	$statusLayout->addStretch(1);
	my $spacerLayout = Qt::HBoxLayout();
	my $spacer = Qt::SpacerItem(0, 20);
	$spacerLayout->addItem($spacer);
	my $vpnInfoLayout = Qt::HBoxLayout();
	$vpnInfoLayout->addSpacing(3);
	$vpnInfoLayout->addWidget($serverCountryLabel);
	$vpnInfoLayout->addWidget(this->{serverCountryCombo}, 1);
	$vpnInfoLayout->addStretch(1);
	my $vpnTypeLayout = Qt::HBoxLayout();
	$vpnTypeLayout->addSpacing(3);
	$vpnTypeLayout->addWidget($serverTypeLabel);
	$vpnTypeLayout->addSpacing(20);
	$vpnTypeLayout->addWidget($serverTypeCombo, 1);
	$vpnTypeLayout->addStretch(1);
	my $buttonLayout = Qt::HBoxLayout();
	$buttonLayout->addWidget(this->{turnoffButton});
	$buttonLayout->addSpacing(10);
	$buttonLayout->addWidget(this->{refreshButton});
	$buttonLayout->addSpacing(10);
	$buttonLayout->addWidget(this->{userpassButton});
	$buttonLayout->addStretch(1);
	
	my $verticalLayout = Qt::VBoxLayout( $frameLayout );
	$verticalLayout->setContentsMargins(11, 11, 11, 6);
	$verticalLayout->addLayout($titleLayout);
	$verticalLayout->addLayout($statusLayout);
	$verticalLayout->addLayout($spacerLayout);
	$verticalLayout->addLayout($vpnInfoLayout);
	$verticalLayout->addLayout($vpnTypeLayout);
	$verticalLayout->addLayout($buttonLayout);
	$centralWidget->setLayout($verticalLayout);
	this->setMinimumSize(Qt::Size(280, 240));
	this->setMaximumSize(Qt::Size(280, 240));

	setWindowTitle(this->tr('VPN Client'));
	this->setCentralWidget($centralWidget);

	my $pty;
	unless ($pty = IO::Pty::Easy->new) {
		my $status_text = "Could not create new pty.  Reason: " . $! . "\n";
		setStatusText($status_text);
		return(1);
	}
	this->{pty} = $pty;
}


################             QT events/slots            ################
sub moveEvent($$) {
	my ($event) = @_;
	this->move( (Qt::Application::desktop()->availableGeometry()->width() - this->width() - Qt::Application::desktop()->width()/28), (Qt::Application::desktop()->availableGeometry()->height() - this->height()) );
	$event->ignore();
}


sub closeEvent($$) {
	my ($event) = @_;
	this->hide();
	$event->ignore();
}


sub setCountry {
	my ($country) = @_;
	this->{id_country} = $country;
	print "country: ", $country."\n" if DEBUG > 0;
}


sub setServerType {
	my ($type) = @_;
	this->{id_serverType} = $type;
	print "type: ", $type."\n" if DEBUG > 0;
}


sub reenableRefreshButton {
	this->{refreshButton}->setEnabled(1);
	this->{buttonTimer}->stop();
}


################           Helper subroutines           ################
sub getConnections {
	my $object = Net::DBus->system
	    ->get_service("org.freedesktop.NetworkManager")
	        ->get_object("/org/freedesktop/NetworkManager/Settings",
	            "org.freedesktop.NetworkManager.Settings");

	return $object->ListConnections();
}


sub getVpnConnection {
	my ($connections) = @_;
	my @return_conns = ();

	foreach my $connection (@{$connections}) {
		my $object = Net::DBus->system
		    ->get_service("org.freedesktop.NetworkManager")
		        ->get_object($connection,
		            "org.freedesktop.NetworkManager.Settings.Connection");
		my $settings = $object->GetSettings();
		push(@return_conns, $settings) if ($settings->{connection}->{type} eq "vpn");
	}
	return \@return_conns;
}


sub isVpnActive {
	return </sys/devices/virtual/net/tun*> ? 1 : 0;
}


sub setStatusText {
	my ($status_text) = @_;

	my $status = this->{statusOutput};
	$status->setText($status_text);
	
	# move cursor to end
	my $cursor = $status->textCursor;
	$cursor->movePosition(Qt::TextCursor::End());
	$status->setTextCursor($cursor);
	$status->repaint();
}


sub showNetStatus {
	my $status_text;
	my $api_status = getApiStatus();

	if ($api_status == NET_UNCONFIRMED) {
		$status_text = "The VPN is up, but the network status is unconfirmed\n";
	}
	elsif ($api_status == NET_UNPROTECTED || $api_status == NET_PROTECTED) {
		$status_text = "The network is online\n";
	} elsif ($api_status == NET_CRIPPLED) {
		$status_text = "The network is in safemode\n";
	} else {
		$status_text = "The network is offline\n";
	}

	if ($api_status == NET_PROTECTED) {
		$status_text .= "The VPN is up\n";
		this->{turnoffButton}->setEnabled(1);
	} elsif ($api_status == NET_CRIPPLED) {
		$status_text .= "The VPN is down\n";
		this->{turnoffButton}->setEnabled(1);
	} else {
		$status_text .= "The VPN is down\n";
		this->{turnoffButton}->setEnabled(0);
	}

	my $current_state_string = getMonitorState();
	if ($current_state_string =~ /(\S+)-(\S+)-\S+/) {
		my $monitor = $1;
		my $task = $2;
		if ( $task eq "unknown") {
			$status_text .= "The monitor state is unknown\n";
			print "ERROR: getMonitorState returned unknown \"$current_state_string\" \n" if DEBUG > 0;
		} elsif ( $monitor eq "Enabled" ) {
			$status_text .= "The monitor is enabled\n";
		} elsif ( $monitor eq "Disabled" ) {
			$status_text .= "The monitor is disabled\n";
		} else {
			$status_text .= "The monitor state is unknown\n";
			print "ERROR: Could not parse monitor state. getMonitorState returned \"$current_state_string\" \n" if DEBUG > 0;
		}
	} else {
		$status_text .= "The monitor state is unknown\n";
		print "ERROR: Could not parse monitor state. getMonitorState returned \"$current_state_string\" \n" if DEBUG > 0;
	}

	print "$status_text.\n" if DEBUG > 0;
	setStatusText($status_text);

	# update button text and enabled/disabled
	setButtons($current_state_string);

	return($api_status);
}


sub setButtons {
	my ($current_state_string) = @_;

	my $monitor;
	my $task;
	my $network;

	if ($current_state_string =~ /(\S+)-(\S+)-(\S+)/) {
		$monitor = $1;
		$task = $2;
		$network = $3;
	} else {
		$monitor = "Unknown";
		$task = "unknown";
		$network = "UNKNOWN";
	}		
	
	# set turnoffButton and refreshButton
	if ( $network eq "PROTECTED" ) {
		this->{turnoffButton}->setText(this->tr('Turn off'));
		this->{turnoffButton}->setEnabled(1);
		this->{refreshButton}->setText(this->tr('Refresh'));
		this->{refreshButton}->setEnabled(1);
	} elsif ( $network eq "OFFLINE" ) {
		this->{turnoffButton}->setText(this->tr('Fix'));
		this->{turnoffButton}->setEnabled(1);
		this->{refreshButton}->setText(this->tr('Start'));
		this->{refreshButton}->setEnabled(0);
	} elsif ( $task eq "crippled" || $network eq "CRIPPLED" ) {
		this->{turnoffButton}->setText(this->tr('No VPN'));
		this->{turnoffButton}->setEnabled(1);
		this->{refreshButton}->setText(this->tr('VPN'));
		this->{refreshButton}->setEnabled(1);
	} elsif ( $network eq "BROKEN" || $network eq "ERROR" ) {
		this->{turnoffButton}->setText(this->tr('Wait'));
		this->{turnoffButton}->setEnabled(0);
		this->{refreshButton}->setText(this->tr('Start'));
		this->{refreshButton}->setEnabled(0);
	} elsif ( $monitor eq "Enabled" && $network ne "PROTECTED" ) {
		this->{turnoffButton}->setText(this->tr('Disable'));
		this->{turnoffButton}->setEnabled(1);
		this->{refreshButton}->setText(this->tr('Start'));
		this->{refreshButton}->setEnabled(1);
	} elsif ( $monitor eq "Disabled" ) {
		this->{turnoffButton}->setText(this->tr('Turn off'));
		this->{turnoffButton}->setEnabled(0);
		this->{refreshButton}->setText(this->tr('Start'));
		this->{refreshButton}->setEnabled(1);
	} else {
		this->{turnoffButton}->setText(this->tr('Turn-off'));
		this->{turnoffButton}->setEnabled(1);
		this->{refreshButton}->setText(this->tr('Start'));
		this->{refreshButton}->setEnabled(0);
	}
}


################              Country List              ################
sub getComboboxCountries {
	my $default_vpntype = this->{vpnType};
	my $default_ccode = this->{country};

	my %country_codes = getCountryCodes();
	my ($vpnlist, $duallist, $torlist) = getCountryList();
	my @country = ();
	my $i = 0;
	my $c;
	my $retval;
	my $a_start;
	my $a_end;
	my $a_text;
	my $b_start;
	my $b_end;
	my $b_text;

	# Vanilla VPN connections
	if (ENABLE_VPN) {
		foreach $c (sort {  $a_text = $a;
			   $a_text = $a_text eq 'usa' ? 'usa' : substr($a_text,0,2);
			   $b_text = $b;
			   $b_text = $b_text eq 'usa' ? 'usa' : substr($b_text,0,2);
			   $retval = $a_text eq $b_text ? $a cmp $b : $country_codes{$a_text} cmp $country_codes{$b_text};
			   $retval;
			} keys %$vpnlist) {
		if ($c =~ /([a-z][a-z])([0-9])/) {
			this->{serverCountryCombo}->addItem(substr($country_codes{$1},0,15) . " " . $2);
		} else {
			this->{serverCountryCombo}->addItem(substr($country_codes{$c},0,15));
		}
		if ($default_ccode eq $c) {
			if ($default_vpntype eq 'vpn') {
				this->{serverCountryCombo}->setCurrentIndex($i);
				this->{id_country} = $i;
			} else {
				$i++;
			}
		} else {
			$i++;
		}
		push @country, $c;
	}}

	# Dual VPN connections
	if (ENABLE_DUAL_VPN) {
		foreach $c (sort {  $a_text = $a;
			   $a_text = $a_text eq 'usa' ? 'usa' : substr($a_text,0,2);
			   $b_text = $b;
			   $b_text = $b_text eq 'usa' ? 'usa' : substr($b_text,0,2);
			   $retval = $a_text eq $b_text ? $a cmp $b : $country_codes{$a_text} cmp $country_codes{$b_text};
			   $retval;
			} keys %$duallist) {
		if ($c =~ /([a-z][a-z])\+([a-z][a-z])([0-9]?)/) {
			$a_text = substr($country_codes{$1},0,7) . " - " . substr($country_codes{$2},0,7) . " " . $3;
		} elsif ($c =~ /([a-z][a-z])\+([a-z][a-z])/) {
			$a_text = substr($country_codes{$1},0,7) . " - " . substr($country_codes{$2},0,7);
		} else {
			$a_text = $c;
		}
		this->{serverCountryCombo}->addItem($a_text);

		if ($default_ccode eq $c) {
			if ($default_vpntype eq 'double') {
				this->{serverCountryCombo}->setCurrentIndex($i);
				this->{id_country} = $i;
			} else {
				$i++;
			}
		} else {
			$i++;
		}
		# These can be distinguished by the '+' in the $c
		push @country, $c;
	}}

	if (ENABLE_TOR_VPN) {
		foreach $c (sort {  $a_text = $a;
			   $a_text = $a_text eq 'usa' ? 'usa' : substr($a_text,0,2);
			   $b_text = $b;
			   $b_text = $b_text eq 'usa' ? 'usa' : substr($b_text,0,2);
			   $retval = $a_text eq $b_text ? $a cmp $b : $country_codes{$a_text} cmp $country_codes{$b_text};
			   $retval;
			} keys %$torlist) {
		$a_text = "Tor : " . substr($country_codes{$c},0,10);
		this->{serverCountryCombo}->addItem($a_text);

		if ($default_ccode eq $c) {
			if ($default_vpntype eq 'tor') {
				this->{serverCountryCombo}->setCurrentIndex($i);
				this->{id_country} = $i;
			} else {
				$i++;
			}
		} else {
			$i++
		}
		push @country, ("tor_" . $c);
	}}
	if (DEBUG > 0) {
		print STDERR "getComboboxCountries returning " . scalar(@country) . " entries\n";
		print STDERR "Countries: " . join(", ", @country) . "\n";
	}
	return \@country;
}


################      Username/Password management      ################
sub setUserInfo {
	this->{userpassButton}->setEnabled(0);
	my $tmp = getUserInfo();
	my %userInfo = %$tmp;
	my $status_text;

	if ($userInfo{code} == 1) {
		$status_text = "Note: There are no VPN connection installed.\n";
		setStatusText($status_text);
		$userInfo{username} = "";
		$userInfo{password} = "";
	} elsif ($userInfo{code} == 2) {
		$status_text = "Note: Can not open your VPN connection files.\n";
		setStatusText($status_text);
		this->{userpassButton}->setEnabled(1);
		return $userInfo{code};
	}
	my ($ok, $password);
	my $username = Qt::InputDialog::getText(this, this->tr('Credentials'),
	   this->tr('VPN Username:'), Qt::LineEdit::Normal(), $userInfo{username}, $ok);
	if ($ok && $username) {
		this->{username} = $username;
		$password = Qt::InputDialog::getText(this, this->tr('Credentials'),
		this->tr('VPN Password:'), Qt::LineEdit::Password(),
		$userInfo{password}, $ok);
		if ($ok && $password) {
			this->{password} = $password;
		}
	}

	unless ($ok) {
		$status_text .= "Credentials entry aborted.\n";
		$status_text .= "Click Setup to change VPN credentials ";
		$status_text .= "and retrieve latest server list.";
		setStatusText($status_text);
		this->{userpassButton}->setEnabled(1);
		return 1;
	}
	
	my $ac_rc; # addConnections() return code
	if ($ok) {
		$ac_rc = addConnections($username, $password);
		if ($ac_rc == 0) {
			while (</etc/openvpn/*.ovpn>) {
				copy($_,$_ . '.bak');
				# TODO: what do we do after copying?
			}
		} else {
		my $original_file;
		if ($ac_rc == 1) {
			while (</etc/openvpn/*.bak>) {
				$original_file = substr($_, 0, -4); # remove trailing .bak
				if (!(-e $original_file)) {
					# copy only if file doesn't already exist
					rename($_, $original_file);
				}
			}
		}
		elsif ($ac_rc == 2) {
			while (</etc/openvpn/*.bak>) {
				$original_file = substr($_, 0, -4); # remove trailing .bak
				rename($_, $original_file);
			}
		}
		$status_text = "Note: Can not create all connections for you\n";
		setStatusText($status_text);
		this->{userpassButton}->setEnabled(1);
		return $userInfo{code};
		}
	}

	# reread country list
	this->{serverCountryCombo}->clear();
	this->{countrylist} = getComboboxCountries();

	# load new system connection into NetworkManager
	system("/sbin/service network force-reload");

	$status_text = "Successful to set the Username and password!\n";
	setStatusText($status_text);

	this->{userpassButton}->setEnabled(1);
	return 0;
}


sub getUserInfo {
	my %userInfo = ();
	$userInfo{code} = 0;
	my $country = this->{id_country};
	my $server = this->{id_serverType};
	my @countrylist = @{this->{countrylist}};
	if (not defined $country) {
		$country = 0;
	}
	if (not defined $server) {
		$server = 0;
	}

	my $ccode = $countrylist[$country];
	my $stype = $server == 0 ? "tcp" : "udp";
	my $system_connection_file = "";	

	# scan directory for matching files
	my @tmplist = glob("/etc/NetworkManager/system-connections/*-$ccode-*-$stype");
	foreach my $file (@tmplist) {
		# check file syntax, select first that matches
		if ($file =~ /(double|tor|vpn)-([a-z][a-z][0-9]?|[a-z][a-z]\+[a-z][a-z][0-9]?)-(.*)-(tcp|udp)/i) {
			$system_connection_file = $file;
			last;
		}
	}

	# if no file found
	if ($system_connection_file eq "") {
		print "glob files: @tmplist\n" if DEBUG > 0;
		print "ERROR: system-connection: \{TYPE\}-$ccode-\{COMMENT\}-$stype not found!\n" if DEBUG > 0;
		$userInfo{code} = 1; # there is empty connection file
		return \%userInfo;
	}

	open my $file, $system_connection_file or $userInfo{code} = 2;
	while (my $line = <$file>) {
		if ($line =~ /^username=(\S+)/) {
			$userInfo{username} = $1;
		}
		if ($line =~ /^password=(\S+)/) {
			$userInfo{password} = $1;
		}
	}
	close $file;
	return \%userInfo;
}


################     Refresh/Activate VPN connection    ################
sub updateDefaultVpn {

	this->{refreshButton}->setEnabled(0);
	this->{buttonTimer}->start(20000);

	takeABreak();
	removeDispatcher();

	my $status_text;

	undoCrippling() if (getCripplingStatus(DEBUG));

	my $api_status = getApiStatus();
	if ($api_status == NET_PROTECTED || $api_status == NET_UNCONFIRMED) { # i.e. vpn is up
		$status_text = "The VPN connection is deactivating,\n";
		$status_text .= "Please hold on.\n";
		setStatusText($status_text);
		print "VPN is active, deactivating...\n" if DEBUG > 0;

		# detect nmcli version
		my @active_lines;
		my $test_string = '/usr/bin/nmcli conn show --active';
		if (DEBUG > 0) {
			print STDERR "All active connections\n";
			$test_string = '/usr/bin/nmcli conn show --active';
		}
		if ( system($test_string) == 0 ) {
			# openSUSE 13.2 uses argument "conn show --active"
			@active_lines = `/usr/bin/nmcli conn show --active | /usr/bin/grep vpn`;
		} else {
			# openSUSE 13.1 uses argument "conn status" 
			@active_lines = `/usr/bin/nmcli conn status | /usr/bin/grep vpn`;
		}
		my @active_conns = ();
		foreach my $conn (@active_lines) {
			if ($conn =~ /(\S+)/) {
				push @active_conns, $1;
			}
		}
		
		# failover command if above gave no results
		if (!@active_conns) {
			@active_lines = `/usr/bin/nmcli conn`;
			foreach my $conn (@active_lines) {
				if ($conn =~ /(\S+)/) {
					push @active_conns, $1;
				}
			}
		}
	
		my $vpn_connection = getVpnConnection(getConnections());
		my $pty = this->{pty};
		foreach my $conn (@$vpn_connection) {
			my $vpn_name = $conn->{connection}->{id};
			if ($vpn_name ~~ @active_conns) {
				try {
					print "deactivating " . $vpn_name . "\n" if DEBUG > 0;
					$pty->spawn("/usr/bin/nmcli conn down id $vpn_name >/dev/null && echo \"VPN deactivation successful\"");
					# wait for connection to close
					sleep(1);
					for (my $i = 0; $i < 10; $i++) {
						if (!isVpnActive()) { last; }
						sleep 1;
					}
				} catch {
					warn "caught error: $_\n";
				};
			}
		}
	} elsif ($api_status == NET_CRIPPLED) {
		undoCrippling();
	}

	# return to QT event loop for 4 seconds
	print "Start resume vpn timer\n" if DEBUG > 0;
	this->{resumeVpnTimer}->start(2000);
}


sub updateDefaultVpnResume {
	system("pkill -9 openvpn");
	this->{resumeVpnTimer}->stop;
	print "Resume activation of VPN\n" if DEBUG > 0;
	my $status_text;

	my $countrylist = this->{countrylist};
	my $homedir = $ENV{HOME}.'/';
	my $configfiledir = "/etc/openvpn/";
	my $vpntype;
	my $comment;
	my $configfile;

	print "Country ID is " . this->{id_country} . "\n" if DEBUG > 0;
	print "Countrylist is " . join(", ", @{$countrylist}) . "\n" if DEBUG > 0;
	my $ccode = (defined($countrylist) && scalar(@$countrylist) > this->{id_country}) ? $countrylist->[this->{id_country}] : '';
	my $stype = this->{id_serverType} == 0 ? 'tcp' : 'udp';

	# scan directory for matching files
	my @tmplist = glob($configfiledir."*-$ccode-*-$stype.ovpn");
	foreach my $file (@tmplist) {
		# check file syntax, select first that matches
		if ($file =~ /(double|tor|vpn)-([a-z][a-z][0-9]?|[a-z][a-z]\+[a-z][a-z][0-9]?)-(.*)-(tcp|udp)\.ovpn/i) {
			$vpntype = $1;
			$ccode = $2;
			$comment = $3;
			$stype = $4;
			$configfile = $file;
			last;
		}
	}

	if ( defined($configfile) && $configfile ne '' ) {
		print "config file: $configfile\n" if DEBUG > 0;
	}else {
		print "glob files: @tmplist\n" if DEBUG > 0;
		print "ERROR: config file: \{TYPE\}-$ccode-\{COMMENT\}-$stype.ovpn not found!\n" if DEBUG > 0;
		$status_text = "Error: Configuration file not found!\n";
		$status_text .="Check that the selected server\n";
		$status_text .="supports protocol " . uc($stype) . ".\n";
		setStatusText($status_text);
		this->{internalTimer}->start(10*60*1000);
		forceRefresh();
		return;
	}


	my $pty = this->{pty};
	my $pid = $pty->pid();
	if ($pty->is_active and defined $pid) {
		system("/usr/bin/kill -9 $pid");
		$pty->close();
		$pty = IO::Pty::Easy->new();
		this->{pty} = $pty;
		print "Killed the previous subprocess, pid: ",$pid."\n" if DEBUG > 0;
	}
	print "ccode = $ccode\tstype = $stype\n" if DEBUG > 0;
	my $return_code = setDefaultVpn($configfile, $ccode, $comment, $stype, $vpntype);
	if ($return_code == 1) {
		$status_text = "There are no VPN connections!\n";
		$status_text .="Please click 'Servers'\n"; 
		$status_text .="to set your username/password\n"; 
		setStatusText($status_text);
		this->{internalTimer}->start(10*60*1000);
	} elsif ($return_code !=0) {
		$status_text = "Unexcepted Error.\n";
		setStatusText($status_text);
		this->{internalTimer}->start(10*60*1000);
	}else {
		$status_text = "The VPN connection will be activated,\n";
		$status_text .= "Please hold on.\n";
		setStatusText($status_text);
		this->{internalTimer}->start(5*1000);
	}
	enableMonitor();
	forceRefresh();
}


sub setDefaultVpn {
	my ($configfile, $ccode, $comment, $type, $vpntype) = @_;
	my $uuid = "";
	my $url = "none";
	my $remote = "";
	my $return_code = 0;
	my $pty = this->{pty};
	my $spawn_out;

	print STDERR "Setting default vpn: \$configfile = '$configfile', \$ccode = '$ccode', \$type = '$type', \$vpntype = '$vpntype'\n" if DEBUG > 0;

	my $sysconnections = "/etc/NetworkManager/system-connections/";
	my $id = $vpntype . "-" . $ccode . "-" . $comment . "-" . $type;
	if (-r $sysconnections . $id && -r '/etc/ca-certificates/' . $id . ".ca" && -r '/etc/ca-certificates/' . $id . ".auth") {
		unless (open IN, $sysconnections.$id) {
			my $status_text = "Could not open VPN config file for reading. Reason: " . $! . "\n";
			setStatusText($status_text);
			return(1);
		}
		while (<IN>) {
			if (/^uuid=(\S+)/) {
				$uuid = $1;
			} elsif (/^remote=(\S+)/) {
				$remote = $1;
			} else {
				next;
			}
		}
		close IN;
		try {
			$pty->spawn("/usr/bin/nmcli conn up uuid $uuid >/dev/null && echo \"VPN activation successful\"");
		} catch {
			warn "caught error: $_\n";
			$return_code = 2;
		};
	} else {
		my $status = this->{statusOutput};
		my $status_text = $status->toPlainText();
		$status_text .= "No system connection file found.\n";
		this->{statusOutput} = $status;
		return 1;
	}
	if ($uuid eq "") {
		$return_code = 1;
	}
	if ($return_code != 0) {
		return $return_code;
	}

	# read API check URL from ini file
	my $vpn_ini;
	open $vpn_ini, "<", INI_FILE;
	while (my $line = <$vpn_ini>) {
		if ($line =~ /^url\s*=\s*(.*)\s*/) {
			$url = $1;
			last;
		}
	}
	close $vpn_ini;

	# write ini file
	unless (open $vpn_ini, ">", INI_FILE) {
		my $status_text = "Could not create '" . INI_FILE . "'  Reason: " . $! . "\n";
		setStatusText($status_text);
		return(1);
	}
	print $vpn_ini "[default-vpn]\n";
	print $vpn_ini "id=$id\n";
	print $vpn_ini "uuid=$uuid\n";
	print $vpn_ini "remote=$remote\n";
	print $vpn_ini "url=$url\n";
	print $vpn_ini "monitor=enabled\n";
	close $vpn_ini;

	### setup dispatcher file
	my $vpn_d;
	unless (open $vpn_d, ">", DISPATCH_FILE) {
		my $status_text = "Could not create '" . DISPATCH_FILE . "'  Reason: " . $! . "\n";
		setStatusText($status_text);
		return(1);
	}
	print $vpn_d "#!/bin/sh\n";
	print $vpn_d "#$ccode-$type\n";
	print $vpn_d "ESSID=\"$uuid\"\n";
	print $vpn_d "\n";
	print $vpn_d "interface=\$1 status=\$2\n";
	print $vpn_d "case \$status in\n";
	print $vpn_d "  up|vpn-down)\n";
	print $vpn_d "	sleep 3 && /usr/bin/nmcli con up uuid \"\$ESSID\" &\n";
	print $vpn_d "	;;\n";
	print $vpn_d "esac\n";
	close $vpn_d;
	system("/usr/bin/chmod 755 ".DISPATCH_FILE);
	return 0;
}


################     Deactivate VPN / Fix connection    ################
sub turnOffVpn {

	# network status = PROTECTED or monitor = Disabled
	if (this->{turnoffButton}->text eq "Turn off") {
		# continue to rest of subroutines

	# network status = UNPROTECTED and monitor = Enabled
	} elsif (this->{turnoffButton}->text eq "Disable") {
		removeDispatcher();
		disableMonitor();
		setStatusText("Monitor disabled.\n");
		this->{turnoffButton}->setEnabled(0);
		return 0;

	# network status = CRIPPLED
	} elsif (this->{turnoffButton}->text eq "No VPN") {
		removeDispatcher();
		disableMonitor();
		undoCrippling();
		setStatusText("Safemode deactivated.\n");
		this->{turnoffButton}->setEnabled(0);
		return 0;

	# network status = OFFLINE
	} elsif (this->{turnoffButton}->text eq "Fix") {
		fixConnection();
		return 0;

	# error cases
	} else {
		# disable NetworkManager to force restart
		system("/usr/sbin/service NetworkManager stop >/dev/null 2>&1");
		fixConnection();
		return 0;
	}

	my $status_text = "The VPN connection is deactivating,\n";
	$status_text .= "Please hold on.\n";

	takeABreak();
	removeDispatcher();
	disableMonitor();

	if (getCripplingStatus(DEBUG)) {
		undoCrippling();
		$status_text = "The VPN connection is deactivated.\n";
		setStatusText($status_text);
		return 0;
	}

	# detect nmcli version
	my @active_lines;
	my $test_string = '/usr/bin/nmcli conn show --active';
	if (DEBUG > 0) {
		print STDERR "All active connections\n";
		$test_string = '/usr/bin/nmcli conn show --active';
	}
	if ( system($test_string) == 0 ) {
		# openSUSE 13.2 uses argument "conn show --active"
		@active_lines = `/usr/bin/nmcli conn show --active | /usr/bin/grep vpn`;
	} else {
		# openSUSE 13.1 uses argument "conn status" 
		@active_lines = `/usr/bin/nmcli conn status | /usr/bin/grep vpn`;
	}
	my @active_conns = ();
	foreach my $conn (@active_lines) {
		if ($conn =~ /(\S+)/) {
			push @active_conns, $1;
		}
	}

	# save list for use after resume
	if (@active_conns) {
		this->{active_conns} = \@active_conns;
	} else {
		if (defined this->{active_conns}) { undef this->{active_conns} };
		$status_text = "Forcing VPN deactivation,\n";
		$status_text .= "This may take a few seconds.\n";
	}

	setStatusText($status_text);
	this->{turnoffButton}->setEnabled(0);

	# return to QT event loop for 0.5 seconds
	print "Start resume deactivating VPN timer\n" if DEBUG > 0;
	this->{resumeTurnOffTimer}->start(500);
}


sub turnOffVpnResume {
	this->{resumeTurnOffTimer}->stop;
	print "Resume deactivating VPN\n" if DEBUG > 0;

	my $pty = this->{pty};
	my @active_conns = ();
	my $failover_mode = 0;
	if ( (defined this->{active_conns}) && (ref(this->{active_conns}) eq 'ARRAY') ) {
		@active_conns = @{this->{active_conns}};
		undef this->{active_conns};
	} else {
		$failover_mode = 1;
	}

	my $vpn_connection = getVpnConnection(getConnections());
	foreach my $conn (@$vpn_connection) {
		my $vpn_name = $conn->{connection}->{id};
		if ( $failover_mode  || ($vpn_name ~~ @active_conns) ) {
			try {
				print "deactivating " . $vpn_name . "\n" if DEBUG > 0;
				if (!$failover_mode) {
					$pty->spawn("/usr/bin/nmcli conn down id $vpn_name >/dev/null && echo \"VPN deactivation successful\"");

					# wait for connection to close
					for (my $i = 0; $i < 10; $i++) {
						sleep 1;
						if (!isVpnActive()) { last; }
					}
				} else {
					# Don't collect the error output since failover mode produces a lot of it
					$pty->spawn("/usr/bin/nmcli conn down id $vpn_name >/dev/null 2>&1 && echo \"$vpn_name deactivated\"");

					# wait up to 4 sec for connection to be brought down
					for (my $i = 0; $i < 4; $i++) {
						sleep(1);
						unless ($pty->is_active) { last; }
					}

					# restart pty if it is still active
					if ($pty->is_active) {
						$pty->close();
						$pty = IO::Pty::Easy->new();
						this->{pty} = $pty;
					}
				}
			} catch {
				warn "caught error: $_\n";
			};
		}
	}
	system("pkill -9 openvpn");
	forceRefresh();
	this->{internalTimer}->start(5*1000);

	if ($failover_mode) {
		my $status = this->{statusOutput};
		my $status_text = $status->toPlainText();
		$status_text = "The VPN connection is deactivated.\n";
		setStatusText($status_text);
	}
	
	return 0;
}


sub fixConnection {
	my $status_text = "Fixing network connection\n";

	# restart NetworkManager if not running
	if ( system("/usr/sbin/service NetworkManager status >/dev/null 2>&1") ) {
		system("/usr/sbin/service NetworkManager stop >/dev/null 2>&1");
		system("/usr/sbin/service NetworkManager start >/dev/null 2>&1");
		sleep(1);
		if ( system("/usr/sbin/service NetworkManager status >/dev/null 2>&1") ) {
			$status_text .= "NetworkManager restart failed\n";
		} else {
			$status_text .= "NetworkManager restarted\n";
		}
	}
	setStatusText($status_text);
	this->{turnoffButton}->setEnabled(0);

	# return to QT event loop for 0.5 seconds
	print "Start resume fix timer\n" if DEBUG > 0;
	this->{resumeFixTimer}->start(500);
}


sub fixConnectionResume {
	this->{resumeFixTimer}->stop;
	print "Resume fixing of connection\n" if DEBUG > 0;

	my $pty = this->{pty};
	my $status = this->{statusOutput};
	my $status_text = $status->toPlainText();

	# find non-virtual network interfaces
	my $sys_net_path = "/sys/class/net/";
	my $net;
	my @interface_array;
	unless (opendir $net, $sys_net_path) {
		print "ERROR: Could not open directory: " . $sys_net_path . " Reason: " . $!;
	} else {
		while (my $file = readdir($net)) {
			next unless (-d $sys_net_path."/".$file);
			# make readlink errors nonfatal
			eval {
				my $value = readlink($sys_net_path."/".$file);
				if (defined($value) && $value =~ /pci/i) {
					# directory is read in reverse order, so push to beginning of array
					unshift(@interface_array, $file);
				}
			};
		}
		closedir $net;
	}

	# if no interfaces found, use default list
	if ( scalar(@interface_array) == 0 ) {
		$interface_array[0] = "enp1s0";
		$interface_array[1] = "wlp2s0";
		$status_text .= "No interfaces found, using default list\n";
		setStatusText($status_text);
	}

	foreach my $interface (@interface_array) {
		try {
			$pty->spawn("echo \"Bringing up interface $interface\" ; " .
			   "/usr/bin/nmcli conn up ifname $interface >/dev/null && " .
			   "echo \"IP address assigned to $interface\"");

			# wait up to 15 sec for connection to be brought up
			for (my $i = 0; $i < 15; $i++) {
				sleep(1);
				unless ($pty->is_active) { last; }
				print " (fix)" if DEBUG > 1;
			}

			my $pid = $pty->pid();
			if ($pty->is_active && defined $pid) {
				# write pty to status area before continuing
				updateStatus();
				system("/usr/bin/kill -9 $pid");
				$pty->close();
				$pty = IO::Pty::Easy->new();
				this->{pty} = $pty;
				$status_text .= "Interface $interface timed out\n";
				setStatusText($status_text);
				print "\nInterface $interface timed out. Killed the previous subprocess, pid: ",$pid."\n" if DEBUG > 0;
			}
			
			# end loop if interface has an IP address
			my $if = IO::Interface::Simple->new($interface);
			if ( defined($if) && defined($if->address) ) {
				if ( $if->address =~ /\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/ ) {
					print "\nInterface $interface fixed. Has IP address " . $if->address . "\n" if DEBUG > 0;
					last;
				}
			}
			print "Interface $interface did not get a valid IP address\n" if DEBUG > 1;
		} catch {
			warn "caught error: $_\n";
		};
	}

	return 0;
}


################                Main Loop               ################
sub updateStatus {
	my $status = this->{statusOutput};
	my $status_text = $status->toPlainText();
	my $status_text_changed = 0;
	my $pty = this->{pty};
	my $active_flag = $pty->is_active();

	# initialize persistent variables
	state $previous_status = 100;
	state $last_pty_read = 4102444800000; 	# epoch year 2100
	state $previous_state_string = "";
	state $last_state_read = 0; 		# epoch year 1970

	while ( my $output = $pty->read(0) ) {
		$status_text .= $output;
		$status_text_changed = 1;
		$active_flag = 1;
	}

	my $current_time = time();
	if ($active_flag) {
		this->{internalTimer}->start(1000);
		$last_pty_read = $current_time;
		print "#" if DEBUG > 1;
	} else {
		if ( $current_time - $last_pty_read > 2*60 ) { # keep text for 2 min
			my $api_status = showNetStatus();
			if ($api_status == NET_PROTECTED) {
				this->{internalTimer}->start(5*60*1000);
			} else {
				this->{internalTimer}->start(60*1000);
			}
			return;
		} elsif ( $current_time - $last_pty_read > 30 ) { # slow down refresh after 30 seconds
			this->{internalTimer}->start(5*1000);
		} elsif ( $current_time - $last_pty_read > 60 ) { # slow down refresh even more after 1 minute
			this->{internalTimer}->start(10*1000);
		}
		print "." if DEBUG > 1;
	}

	my $current_status = getNetStatus();
	my $tmp_previous = $previous_status;
	$previous_status = $current_status;

	if ($current_status != $tmp_previous) {
		forceRefresh();

		if ($current_status == NET_OFFLINE && $tmp_previous != NET_OFFLINE && $tmp_previous != NET_UNKNOWN) {
			$status_text .= "Network offline, please wait.\n";
			$status_text_changed = 1;
		} elsif ($current_status == NET_BROKEN && $tmp_previous != NET_BROKEN) {
			$status_text .= "Network broken, check system.\n";
			$status_text_changed = 1;
		} elsif ($current_status == NET_ERROR && $tmp_previous != NET_ERROR) {
			$status_text .= "Monitor is offline, please wait.\n";
			$status_text_changed = 1;
		} elsif ($current_status == NET_UNKNOWN && $tmp_previous != NET_UNKNOWN) {
			$status_text .= "Network changed to unknown state.\n";
			$status_text_changed = 1;
		} elsif ($current_status == NET_CRIPPLED && $tmp_previous != NET_CRIPPLED) {
			this->{userpassButton}->setEnabled(0);
			$status_text .= "Network placed in safemode, check VPN settings.\n";
			$status_text_changed = 1;
		} elsif ($current_status == NET_UNCONFIRMED && $tmp_previous != NET_UNCONFIRMED) {
			$status_text .= "Network status is unconfirmed, please wait for status update.\n";
			$status_text_changed = 1;
		} elsif ($current_status == NET_PROTECTED && $tmp_previous != NET_PROTECTED) {
			this->{refreshButton}->setEnabled(1);
			this->{buttonTimer}->stop();
			this->{turnoffButton}->setEnabled(1);
		}

		if ($current_status != NET_CRIPPLED && $tmp_previous == NET_CRIPPLED) {
			this->{userpassButton}->setEnabled(1);
			$status_text .= "Network restored from safemode.\n";
			$status_text_changed = 1;
		} elsif ( ($current_status != NET_OFFLINE || $current_status != NET_BROKEN || $current_status != NET_ERROR || $current_status != NET_UNKNOWN) 
		   && ($tmp_previous == NET_BROKEN) ) {
			# note: no recovered-text for NET_UNKNOWN, since GUI starts with UNKNOWN state
			if ($current_status == NET_PROTECTED) {
				$status_text .= "Recovered to protected mode.\n";
				$status_text_changed = 1;
			} elsif ($current_status == NET_UNPROTECTED) {
				$status_text .= "Recovered to unprotected mode.\n";
				$status_text_changed = 1;
			}
		} elsif ( ($current_status != NET_OFFLINE || $current_status != NET_BROKEN || $current_status != NET_ERROR || $current_status != NET_UNKNOWN) 
		   && ($tmp_previous == NET_ERROR) ) {
			if ($current_status == NET_PROTECTED) {
				$status_text .= "Monitor recovered, VPN is up.\n";
				$status_text_changed = 1;
			} elsif ($current_status == NET_UNPROTECTED) {
				$status_text .= "Monitor recovered, VPN is down.\n";
				$status_text_changed = 1;
			}
		} elsif ( ($current_status != NET_OFFLINE || $current_status != NET_BROKEN || $current_status != NET_ERROR || $current_status != NET_UNKNOWN) 
		   && ($tmp_previous == NET_OFFLINE) ) {
			if ($current_status == NET_PROTECTED) {
				$status_text .= "Network connection recovered\nThe VPN is up\n";
				$status_text_changed = 1;
			} elsif ($current_status == NET_UNPROTECTED) {
				$status_text .= "Network connection recovered\nThe VPN is down\n";
				$status_text_changed = 1;
			} elsif ($current_status == NET_UNCONFIRMED) {
				$status_text .= "Network connection recovered\nThe network status is still unconfirmed\n";
				$status_text_changed = 1;
			}
		}
	}

	# progress indicator dots
	if ($status_text =~ /please\shold\son/i) {
		# add progress indicator dots if last line of status text is 'Please hold on'
		if ($status_text =~ /please\shold\son[.]?[\r]?[\n]?[.]*$/i) {
			unless ($status_text =~ /please\shold\son[.]?[\r]?[\n]?$/i) {
				chomp $status_text;
			}
			$status_text .= ".\n";
			$status_text_changed = 1;
		} else {
		# since the task is completed, remove dots and lines before the dots
			$status_text =~ s/.*[\r]?[\n]?.*please\shold\son[.]?[\r]?[\n]?[.]*[\r]?[\n]?//i;
			$status_text_changed = 1;
		}
	}

	if ($status_text_changed) {
		setStatusText($status_text);
	}

	# if network status has changed OR at least 10 seconds have passed, update button text and enabled/disabled
	if ( ($current_status != $tmp_previous) || ($current_time - $last_state_read >= 10) ) {
		my $current_state_string = getMonitorState();
		if ($current_state_string ne $previous_state_string) {
			setButtons($current_state_string);
			$previous_state_string = $current_state_string;
			$last_state_read = $current_time;
		}
	}
}

1;
