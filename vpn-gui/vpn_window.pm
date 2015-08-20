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
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Path qw(make_path);
use IO::Interface::Simple;
use IO::Pty::Easy;
use Net::DBus qw(:typing);
use Try::Tiny;
use vpn_countries qw(getCountryCodes getCountryList);
use vpn_install qw(addConnections backupConnections restoreConnections);
use vpn_ipc qw(getApiStatus getNetStatus getCripplingStatus getMonitorState 
		takeABreak resumeIdling forceRefresh undoCrippling
		removeDispatcher writeDispatcher removeRoute rereadConfig
		disableMonitor enableMonitor); 
use vpn_network qw(getVpnConnection isVpnActive
		isNetworkManagerEnabled explainNetworkManagerProblem);

use constant {
	DISPATCH_FILE   => "/etc/NetworkManager/dispatcher.d/vpn-up",
	INI_FILE        => "/etc/PrivateOn/vpn-default.ini",
	DEBUG           => 0,
	ENABLE_VPN      => 1,
	ENABLE_DUAL_VPN => 1,
	ENABLE_TOR_VPN  => 0
};

use constant {
	NET_UNPROTECTED	=> 1,
	NET_PROTECTED	=> 2,
	NET_NEGATIVE	=> 3,
	NET_CONFIRMING	=> 4,
	NET_UNCONFIRMED	=> 5,
	NET_CRIPPLED	=> 6,
	NET_OFFLINE     => 7,
	NET_BROKEN	=> 8,
	NET_ERROR	=> 9,
	NET_UNKNOWN	=> 10
};

use constant {
	API_CHECK_TIMEOUT       => 10
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
	this->{updateStatusMode} = 'normal';

	# update status text timer
	this->{internalTimer} = Qt::Timer(this);  # create internal timer
	this->connect(this->{internalTimer}, SIGNAL('timeout()'), SLOT('updateStatus()'));

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
	this->findIconPath();
	$image->setPixmap(Qt::Pixmap(this->{iconPath} . 'PrivateOn-logo.png'));

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
	my $status_text;
	my $status_text_changed = 0;

	# set default values to be used if values not found in ini file 
	my $default_protocol = "udp";
	if (-e INI_FILE) {
		open my $vpn_ini, "<", INI_FILE;
		while (my $line = <$vpn_ini>) {
			if ($line =~ /^id=(\S+)/) {
				my $id = $1;
				if ($id =~ /(double|tor|vpn)-([a-z][a-z][0-9]*|[a-z][a-z]\+[a-z][a-z][0-9]?)-(.*)-(tcp|udp)/i) {
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
		$status_text .= "No previous configuration file.\n";
		$status_text_changed = 1;
	}

	my $serverCountryLabel = Qt::Label(this->tr('Server Country: '));
	this->{serverCountryCombo} = Qt::ComboBox();
	this->{serverCountryCombo}->setMinimumContentsLength(16);
	this->{countryList} = getComboboxCountries();
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
		$status_text .= "Could not create new pty.  Reason: " . $! . "\n";
		$status_text_changed = 1;
	}
	this->{pty} = $pty;

	# retrieve api_status
	my $api_status = getApiStatus();

	# show VPN/network/monitor status and set timer accordingly
	unless ( showNetStatus($api_status) ) {
		# monitor offline or other failure, switch to other mode
		this->{updateStatusMode} = 'other';
		this->{lastPtyRead} = time();
		this->{internalTimer}->start(1000);
		updateStatusOther();
		$status_text .= "Monitor is offline, please wait.\n";
		$status_text_changed = 1;
	} elsif ($api_status == NET_CONFIRMING) {
		this->{internalTimer}->start(1000);
	} else {
		this->{internalTimer}->start(20*1000);
	}

	if ($status_text_changed) {
		setStatusText($status_text);
	}
	updateButtons(1);
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
sub findIconPath
{
	# find path to images directory, resolve symlink if necessary
	if ( -l $0 ) {
		this->{iconPath} = dirname(readlink($0)) . '/images/';
	} else {
		this->{iconPath} = dirname($0) . '/images/';
	}
}


sub startTask {
	takeABreak(DEBUG);
	removeDispatcher(DEBUG);

	# change mode so that pty writes are displayed
	this->{updateStatusMode} = 'other';
	this->{lastPtyRead} = time();
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
	my ($api_status) = @_;
	my $status_text;
	my $monitor_online = 0;

	if ( $api_status == NET_UNPROTECTED || $api_status == NET_PROTECTED || $api_status == NET_NEGATIVE ||
	   $api_status == NET_CONFIRMING || $api_status == NET_UNCONFIRMED ) {
		$status_text = "The network is online\n";
	} elsif ($api_status == NET_CRIPPLED) {
		$status_text = "The network is in safemode\n";
	} elsif ($api_status == NET_OFFLINE || $api_status == NET_BROKEN) {
		$status_text = "The network is offline\n";
	} else {
		$status_text = "The network state is unknown\n";
	}

	if ($api_status == NET_PROTECTED) {
		$status_text .= "The VPN is up\n";
	} elsif ($api_status == NET_NEGATIVE) {
		$status_text .= "The VPN is up, but not in use\n";
	} elsif ($api_status == NET_CONFIRMING) {
		$status_text .= "The VPN is being confirmed\n";
	} elsif ($api_status == NET_UNCONFIRMED) {
		$status_text .= "The VPN is unconfirmed\n";
	} elsif ($api_status == NET_UNPROTECTED || $api_status == NET_CRIPPLED || $api_status == NET_OFFLINE) {
		$status_text .= "The VPN is down\n";
	} else {
		$status_text .= "The VPN state is unknown\n";
	}

	my $current_state_string = getMonitorState();
	if ($current_state_string =~ /(\S+)-(\S+)-\S+/) {
		my $monitor = $1;
		if ( $monitor eq "Unknown" ) {
			$status_text .= "The monitor state is unknown\n";
			print "ERROR: getMonitorState returned unknown \"$current_state_string\" \n" if DEBUG > 0;
		} elsif ( $monitor eq "Enabled" ) {
			$status_text .= "The monitor is enabled\n";
			$monitor_online = 1;
		} elsif ( $monitor eq "Disabled" ) {
			$status_text .= "The monitor is disabled\n";
			$monitor_online = 1;
		} else {
			$status_text .= "The monitor state is unknown\n";
			print "ERROR: Could not parse monitor state. getMonitorState returned \"$current_state_string\" \n" if DEBUG > 0;
		}
	} else {
		$status_text .= "The monitor state is unknown\n";
		print "ERROR: Could not parse monitor state. getMonitorState returned \"$current_state_string\" \n" if DEBUG > 0;
	}

	# instruct user if ini file missing
	unless (-e INI_FILE) {
		$status_text .= "No previous configuration file found.\n";
		$status_text .= "Please click 'Servers' to create one.\n"; 
	}
	setStatusText($status_text);

	if (DEBUG > 2) {
		$status_text =~ s/\R/  \|  /g;
		print "\n|  $status_text\n";
	}

	return($monitor_online);
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
	if ( $network eq "PROTECTED" || $network eq "NEGATIVE" ||
	   $network eq "CONFIRMING" || $network eq "UNCONFIRMED" ) {
		this->{turnoffButton}->setText(this->tr('Turn off'));
		this->{turnoffButton}->setEnabled(1);
		this->{refreshButton}->setText(this->tr('Refresh'));
		this->{refreshButton}->setEnabled(1);
		this->{userpassButton}->setEnabled(1);
	} elsif ( $network eq "OFFLINE" ) {
		this->{turnoffButton}->setText(this->tr('Fix'));
		this->{turnoffButton}->setEnabled(1);
		this->{refreshButton}->setText(this->tr('Start'));
		this->{refreshButton}->setEnabled(0);
		this->{userpassButton}->setEnabled(0);
	} elsif ( $task eq "crippled" || $network eq "CRIPPLED" ) {
		this->{turnoffButton}->setText(this->tr('No VPN'));
		this->{turnoffButton}->setEnabled(1);
		this->{refreshButton}->setText(this->tr('VPN'));
		this->{refreshButton}->setEnabled(1);
		this->{userpassButton}->setEnabled(0);
	} elsif ( $network eq "BROKEN" || $network eq "ERROR" ) {
		this->{turnoffButton}->setText(this->tr('Wait'));
		this->{turnoffButton}->setEnabled(0);
		this->{refreshButton}->setText(this->tr('Start'));
		this->{refreshButton}->setEnabled(0);
		this->{userpassButton}->setEnabled(0);
	} elsif ( $monitor eq "Enabled" ) {
		this->{turnoffButton}->setText(this->tr('Disable'));
		this->{turnoffButton}->setEnabled(1);
		this->{refreshButton}->setText(this->tr('Start'));
		this->{refreshButton}->setEnabled(1);
		this->{userpassButton}->setEnabled(1);
	} elsif ( $monitor eq "Disabled" ) {
		this->{turnoffButton}->setText(this->tr('Turn off'));
		this->{turnoffButton}->setEnabled(0);
		this->{refreshButton}->setText(this->tr('Start'));
		this->{refreshButton}->setEnabled(1);
		this->{userpassButton}->setEnabled(1);
	} else {
		this->{turnoffButton}->setText(this->tr('Turn-off'));
		this->{turnoffButton}->setEnabled(0);
		this->{refreshButton}->setText(this->tr('Start'));
		this->{refreshButton}->setEnabled(0);
		this->{userpassButton}->setEnabled(0);
	}

	# if country list is empty tweak turnoffButton, disable refreshButton and enable userpassButton
	unless (this->{countryCount}) {
		if ( $network eq "PROTECTED" || $network eq "NEGATIVE" ||
		   $network eq "CONFIRMING" || $network eq "UNCONFIRMED" ) {
			this->{turnoffButton}->setEnabled(0);
		} elsif ( $task eq "crippled" || $network eq "CRIPPLED" ) {
			this->{turnoffButton}->setText(this->tr('Uncripple'));
		}
		this->{refreshButton}->setText(this->tr('No servers'));
		this->{refreshButton}->setEnabled(0);
		this->{userpassButton}->setEnabled(1);
	}
}


sub updateButtons {
	my ($force_flag) = @_;
	if (not defined($force_flag)) {
		$force_flag = 0;
	}

	# initialize persistent variables
	state $last_state_read = 0; 		# epoch year 1970
	state $previous_state_string = "";	

	my $monitor_state = 0;			# 0 means no data, 1 = OK, 2 = offline
	my $current_state_string;

	# only update button text and enabled/disabled if 10 seconds has passed from last iteration
	my $current_time = time();
	if ( $force_flag || ($current_time - $last_state_read >= 10) ) {
		$last_state_read = $current_time;

		my $current_state_string = getMonitorState();
		if ( $force_flag || ($current_state_string ne $previous_state_string) ) {
			setButtons($current_state_string);
			$previous_state_string = $current_state_string;
		}

		if ($current_state_string =~ /(\S+)-(\S+)-\S+/) {
			my $monitor = $1;
			if ( $monitor eq "Unknown" ) {
				$monitor_state = 2;
			} elsif ( $monitor eq "Enabled" ) {
				$monitor_state = 1;
			} elsif ( $monitor eq "Disabled" ) {
				$monitor_state = 1;
			} else {
				$monitor_state = 2;
			}
		} else {
			$monitor_state = 2;
		}
	}

	return($monitor_state);
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
		if ($c =~ /([a-z][a-z])([0-9]*)/) {
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
		if ($c =~ /([a-z][a-z])\+([a-z][a-z])([0-9]*)/) {
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
		}
	}

	this->{countryCount} = scalar(@country);
	if (DEBUG > 0) {
		print STDERR "getComboboxCountries returned " . this->{countryCount} . " entries\n";
	}
	return \@country;
}


################      Username/Password management      ################
sub setUserInfo {
	this->{userpassButton}->setEnabled(0);
	this->{internalTimer}->start(120*1000);
	my $tmp = getUserInfo();
	my %userInfo = %$tmp;
	my $status_text = '';

	if ($userInfo{code} == 1) {
		$status_text .= "Note: There are no VPN connection installed.\n";
		setStatusText($status_text);
		$userInfo{username} = "";
		$userInfo{password} = "";
	} elsif ($userInfo{code} == 2) {
		$status_text .= "Note: Can not open your VPN connection files.\n";
		setStatusText($status_text);
		this->{userpassButton}->setEnabled(1);
		this->{internalTimer}->start(30*1000);
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
		$status_text .= "Click 'Servers' to change VPN credentials ";
		$status_text .= "and retrieve latest server list.";
		setStatusText($status_text);
		this->{userpassButton}->setEnabled(1);
		this->{internalTimer}->start(30*1000);
		return 1;
	}

	my $ac_rc; # addConnections() return code
	if ($ok) {
		backupConnections();
		$ac_rc = addConnections($username, $password);
		if ($ac_rc == 1) {
			restoreConnections('missing');
			$status_text .= "Note: Can not create all connections for you due to partial failure\n";
		} elsif ($ac_rc == 2) {
			restoreConnections('all');
			$status_text .= "Note: Can not create all connections for you due to complete failure\n";
		}

		# since we changed the ini file, ask monitor to reread config
		rereadConfig();

		if ($ac_rc != 0) {
			setStatusText($status_text);
			this->{userpassButton}->setEnabled(1);
			this->{internalTimer}->start(30*1000);
			return $userInfo{code};
		}
	}

	# reread country list
	this->{serverCountryCombo}->clear();
	this->{countryList} = getComboboxCountries();
	updateButtons(1);

	# load new system connection into NetworkManager
	system("/sbin/service network force-reload");

	$status_text .= "\nVPN servers updated!\n";
	$status_text .= "Username and password set.\n";
	setStatusText($status_text);

	this->{userpassButton}->setEnabled(1);
	this->{internalTimer}->start(30*1000);
	return 0;
}


sub getUserInfo {
	my %userInfo = ();
	$userInfo{code} = 0;

	my $countrylist = this->{countryList};
	my $ccode = (defined($countrylist) && this->{countryCount} > this->{id_country}) ? $countrylist->[this->{id_country}] : '';

	my $servertype = this->{id_serverType};
	if (not defined $servertype) {
		$servertype = 0;
	}
	my $stype = $servertype == 0 ? "tcp" : "udp";

	my $system_connection_file = "";
	# scan directory for matching files
	my @tmplist = glob("/etc/NetworkManager/system-connections/*-$ccode-*-$stype");
	foreach my $file (@tmplist) {
		# check file syntax, select first that matches
		if ($file =~ /(double|tor|vpn)-([a-z][a-z][0-9]*|[a-z][a-z]\+[a-z][a-z][0-9]?)-(.*)-(tcp|udp)/i) {
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
	# disable refresh button for 20 seconds
	this->{refreshButton}->setEnabled(0);
	this->{buttonTimer}->start(20*1000);

	startTask();

	# Clear previous status text and disable normal/other update for 2 minutes or until timer restarted
	my $status_text = '';
	this->{internalTimer}->start(120*1000);

	my $api_status = getNetStatus();
	if ($api_status == NET_CRIPPLED || getCripplingStatus(DEBUG)) {
		undoCrippling(DEBUG);
		$status_text .= "Deactivating Safemode.\n";
	}

	# check NetworkManager and nmcli
	unless ( isNetworkManagerEnabled() ) {
		$status_text .= explainNetworkManagerProblem();
		setStatusText($status_text);
		return;
	}

	if ($api_status == NET_PROTECTED || $api_status == NET_NEGATIVE || 
	   $api_status == NET_CONFIRMING || $api_status == NET_UNCONFIRMED) { # i.e. vpn is up
		$status_text .= "The VPN connection is deactivating,\n";
		$status_text .= "Please hold on.\n\n";
		print "VPN is active, deactivating...\n" if DEBUG > 0;

		# detect nmcli version
		my @active_lines;
		my $test_string = '/usr/bin/nmcli conn show --active >/dev/null 2>&1';
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
		
		# set failover flag if above gave no results
		my $failover_mode = 0;
		if (!@active_conns) {
			$failover_mode = 1;
		}

		my $vpn_connection = getVpnConnection();
		my $pty = this->{pty};
		foreach my $conn (@$vpn_connection) {
			my $vpn_name = $conn->{connection}->{id};
			if ( $failover_mode  || ($vpn_name ~~ @active_conns) ) {
				try {
					print "Deactivating " . $vpn_name . "\n" if DEBUG > 0;
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
	}

	setStatusText($status_text);

	# return to QT event loop for 0.5 seconds
	print "Start resume vpn timer\n" if DEBUG > 0;
	this->{resumeVpnTimer}->start(500);
}


sub updateDefaultVpnResume {
	system("pkill -9 openvpn");
	this->{resumeVpnTimer}->stop;
	print "Resume activation of VPN\n" if DEBUG > 0;

	my $status = this->{statusOutput};
	my $status_text = $status->toPlainText();

	# read output from deactivation pty now, otherwise the status text order will be wrong
	my $pty = this->{pty};
	while ( my $output = $pty->read(0) ) {
		$status_text .= $output;
	}

	my $countrylist = this->{countryList};
	my $configfiledir = "/etc/openvpn/";
	my $vpntype;
	my $comment;
	my $configfile;

	print "Country ID is " . this->{id_country} . "\n" if DEBUG > 1;
	my $ccode = (defined($countrylist) && this->{countryCount} > this->{id_country}) ? $countrylist->[this->{id_country}] : '';
	my $stype = this->{id_serverType} == 0 ? 'tcp' : 'udp';

	# scan directory for matching files
	my @tmplist = glob($configfiledir."*-$ccode-*-$stype.ovpn");
	foreach my $file (@tmplist) {
		# check file syntax, select first that matches
		if ($file =~ /(double|tor|vpn)-([a-z][a-z][0-9]*|[a-z][a-z]\+[a-z][a-z][0-9]?)-(.*)-(tcp|udp)\.ovpn/i) {
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
		$status_text .= "\nError: Configuration file not found!\n";
		$status_text .= "Check that the selected server\n";
		$status_text .= "supports protocol " . uc($stype) . ".\n";
		setStatusText($status_text);
		this->{internalTimer}->start(120*1000);
		forceRefresh(DEBUG);
		return;
	}

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
		$status_text .= "\nThere are no VPN connections!\n";
		$status_text .= "Please click 'Servers'\n"; 
		$status_text .= "to set your username/password\n"; 
		this->{internalTimer}->start(10*60*1000);
	} elsif ($return_code !=0) {
		$status_text .= "\nUnexcepted Error.\n";
		this->{internalTimer}->start(10*60*1000);
	}else {
		$status_text .= "\nThe VPN connection will be activated,\n";
		$status_text .= "Please hold on.\n\n";
		this->{updateStatusMode} = 'other';
		this->{internalTimer}->start(1000);
	}
	setStatusText($status_text);

	enableMonitor(DEBUG);
	forceRefresh(DEBUG);
}


sub setDefaultVpn {
	my ($configfile, $ccode, $comment, $type, $vpntype) = @_;
	my $uuid = '';
	my $url = 'none';
	my $remote = '';
	my $return_code = 0;
	my $pty = this->{pty};
	my $spawn_out;
	my $status_text = '';

	# check NetworkManager and nmcli
	unless ( isNetworkManagerEnabled() ) {
		$status_text .= explainNetworkManagerProblem();
		setStatusText($status_text);
		return 1;
	}

	print STDERR "Setting default vpn: \$configfile = '$configfile', \$ccode = '$ccode', \$type = '$type', \$vpntype = '$vpntype'\n" if DEBUG > 0;

	my $sysconnections = "/etc/NetworkManager/system-connections/";
	my $id = $vpntype . "-" . $ccode . "-" . $comment . "-" . $type;
	if (-r $sysconnections . $id && -r '/etc/ca-certificates/' . $id . ".ca" && -r '/etc/ca-certificates/' . $id . ".auth") {
		unless (open IN, $sysconnections.$id) {
			my $status = this->{statusOutput};
			$status_text = $status->toPlainText();
			$status_text .= "Could not open VPN config file for reading. Reason: " . $! . "\n";
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
		$status_text = $status->toPlainText();
		$status_text .= "No system connection file found.\n";
		setStatusText($status_text);
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
	if (open $vpn_ini, "<" . INI_FILE) {
		open $vpn_ini, "<", INI_FILE;
		while (my $line = <$vpn_ini>) {
			if ($line =~ /^url\s*=\s*(.*)\s*/) {
				$url = $1;
				last;
			}
		}
		close $vpn_ini;
	} else {
		my $error = $!;
		my $status = this->{statusOutput};
		$status_text = $status->toPlainText();
		if ( -e INI_FILE ) {
			print STDERR "Could not open " . INI_FILE . " for reading.  Reason: " . $error . "\n";
			print STDERR "Deleting old ini file.\n";
			unlink(INI_FILE);
			$status_text .= "Deleted old ini file.\n";
		}
		print STDERR "Creating new ini file " . INI_FILE . "\n";
		$status_text .= "Creating new ini file '" . INI_FILE . "'\n";
		setStatusText($status_text);

		# make directory in case it is missing
		my $config_path = dirname(INI_FILE);
		unless ( -d $config_path ) {
			eval { make_path($config_path); };
		}
	}

	# write ini file
	unless (open $vpn_ini, ">", INI_FILE) {
		my $status = this->{statusOutput};
		$status_text = $status->toPlainText();
		$status_text .= "Could not create '" . INI_FILE . "'  Reason: " . $! . "\n";
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
	my $result = writeDispatcher();
	if ($result =~ /not ok/) {
		my $status = this->{statusOutput};
		$status_text = $status->toPlainText();
		$status_text .= "Could not write dispatcher file. " . $result . "\n";
		setStatusText($status_text);
	}

	return 0;
}


################     Deactivate VPN / Fix connection    ################
sub turnOffVpn {
	# Disable normal/other update for 2 minutes or until timer restarted
	this->{internalTimer}->start(120*1000);

	# network status = PROTECTED or monitor = Disabled
	if (this->{turnoffButton}->text eq "Turn off") {
		# continue to rest of subroutines

	# network status = UNPROTECTED and monitor = Enabled
	} elsif (this->{turnoffButton}->text eq "Disable") {
		removeDispatcher(DEBUG);
		disableMonitor(DEBUG);
		setStatusText("Monitor disabled.\n");
		this->{turnoffButton}->setEnabled(0);
		return 0;

	# network status = CRIPPLED
	} elsif (this->{turnoffButton}->text eq "No VPN" || this->{turnoffButton}->text eq "Uncripple") {
		removeDispatcher(DEBUG);
		disableMonitor(DEBUG);
		undoCrippling(DEBUG);
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

	
	# check NetworkManager and nmcli
	unless ( isNetworkManagerEnabled() ) {
		my $status_text .= explainNetworkManagerProblem();
		setStatusText($status_text);
		system("pkill -9 openvpn");
		forceRefresh(DEBUG);
		this->{updateStatusMode} = 'other';
		this->{internalTimer}->start(1000);
		return;
	}
	
	my $status_text = "The VPN connection is deactivating,\n";
	$status_text .= "Please hold on.\n\n";

	startTask();
	disableMonitor(DEBUG);

	if (getCripplingStatus(DEBUG)) {
		undoCrippling(DEBUG);
		setStatusText("Safemode deactivated.\n");
		return 0;
	}

	# detect nmcli version
	my @active_lines;
	my $test_string = '/usr/bin/nmcli conn show --active >/dev/null 2>&1';
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
		$status_text .= "Forcing VPN deactivation,\n";
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

	my $vpn_connection = getVpnConnection();
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
	forceRefresh(DEBUG);
	this->{updateStatusMode} = 'other';
	this->{internalTimer}->start(1000);

	if ($failover_mode) {
		my $status = this->{statusOutput};
		my $status_text = $status->toPlainText();
		$status_text .= "The VPN connection is deactivated.\n";
		setStatusText($status_text);
	}
	
	return 0;
}


sub fixConnection {
	my $status_text = "Fixing network connection\n";

	startTask();

	my $remove_response = removeRoute();
	if ($remove_response =~ /not ok/) {
		$status_text .= "Detected wrong route but cannot remove it.\n";
	}

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

	# restart network
	system("/usr/sbin/service network restart");

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

	# check NetworkManager and nmcli
	unless ( isNetworkManagerEnabled() ) {
		$status_text .= explainNetworkManagerProblem();
		setStatusText($status_text);
		forceRefresh(DEBUG);
		this->{updateStatusMode} = 'other';
		this->{internalTimer}->start(1000);
		return 1;
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

	forceRefresh(DEBUG);
	this->{updateStatusMode} = 'other';
	this->{internalTimer}->start(1000);

	return 0;
}


################                Main Loop               ################
sub updateStatus {
	if ( this->{updateStatusMode} eq 'normal' ) {
		updateStatusNormal();
	} else {
		updateStatusOther();
	}
}


sub updateStatusNormal {
	# initialize persistent variables
	state $confirming_counter = 0;

	print "@" if DEBUG > 2;

	my $api_status = getApiStatus();
	if ($api_status == NET_CONFIRMING) {
		$confirming_counter++;
		if ($confirming_counter == 1) {
			# continue subroutine to change status text to unconfirmed
		} elsif ($confirming_counter < API_CHECK_TIMEOUT) {
			# ignore status change until request has timed out
			this->{internalTimer}->start(1000);
			return;
		} else {
			# change status to unconfirmed if request timeout failed
			$api_status = NET_UNCONFIRMED;
		}
	} else {
		$confirming_counter = 0;
	}

	# display net/monitor status
	unless ( showNetStatus($api_status) ) {
		# monitor offline or other failure, switch to other mode
		this->{updateStatusMode} = 'other';
		this->{lastPtyRead} = time();
		this->{internalTimer}->start(1000);
		updateStatusOther();
		return;
	}

	updateButtons(0);

	if ($api_status == NET_UNPROTECTED || $api_status == NET_PROTECTED) {
		this->{internalTimer}->start(60*1000);
	} elsif ($api_status == NET_UNCONFIRMED || $api_status == NET_NEGATIVE) {
		this->{internalTimer}->start(15*1000);
	} elsif ($api_status == NET_CONFIRMING) {
		this->{internalTimer}->start(1000);
	} elsif ($api_status == NET_CRIPPLED) { 
		this->{updateStatusMode} = 'other';
		this->{lastPtyRead} = time();
		this->{internalTimer}->start(10*1000);
	} else {
		this->{updateStatusMode} = 'other';
		this->{lastPtyRead} = time();
		this->{internalTimer}->start(1000);
	}
}


sub updateStatusOther {
	# initialize persistent variables
	state $previous_status = 100;
	state $reset_previous_status = 1;
	state $previous_monitor_state = 0;
	state $confirming_counter = 0;

	my $current_time = time();
	my $status = this->{statusOutput};
	my $status_text = $status->toPlainText();
	my $status_text_changed = 0;

	# read pty
	my $pty = this->{pty};
	my $active_flag = $pty->is_active();
	while ( my $output = $pty->read(0) ) {
		$status_text .= $output;
		$status_text_changed = 1;
		$active_flag = 1;
		this->{lastPtyRead} = $current_time;
	}

	if (DEBUG > 2) {
		if ($active_flag) {
			print "#";
		} else {
			print ".";
		}
	}

	if ($active_flag) {
		# display progress indicator dots
		if ($status_text =~ /please\shold\son/i) {
			# remove all carriage return characters
			$status_text =~ s/[\r]//g;
			# add progress indicator dots if last line of status text is 'Please hold on'
			if ($status_text =~ /please\shold\son[.]?[\s]*[\n]*[.]*[\n]*$/i) {
				chomp $status_text;
				$status_text .= ".\n";
			} else {
				# since the task is completed, remove 'Please hold on' text and progress indicator dots
				$status_text =~ s/please\shold\son[.]?[\s]*[\n]*[.]*[\n]?/\n/i;
			}
			$status_text_changed = 1;
		}

		if ($status_text_changed) {
			setStatusText($status_text);
		}

		# reset network status on next iteration after the pty's subprocess has completed
		$reset_previous_status = 1;

		this->{internalTimer}->start(1000);
		return;
	}

	# continue here if the pty is not active
	my $last_pty_read = this->{lastPtyRead};
	if ( $current_time - $last_pty_read > 2*60 ) { # keep text for 2 min
		print "\n\tupdateStatusMode changed back to normal because of 2 minute timeout.\n" if DEBUG > 1;
		this->{updateStatusMode} = 'normal';
		updateStatusNormal();
		return;
	} elsif ( $current_time - $last_pty_read > 30 ) { # slow down refresh after 30 seconds
		this->{internalTimer}->start(5*1000);
	} elsif ( $current_time - $last_pty_read > 60 ) { # slow down refresh even more after 1 minute
		this->{internalTimer}->start(10*1000);
	}

	# store network status for next iteration
	my $current_status = getNetStatus();
	my $tmp_previous = $previous_status;
	if ($reset_previous_status) {
		$tmp_previous = $current_status;
		$reset_previous_status = 0;
		forceRefresh(DEBUG);
		
		# change the monitor's task status response to idle
		resumeIdling(DEBUG);
	}
	$previous_status = $current_status;

	# update buttons and retrieve monitor state (runs only every 10 sec)
	my $current_monitor_state = updateButtons(0);
	if ($current_monitor_state) {
		# previous/current_monitor_state: Disabled/Enabled = 1, Unknown = 2 
		unless ($previous_monitor_state) {
			$previous_monitor_state = $current_monitor_state;
		}
		if ($current_monitor_state != $previous_monitor_state) {
			if ($current_monitor_state == 1) {
				print "\n\tupdateStatusMode changed back to normal because monitor recovered.\n" if DEBUG > 1;
				this->{updateStatusMode} = 'normal';
				updateStatusNormal();
				return;
			}
			$previous_monitor_state = $current_monitor_state;
		}
		if ($current_monitor_state == 2) {
			unless ($status_text =~ /Monitor\sis\soffline/) {
				$status_text .= "Monitor is offline, please restart by\n";
				$status_text .= " running 'vpn-monitor -s' as root.\n";
				$status_text_changed = 1;
			}
		}
	}

	# clear confirming counter before tampering with current_status variable
	if ($current_status != NET_CONFIRMING) {
		$confirming_counter = 0;
	}

	# compare current_status to previous_status and inform the user about changes
	if ($current_status != $tmp_previous) {
		forceRefresh(DEBUG);

		if ($current_status == NET_OFFLINE && $tmp_previous != NET_OFFLINE && 
		   $tmp_previous != NET_UNKNOWN) {
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
			$status_text .= "Network status is unconfirmed.\n";
			$status_text_changed = 1;
		} elsif ($current_status == NET_CONFIRMING && $tmp_previous != NET_CONFIRMING) {
			$confirming_counter++;
			if ($confirming_counter < API_CHECK_TIMEOUT) {
				# ignore status change until request has timed out or monitor has changed it to NET_UNCONFIRMED
				$current_status = $tmp_previous;
				$previous_status = $tmp_previous;
				this->{internalTimer}->start(1000);
			} else {
				# change status to unconfirmed if request timeout failed
				$current_status = NET_UNCONFIRMED;
				$previous_status = NET_UNCONFIRMED;
				$status_text .= "Network status is unconfirmed.\n";
				$status_text_changed = 1;
			}
		} elsif ($current_status == NET_PROTECTED && $tmp_previous != NET_PROTECTED) {
			# check API after VPN activation
			$current_status = getApiStatus();
			if ($current_status == NET_UNCONFIRMED) {
				this->{internalTimer}->start(1000);
			}
			this->{refreshButton}->setEnabled(1);
			this->{buttonTimer}->stop();
			this->{turnoffButton}->setEnabled(1);
		}

		if ($tmp_previous == NET_CRIPPLED && $current_status != NET_CRIPPLED) {
			this->{userpassButton}->setEnabled(1);
			$status_text .= "Network restored from safemode.\n";
			$status_text_changed = 1;
		} elsif ($tmp_previous == NET_BROKEN && $current_status != NET_BROKEN) {
			# note: no recovered-text for NET_UNKNOWN, since GUI starts with UNKNOWN state
			if ($current_status == NET_PROTECTED || $current_status == NET_NEGATIVE) {
				$status_text .= "Recovered to protected mode.\n";
				$status_text_changed = 1;
			} elsif ($current_status == NET_UNPROTECTED) {
				$status_text .= "Recovered to unprotected mode.\n";
				$status_text_changed = 1;
			}
		} elsif ( $tmp_previous == NET_ERROR && $current_status != NET_ERROR) {
			if ($current_status == NET_PROTECTED || $current_status == NET_NEGATIVE) {
				$status_text .= "Monitor recovered, VPN is up.\n";
				$status_text_changed = 1;
			} elsif ($current_status == NET_UNPROTECTED) {
				$status_text .= "Monitor recovered, VPN is down.\n";
				$status_text_changed = 1;
			}
		} elsif ($tmp_previous == NET_OFFLINE && $current_status != NET_OFFLINE) {
			if ($current_status == NET_PROTECTED) {
				$status_text .= "Network connection recovered\nThe VPN is up\n";
				$status_text_changed = 1;
			} elsif ($current_status == NET_NEGATIVE) {
				$status_text .= "Network connection recovered\nThe VPN is up, but not in use\n";
				$status_text_changed = 1;
			} elsif ($current_status == NET_UNPROTECTED) {
				$status_text .= "Network connection recovered\nThe VPN is down\n";
				$status_text_changed = 1;
			} elsif ($current_status == NET_UNCONFIRMED) {
				$status_text .= "Network connection recovered\nThe VPN is unconfirmed\n";
				$status_text_changed = 1;
			} elsif ($current_status == NET_CONFIRMING) {
				$status_text .= "Network connection recovered\nThe VPN is being confirmed\n";
				$status_text_changed = 1;
			}
		} elsif ($tmp_previous == NET_UNCONFIRMED && $current_status != NET_UNCONFIRMED) {
			if ($current_status == NET_PROTECTED) {
				$status_text .= "The VPN is confirmed\n";
				$status_text_changed = 1;
			} elsif ($current_status == NET_NEGATIVE) {
				$status_text .= "The VPN is up, but not in use\n";
				$status_text_changed = 1;
			} elsif ($current_status == NET_UNPROTECTED) {
				$status_text .= "The VPN is down\n";
				$status_text_changed = 1;
			}
		}
	}

	if ($status_text_changed) {
		setStatusText($status_text);
	}
}

1;
