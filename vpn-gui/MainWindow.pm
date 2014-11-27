package MainWindow;

#
# PrivateOn-VPN -- Because privacy matters.
#
# Authors: Mikko Rautiainen & Lei Xue     <info@tietosuojakone.fi>
#
# Copyright (C) 2014  PrivateOn / Tietosuojakone Oy, Helsinki, Finland
# All rights reserved. Use is subject to license terms.
#

use strict;
use warnings;
use File::Path qw(make_path);
use File::Copy qw(copy);
use QtCore4;
use QtGui4;
use QtCore4::isa qw( Qt::MainWindow);
use QtCore4::slots
	updateDefaultVpn => [],
	updateDefaultVpnResume => [],
	turnOffVpn => [],
	setUserInfo => [],
	setCountry => ['int'],
	setServerType => ['int'],
	setVpn => ['int'],
	closeEvent => ['Qt::CloseEvent'],
	reenableButton => [],
	updateStatus => [];
use Net::DBus qw(:typing);
use Data::Dumper;
use vpn_status qw(get_nordvpn_status get_net_status take_a_break remove_dispatcher disable_monitor undo_crippling force_refresh enable_monitor);
use vpn_install qw(add_connections);
use sigtrap;
use Socket;
use IO::Pty::Easy;
use Try::Tiny;
use File::Basename;

my $net_status;
my $internalTimer;
my $buttonTimer;
my $resumeTimer;
my $last_pty_read = 4102444800000; # epoch year 2100 
my $previous_status = 100;
my $serverCountryCombo;
my $cancelButton;
my $okButton;
my $default_ccode;

use constant {
	DISPATCH_FILE => "/etc/NetworkManager/dispatcher.d/vpn-up",
	INI_FILE => "/opt/PrivateOn-VPN/vpn-default.ini",
	DEBUG => 1,
	ENABLE_VPN => 1,
	ENABLE_DUAL_VPN => 1,
	ENABLE_TOR_VPN => 0,
};

# net status
use constant {
	NET_UNPROTECTED => 0,
	NET_PROTECTED   => 1,
	NET_BROKEN      => 2,
	NET_CRIPPLED    => 3,
	NET_ERROR       => 99,
	NET_UNKNOWN     => 100	
};

sub country() {
	return this->{id_country};
}

sub serverType() {
	return this->{id_serverType};
}

sub closeEvent($$) {
	my ($event) = @_;
	this->hide();
	$event->ignore();
}

sub moveEvent($$) {
	my ($event) = @_;
	this->move( (Qt::Application::desktop()->availableGeometry()->width() - this->width() - Qt::Application::desktop()->width()/28), (Qt::Application::desktop()->availableGeometry()->height() - this->height()) );
	$event->ignore();
}

# [0]

my %country_code = (
	'ad'	=> 'Andorra',
	'ae'	=> 'United Arab Emirates',
	'af'	=> 'Afghanistan',
	'ag'	=> 'Antigua and Barbuda',
	'ai'	=> 'Anguilla',
	'al'	=> 'Albania',
	'am'	=> 'Armenia',
	'ao'	=> 'Angola',
	'aq'	=> 'Antarctica',
	'ar'	=> 'Argentina',
	'as'	=> 'American Samoa',
	'at'	=> 'Austria',
	'au'	=> 'Australia',
	'aw'	=> 'Aruba',
	'ax'	=> 'Åland Islands',
	'az'	=> 'Azerbaijan',
	'ba'	=> 'Bosnia and Herzegovina',
	'bb'	=> 'Barbados',
	'bd'	=> 'Bangladesh',
	'be'	=> 'Belgium',
	'bf'	=> 'Burkina Faso',
	'bg'	=> 'Bulgaria',
	'bh'	=> 'Bahrain',
	'bi'	=> 'Burundi',
	'bj'	=> 'Benin',
	'bl'	=> 'Saint Barthélemy',
	'bm'	=> 'Bermuda',
	'bn'	=> 'Brunei Darussalam',
	'bo'	=> 'Bolivia, Plurinational State of',
	'bq'	=> 'Bonaire, Sint Eustatius and Saba',
	'br'	=> 'Brazil',
	'bs'	=> 'Bahamas',
	'bt'	=> 'Bhutan',
	'bv'	=> 'Bouvet Island',
	'bw'	=> 'Botswana',
	'by'	=> 'Belarus',
	'bz'	=> 'Belize',
	'ca'	=> 'Canada',
	'cc'	=> 'Cocos (Keeling) Islands',
	'cd'	=> 'Congo, the Democratic Republic of the',
	'cf'	=> 'Central African Republic',
	'cg'	=> 'Congo',
	'ch'	=> 'Switzerland',
	'ci'	=> 'Côte d\'Ivoire',
	'ck'	=> 'Cook Islands',
	'cl'	=> 'Chile',
	'cm'	=> 'Cameroon',
	'ch'	=> 'China',
	'co'	=> 'Colombia',
	'cr'	=> 'Costa Rica',
	'cu'	=> 'Cuba',
	'cv'	=> 'Cape Verde',
	'cw'	=> 'Curaçao',
	'cx'	=> 'Christmas Island',
	'cy'	=> 'Cyprus',
	'cz'	=> 'Czech Republic',
	'de'	=> 'Germany',
	'dj'	=> 'Djibouti',
	'dk'	=> 'Denmark',
	'dm'	=> 'Dominica',
	'do'	=> 'Dominican Republic',
	'dz'	=> 'Algeria',
	'ec'	=> 'Ecuador',
	'ee'	=> 'Estonia',
	'eg'	=> 'Egypt',
	'eh'	=> 'Western Sahara',
	'er'	=> 'Eritrea',
	'es'	=> 'Spain',
	'et'	=> 'Ethiopia',
	'fi'	=> 'Finland',
	'fj'	=> 'Fiji',
	'fk'	=> 'Falkland Islands (Malvinas)',
	'fm'	=> 'Micronesia, Federated States of',
	'fo'	=> 'Faroe Islands',
	'fr'	=> 'France',
	'ga'	=> 'Gabon',
	'uk'	=> 'United Kingdom',
	'gd'	=> 'Grenada',
	'ge'	=> 'Georgia',
	'gf'	=> 'French Guiana',
	'gg'	=> 'Guernsey',
	'gh'	=> 'Ghana',
	'gi'	=> 'Gibraltar',
	'gl'	=> 'Greenland',
	'gm'	=> 'Gambia',
	'gn'	=> 'Guinea',
	'gp'	=> 'Guadeloupe',
	'gq'	=> 'Equatorial Guinea',
	'gr'	=> 'Greece',
	'gs'	=> 'South Georgia and the South Sandwich Islands',
	'gt'	=> 'Guatemala',
	'gu'	=> 'Guam',
	'gw'	=> 'Guinea-Bissau',
	'gy'	=> 'Guyana',
	'hk'	=> 'Hong Kong',
	'hm'	=> 'Heard Island and McDonald Islands',
	'hn'	=> 'Honduras',
	'hr'	=> 'Croatia',
	'ht'	=> 'Haiti',
	'hu'	=> 'Hungary',
	'id'	=> 'Indonesia',
	'ie'	=> 'Ireland',
	'il'	=> 'Israel',
	'im'	=> 'Isle of Man',
	'in'	=> 'India',
	'io'	=> 'British Indian Ocean Territory',
	'iq'	=> 'Iraq',
	'ir'	=> 'Iran, Islamic Republic of',
	'is'	=> 'Iceland',
	'it'	=> 'Italy',
	'je'	=> 'Jersey',
	'jm'	=> 'Jamaica',
	'jo'	=> 'Jordan',
	'jp'	=> 'Japan',
	'ke'	=> 'Kenya',
	'kg'	=> 'Kyrgyzstan',
	'kh'	=> 'Cambodia',
	'ki'	=> 'Kiribati',
	'km'	=> 'Comoros',
	'kn'	=> 'Saint Kitts and Nevis',
	'kp'	=> 'Korea, Democratic People\'s Republic of',
	'kr'	=> 'Korea, Republic of',
	'kw'	=> 'Kuwait',
	'ky'	=> 'Cayman Islands',
	'kz'	=> 'Kazakhstan',
	'la'	=> 'Lao People\'s Democratic Republic',
	'lb'	=> 'Lebanon',
	'lc'	=> 'Saint Lucia',
	'li'	=> 'Liechtenstein',
	'lk'	=> 'Sri Lanka',
	'lr'	=> 'Liberia',
	'ls'	=> 'Lesotho',
	'lt'	=> 'Lithuania',
	'lu'	=> 'Luxembourg',
	'lv'	=> 'Latvia',
	'ly'	=> 'Libyan Arab Jamahiriya',
	'ma'	=> 'Morocco',
	'mc'	=> 'Monaco',
	'md'	=> 'Moldova, Republic of',
	'me'	=> 'Montenegro',
	'mf'	=> 'Saint Martin (French part)',
	'mg'	=> 'Madagascar',
	'mh'	=> 'Marshall Islands',
	'mk'	=> 'Macedonia, the former Yugoslav Republic of',
	'ml'	=> 'Mali',
	'mm'	=> 'Myanmar',
	'mn'	=> 'Mongolia',
	'mo'	=> 'Macao',
	'mp'	=> 'Northern Mariana Islands',
	'mq'	=> 'Martinique',
	'mr'	=> 'Mauritania',
	'ms'	=> 'Montserrat',
	'mt'	=> 'Malta',
	'mu'	=> 'Mauritius',
	'mv'	=> 'Maldives',
	'mw'	=> 'Malawi',
	'mx'	=> 'Mexico',
	'my'	=> 'Malaysia',
	'mz'	=> 'Mozambique',
	'na'	=> 'Namibia',
	'nc'	=> 'New Caledonia',
	'ne'	=> 'Niger',
	'nf'	=> 'Norfolk Island',
	'ng'	=> 'Nigeria',
	'ni'	=> 'Nicaragua',
	'nl'	=> 'Netherlands',
	'no'	=> 'Norway',
	'np'	=> 'Nepal',
	'nr'	=> 'Nauru',
	'nu'	=> 'Niue',
	'nz'	=> 'New Zealand',
	'om'	=> 'Oman',
	'pa'	=> 'Panama',
	'pe'	=> 'Peru',
	'pf'	=> 'French Polynesia',
	'pg'	=> 'Papua New Guinea',
	'ph'	=> 'Philippines',
	'pk'	=> 'Pakistan',
	'pl'	=> 'Poland',
	'pm'	=> 'Saint Pierre and Miquelon',
	'pn'	=> 'Pitcairn',
	'pr'	=> 'Puerto Rico',
	'ps'	=> 'Palestinian Territory, Occupied',
	'pt'	=> 'Portugal',
	'pw'	=> 'Palau',
	'py'	=> 'Paraguay',
	'qa'	=> 'Qatar',
	're'	=> 'Réunion',
	'ro'	=> 'Romania',
	'rs'	=> 'Serbia',
	'ru'	=> 'Russian Federation',
	'rw'	=> 'Rwanda',
	'sa'	=> 'Saudi Arabia',
	'sb'	=> 'Solomon Islands',
	'sc'	=> 'Seychelles',
	'sd'	=> 'Sudan',
	'se'	=> 'Sweden',
	'sg'	=> 'Singapore',
	'sh'	=> 'Saint Helena, Ascension and Tristan da Cunha',
	'si'	=> 'Slovenia',
	'sj'	=> 'Svalbard and Jan Mayen',
	'sk'	=> 'Slovakia',
	'sl'	=> 'Sierra Leone',
	'sm'	=> 'San Marino',
	'sn'	=> 'Senegal',
	'so'	=> 'Somalia',
	'sr'	=> 'Suriname',
	'st'	=> 'Sao Tome and Principe',
	'sv'	=> 'El Salvador',
	'sx'	=> 'Sint Maarten (Dutch part)',
	'sy'	=> 'Syrian Arab Republic',
	'sz'	=> 'Swaziland',
	'tc'	=> 'Turks and Caicos Islands',
	'td'	=> 'Chad',
	'tf'	=> 'French Southern Territories',
	'tg'	=> 'Togo',
	'th'	=> 'Thailand',
	'tj'	=> 'Tajikistan',
	'tk'	=> 'Tokelau',
	'tl'	=> 'Timor-Leste',
	'tm'	=> 'Turkmenistan',
	'tn'	=> 'Tunisia',
	'to'	=> 'Tonga',
	'tr'	=> 'Turkey',
	'tt'	=> 'Trinidad and Tobago',
	'tv'	=> 'Tuvalu',
	'tw'	=> 'Taiwan, Province of China',
	'tz'	=> 'Tanzania, United Republic of',
	'ua'	=> 'Ukraine',
	'ug'	=> 'Uganda',
	'um'	=> 'United States Minor Outlying Islands',
	'us'	=> 'United States',
	'uy'	=> 'Uruguay',
	'uz'	=> 'Uzbekistan',
	'va'	=> 'Holy See (Vatican City State)',
	'vc'	=> 'Saint Vincent and the Grenadines',
	've'	=> 'Venezuela, Bolivarian Republic of',
	'vg'	=> 'Virgin Islands, British',
	'vi'	=> 'Virgin Islands, U.S.',
	'vn'	=> 'Viet Nam',
	'vu'	=> 'Vanuatu',
	'wf'	=> 'Wallis and Futuna',
	'ws'	=> 'Samoa',
	'ye'	=> 'Yemen',
	'yt'	=> 'Mayotte',
	'za'	=> 'South Africa',
	'zm'	=> 'Zambia',
	'zw'	=> 'Zimbabwe',
);

sub NEW
{
	my ($class) = @_;
	$class->SUPER::NEW();
	this->{id_country} = 0;
	this->{country} = 'de';
	this->{id_serverType} = 0;
	this->{serverType} = 'tcp';

	# timer implementation
	$internalTimer = Qt::Timer(this);  # create internal timer
	this->connect($internalTimer, SIGNAL('timeout()'), SLOT('updateStatus()'));
	$internalTimer->start(5000);	  # emit signal every 5 second

	# button enable/disable timer
	$buttonTimer = Qt::Timer(this);
	this->connect($buttonTimer, SIGNAL('timeout()'), SLOT('reenableButton()'));

	# Resume timer to continue processing after vpn disabled
	$resumeTimer = Qt::Timer(this);
	this->connect($resumeTimer, SIGNAL('timeout()'), SLOT('updateDefaultVpnResume()'));

	my $title = Qt::Label(this->tr('VPN default selection'));
	my $image = Qt::Label();
	$image->setPixmap(Qt::Pixmap(dirname($0).'/images/logo.png')->scaled(Qt::Size(300,150)));

	my $status = Qt::TextEdit();
	my $nordvpn_status = get_nordvpn_status();
	$status->setReadOnly(1);

	$status->setMaximumHeight(60);
	this->{statusOutput} = $status;
	$ENV{status_output} = \$status;

	my $centralWidget = Qt::Widget();
	setWindowFlags( Qt::Tool() | Qt::FramelessWindowHint() );

	my $serverCountryLabel = Qt::Label(this->tr('Server Country: '));
	$serverCountryCombo = Qt::ComboBox();

	my $default_type;
	# set default values to be used if values not found in ini file 
	$default_ccode = "de";
	$default_type = "tcp";
	if (-e INI_FILE) {
		open my $vpn_ini, "<", INI_FILE;
		while (my $line = <$vpn_ini>) {
			if ($line =~/^id=(\S+)/) {
				my $id = $1;
				if ($id =~ /vpn-([a-z][a-z][a-z0-9]?)\.nordvpn-(tcp|udp)/i) {
					$default_ccode = $1;
					this->{country} = $default_ccode;
					$default_type = $2;
					this->{serverType} = $default_type;
					print "Read default_ccode = $default_ccode\tdefault_type = $default_type\n" if DEBUG > 1;
				}
				last;
			}
		}
	} else {
		$net_status = "No previous configuration file.\n";
	}

	if ($nordvpn_status == NET_UNPROTECTED || $nordvpn_status == NET_PROTECTED) {
		$net_status .= "The network is online!\n";
	} elsif ($nordvpn_status == NET_CRIPPLED) {
		$net_status .= "The network is in safemode!\n";
	} else {
		$net_status .= "The network is offline!\n";
	}
	if ($nordvpn_status == NET_PROTECTED) {
		$net_status .= "The Nord VPN is up!\n";
	} else {
		$net_status .= "The Nord VPN is down!\n";
	}
	$status->setText($net_status);
	my $cursor = $status->textCursor;
	$cursor->movePosition(Qt::TextCursor::End());
	$status->setTextCursor($cursor);
	$status->repaint();

	this->{countrylist} = get_countries_for_combobox($serverCountryCombo);

	my $serverTypeLabel = Qt::Label(this->tr('Server Type: '));
	my $serverTypeCombo = Qt::ComboBox();

	$serverTypeCombo->addItem('TCP');
	$serverTypeCombo->addItem('UDP');

	if ($default_type eq "udp") {
		$serverTypeCombo->setCurrentIndex(1);
		this->{id_serverType} = 1;
	} else {
		$serverTypeCombo->setCurrentIndex(0);
		this->{id_serverType} = 0;
	}

	my $turnoffButton = Qt::PushButton(this->tr('Turn off'));
	this->{turnoffButton} = $turnoffButton;
	if ($nordvpn_status != NET_PROTECTED and $nordvpn_status != NET_CRIPPLED) {
		$turnoffButton->setEnabled(0);
	}
	$okButton = Qt::PushButton(this->tr('Refresh'));
	$cancelButton = Qt::PushButton(this->tr('S/U Pass'));
#	$cancelButton = Qt::PushButton(this->tr('Update'));
	this->{pwButton} = $cancelButton;

	$turnoffButton->setFont(Qt::Font("Times", 12, Qt::Font::Bold()));
	$cancelButton->setFont(Qt::Font("Times", 12, Qt::Font::Bold()));
	$okButton->setFont(Qt::Font("Times", 12, Qt::Font::Bold()));
	this->connect($cancelButton, SIGNAL "clicked()", this, SLOT "setUserInfo()");
	this->connect($okButton, SIGNAL "clicked()", this, SLOT 'updateDefaultVpn()');
	this->connect($turnoffButton, SIGNAL "clicked()", this, SLOT 'turnOffVpn()');

	this->connect($serverCountryCombo, SIGNAL 'activated(int)', this, SLOT 'setCountry(int)');
	this->connect($serverTypeCombo, SIGNAL 'activated(int)', this, SLOT 'setServerType(int)');
	
	my $verticalLayout = Qt::VBoxLayout();
	$verticalLayout->setContentsMargins(11, 11, 11, 11);
	my $titleLayout = Qt::HBoxLayout();
#	$titleLayout->addSpacing(40);
	$titleLayout->addWidget($image);
	$titleLayout->addStretch(1);
	my $statusLayout = Qt::HBoxLayout();
	$statusLayout->addWidget($status);
	$statusLayout->addStretch(1);

	my $vpnInfoLayout = Qt::HBoxLayout();
	$vpnInfoLayout->addWidget($serverCountryLabel);
	$vpnInfoLayout->addWidget($serverCountryCombo, 1);
	$vpnInfoLayout->addStretch(1);
	my $vpnTypeLayout = Qt::HBoxLayout();
	$vpnTypeLayout->addWidget($serverTypeLabel);
	$vpnTypeLayout->addSpacing(20);
	$vpnTypeLayout->addWidget($serverTypeCombo, 1);
	$vpnTypeLayout->addStretch(1);
	my $buttonLayout = Qt::HBoxLayout();
	$buttonLayout->addWidget($turnoffButton);
	$buttonLayout->addSpacing(150);
	$buttonLayout->addWidget($okButton);
	$buttonLayout->addSpacing(24);
	$buttonLayout->addWidget($cancelButton);
	$buttonLayout->addStretch(1);
	
	$verticalLayout->addLayout($titleLayout);
	$verticalLayout->addLayout($statusLayout);
	$verticalLayout->addLayout($vpnInfoLayout);
	$verticalLayout->addLayout($vpnTypeLayout);
	#$verticalLayout->addLayout($userinfoLayout);
	$verticalLayout->addLayout($buttonLayout);
	$centralWidget->setLayout($verticalLayout);
	this->setMinimumSize(Qt::Size(400, 240));
	this->setMaximumSize(Qt::Size(400, 240));

	setWindowTitle(this->tr('NordVPN Client'));
	this->setCentralWidget($centralWidget);

	my $pty;
	unless ($pty = IO::Pty::Easy->new) {
		my $status = this->{statusOutput};
		my $net_status = "Could not create new pty.  Reason: " . $! . "\n";
		$status->setText($net_status);
		my $cursor = $status->textCursor;
		$cursor->movePosition(Qt::TextCursor::End());
		$status->setTextCursor($cursor);
		$status->repaint();
		return(1);
	}
	this->{pty} = $pty;
}

sub is_vpn_active {
    return </sys/devices/virtual/net/tun*> ? 1 : 0;
}

sub get_countries_for_combobox {
    my $serverCountryCombo = shift;
    
    my $default_ccode = "de";
    my $default_type = "tcp";
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
			$retval = $a_text eq $b_text ? $a cmp $b : $country_code{$a_text} cmp $country_code{$b_text};
			$retval;
		} keys %$vpnlist) {
	if ($c =~ /([a-z][a-z])([0-9])/) {
	    $serverCountryCombo->addItem($country_code{$1}."-".$2);
	} else {
	    $serverCountryCombo->addItem($country_code{$c});
	}
	if ($default_ccode eq $c) {
	    $serverCountryCombo->setCurrentIndex($i);
	    this->{id_country} = $i;
	} else {
	    $i ++;
	}
	push @country, $c;
    }}

    # Dual VPN connections
    if (ENABLE_DUAL_VPN) {
    foreach $c (sort { # No support for 3 letter countries or digits at the end for now
		       # Also don't bother with equals since no digits
		       ($a_start, $a_end) = split('-', $a);
		       ($b_start, $b_end) = split('-', $b);
		       $a_text = $country_code{$a_start} . " - " . $country_code{$a_end};
		       $b_text = $country_code{$b_start} . " - " . $country_code{$b_end};
		       $a_text cmp $b_text;
		} keys %$duallist) {

	($a_start, $a_end) = split('-', $c);
	$a_text = $country_code{$a_start} . " - " . $country_code{$a_end};

	$serverCountryCombo->addItem($a_text);
	if ($default_ccode eq $c) {
	    # Who knows, someone might set tunneled VPN as the default, so might wanna implement the functionality here
	} else {
	    $i++
	}
	# These can be distinguished by the '-' in the $c
	push @country, $c;
    }}

    if (ENABLE_TOR_VPN) {
    foreach $c (sort {  $a_text = $a;
			$a_text = $a_text eq 'usa' ? 'usa' : substr($a_text,0,2);
			$b_text = $b;
			$b_text = $b_text eq 'usa' ? 'usa' : substr($b_text,0,2);
			$retval = $a_text eq $b_text ? $a cmp $b : $country_code{$a_text} cmp $country_code{$b_text};
			$retval;
		} keys %$torlist) {
	$a_text = "Tor : " . $country_code{$c};
	$serverCountryCombo->addItem($a_text);

	if ($default_ccode eq $c) {
	    # Right now there's no way for $c to contain info on tor enablement, so just don't do anything
	} else {
	    $i++
	}
	push @country, ("tor_" . $c);
    }}
    if (DEBUG > 0) {
	print STDERR "get_countries_for_combobox returning " . scalar(@country) . " entries\n";
	print STDERR "Countries: " . join(", ", @country) . "\n";
    }
    return \@country;
}

sub turnOffVpn
{
	my $status = this->{statusOutput};
	$net_status = "The VPN connection is deactivating,\n";
	$net_status .= "Please hold on...\n";
	$status->setText($net_status);
	my $cursor = $status->textCursor;
	$cursor->movePosition(Qt::TextCursor::End());
	$status->setTextCursor($cursor);
	$status->repaint();

	take_a_break();
	remove_dispatcher();
	disable_monitor();

	if (get_nordvpn_status() == NET_CRIPPLED) {
		undo_crippling();
		$net_status = "The VPN connection is deactivated.\n";
		$status->setText($net_status);
		my $cursor = $status->textCursor;
		$cursor->movePosition(Qt::TextCursor::End());
		$status->setTextCursor($cursor);
		$status->repaint();
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
		@active_lines = `/usr/bin/nmcli conn show --active | /usr/bin/grep nordvpn`;
	} else {
		# openSUSE 13.1 uses argument "conn status" 
		@active_lines = `/usr/bin/nmcli conn status | /usr/bin/grep nordvpn`;
	}
	my @active_conns = ();
	foreach my $conn (@active_lines) {
		if ($conn =~ /(\S+)/) {
			push @active_conns, $1;
		}
	}
	my $vpn_connection = get_vpn_connection(get_connections());
	my $pty = this->{pty};
	foreach my $conn (@$vpn_connection) {
		my $vpn_name = $conn->{connection}->{id};
		if ($vpn_name ~~ @active_conns) {
			try {
				print "deactivating " . $vpn_name . "\n" if DEBUG > 0;
				$pty->spawn("/usr/bin/nmcli conn down id $vpn_name && echo \"VPN deactivation successful\"");
				# wait for connection to close
				sleep(1);
				for (my $i = 0; $i < 10; $i ++) {
					if (!is_vpn_active()) { last; }
					sleep 1;
				}
			} catch {
				warn "caught error: $_\n";
			}
		}
	}
	system("pkill -9 openvpn");
#	force_refresh();	
	$internalTimer->start(5*1000);

	$net_status = "The VPN connection is deactivated.\n";
	$status->setText($net_status);
	$cursor->movePosition(Qt::TextCursor::End());
	$status->setTextCursor($cursor);
	$status->repaint();
	
	this->{turnoffButton}->setEnabled(0);
	return 0;
}

sub updateDefaultVpn
{

	$okButton->setEnabled(0);
	$buttonTimer->start(20000);

	take_a_break();
#	force_refresh();
	remove_dispatcher();

	my $status = this->{statusOutput};

	my $nordvpn_status = get_nordvpn_status();
	if ($nordvpn_status == NET_PROTECTED) { # i.e. vpn is up
		$net_status = "The VPN connection is deactivating,\n";
		$net_status .= "Please hold on...\n";
		$status->setText($net_status);
		my $cursor = $status->textCursor;
		$cursor->movePosition(Qt::TextCursor::End());
		$status->setTextCursor($cursor);
		$status->repaint();
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
			@active_lines = `/usr/bin/nmcli conn show --active | /usr/bin/grep nordvpn`;
		} else {
			# openSUSE 13.1 uses argument "conn status" 
			@active_lines = `/usr/bin/nmcli conn status | /usr/bin/grep nordvpn`;
		}
		my @active_conns = ();
		foreach my $conn (@active_lines) {
			if ($conn =~ /(\S+)/) {
				push @active_conns, $1;
			}
		}
		my $vpn_connection = get_vpn_connection(get_connections());
		my $pty = this->{pty};
		foreach my $conn (@$vpn_connection) {
			my $vpn_name = $conn->{connection}->{id};
			if ($vpn_name ~~ @active_conns) {
				try {
					print "deactivating " . $vpn_name . "\n" if DEBUG > 0;
					$pty->spawn("/usr/bin/nmcli conn down id $vpn_name && echo \"VPN deactivation successful\"");
					# wait for connection to close
					sleep(1);
					for (my $i = 0; $i < 10; $i ++) {
						if (!is_vpn_active()) { last; }
						sleep 1;
					}
				} catch {
					warn "caught error: $_\n";
				}
			}
		}
	} elsif ($nordvpn_status == NET_CRIPPLED) {
		undo_crippling();
	}

	# return to QT event loop for 4 seconds
	print "Start resume timer\n" if DEBUG > 0;
	$resumeTimer->start(2000);
}

sub updateDefaultVpnResume
{
	system("pkill -9 openvpn");
	$resumeTimer->stop;
	print "Resume activation of VPN\n" if DEBUG > 0;
	my $status = this->{statusOutput};

	my $countrylist = this->{countrylist};
	my $homedir = $ENV{HOME}.'/';
	my $configfiledir = "/etc/openvpn/";
	my $vpntype;

	print "Country ID is " . this->{id_country} . "\n" if DEBUG > 0;
	print "Countrylist is " . join(", ", @{$countrylist}) . "\n" if DEBUG > 0;
	my $ccode = (defined($countrylist) && scalar(@$countrylist) > this->{id_country}) ? $countrylist->[this->{id_country}] : '';
	my $stype = this->{id_serverType} == 0 ? 'tcp' : 'udp';
	my $configfile;

	if (-r $configfiledir."vpn-$ccode.nordvpn-$stype.ovpn") {
	    $configfile = $configfiledir."vpn-$ccode.nordvpn-$stype.ovpn";
	    $vpntype    = 'vpn';
	} elsif ($ccode =~ /\-/ && -r $configfiledir."double-$ccode.nordvpn-$stype.ovpn") {
	    # Dual tunnel
	    $configfile = $configfiledir."double-$ccode.nordvpn-$stype.ovpn";
	    $vpntype    = 'double';
	} elsif ($ccode =~ /tor\_(.*)/ && ($ccode = $1) && -r $configfiledir."tor-$ccode.nordvpn-$stype.ovpn") {
	    $configfile = $configfiledir."tor-$ccode.nordvpn-$stype.ovpn";
	    $vpntype    = 'tor';
	}

	return unless defined($configfile);

	print "config file: $configfile\n" if DEBUG > 0;

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
	my $return_code = set_default_vpn($configfile, $ccode, $stype, $vpntype);
	if ($return_code == 1) {
		$net_status .= "There is no any VPN connection!\n";
		$net_status .="Please set the username/password by clicking 'update',\n";
		$net_status .="it will install all vpn connections automatically.\n";
		$status->setText($net_status);
		my $cursor = $status->textCursor;
		$cursor->movePosition(Qt::TextCursor::End());
		$status->setTextCursor($cursor);
		$status->repaint();
		$internalTimer->start(10*60*1000);
	} elsif ($return_code !=0) {
		$net_status = "Unexcepted Error.\n";
		$status->setText($net_status);
		my $cursor = $status->textCursor;
		$cursor->movePosition(Qt::TextCursor::End());
		$status->setTextCursor($cursor);
		$status->repaint();
		$internalTimer->start(10*60*1000);
	}else {
		$net_status = "The VPN connection will be activated,\n";
		$net_status .= "Please hold on...\n";
		$status->setText($net_status);
		my $cursor = $status->textCursor;
		$cursor->movePosition(Qt::TextCursor::End());
		$status->setTextCursor($cursor);
		$status->repaint();
		$internalTimer->start(5*1000);
	}
	enable_monitor();
}

sub showNetStatus {
	my $status = this->{statusOutput};
	my $nordvpn_status = get_net_status();
	if ($nordvpn_status == NET_UNPROTECTED || $nordvpn_status == NET_PROTECTED) {
		$net_status = "The network is online!\n";
	} elsif ($nordvpn_status == NET_CRIPPLED) {
		$net_status .= "The network is in safemode!\n";
	} else {
		$net_status = "The network is offline!\n";
	}
	if ($nordvpn_status == NET_PROTECTED) {
		$net_status .= "The Nord VPN is up!\n";
		this->{turnoffButton}->setEnabled(1);
	} elsif ($nordvpn_status == NET_CRIPPLED) {
		$net_status .= "The Nord VPN is down!\n";
		this->{turnoffButton}->setEnabled(1);
	} else {
		$net_status .= "The Nord VPN is down!\n";
		this->{turnoffButton}->setEnabled(0);
	}

	print "$net_status.\n" if DEBUG > 0;
	$status->setText($net_status);
	my $cursor = $status->textCursor;
	$cursor->movePosition(Qt::TextCursor::End());
	$status->setTextCursor($cursor);
	$status->repaint();
	return($nordvpn_status);
}

sub setUserInfo {
	$cancelButton->setEnabled(0);
	my $tmp = getUserInfo();
	my %userInfo = %$tmp;
	my $status = this->{statusOutput};
	if ($userInfo{code} == 1) {
		$net_status = "Note: There is no any connection in your system\n";
		$status->setText($net_status);
		my $cursor = $status->textCursor;
		$cursor->movePosition(Qt::TextCursor::End());
		$status->setTextCursor($cursor);
		$status->repaint();
		$userInfo{username} = "";
		$userInfo{password} = "";
	} elsif ($userInfo{code} == 2) {
		$net_status = "Note: Can not open your connection file\n";
		$status->setText($net_status);
		my $cursor = $status->textCursor;
		$cursor->movePosition(Qt::TextCursor::End());
		$status->setTextCursor($cursor);
		$status->repaint();
		return $userInfo{code};
	}
	my ($ok, $password);
	my $username = Qt::InputDialog::getText(this, this->tr('Input'),
	this->tr('User name:'), Qt::LineEdit::Normal(),
	$userInfo{username}, $ok);
	if ($ok && $username) {
		this->{username} = $username;
		$password = Qt::InputDialog::getText(this, this->tr('Input'),
		this->tr('Password:'), Qt::LineEdit::Password(),
		$userInfo{password}, $ok);
		if ($ok && $password) {
			this->{password} = $password;
		}
	}

	my $ac_rc; # add_connections() return code
	if ($ok) {
	    $ac_rc = add_connections($username, $password);
	    if ($ac_rc == 0) {
		while (</etc/openvpn/*.ovpn>) {
		    copy($_,$_ . '.bak');
		    # TODO: what do we do after copying?
		}
	    }
	    else {
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
		my $status = this->{statusOutput};
		$net_status = "Note: Can not create all connections for you\n";
		$status->setText($net_status);
		my $cursor = $status->textCursor;
		$cursor->movePosition(Qt::TextCursor::End());
		$status->setTextCursor($cursor);
		$status->repaint();
		return $userInfo{code};
	    }
	}

	# reread country list
	$serverCountryCombo->clear();
	this->{countrylist} = get_countries_for_combobox($serverCountryCombo);

	# load new system connection into NetworkManager
	system("/sbin/service network force-reload");

	$net_status = "Successful to set the Username and password!\n";
	$status->setText($net_status);
	my $cursor = $status->textCursor;
	$cursor->movePosition(Qt::TextCursor::End());
	$status->setTextCursor($cursor);
	$status->repaint();
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

	my $countrycode = $countrylist[$country];
	my $servertype = $server == 0 ? "tcp" : "udp";

	my $kind = "";
	if (-e "/etc/NetworkManager/system-connections/vpn-$countrycode.nordvpn-$servertype") {
		$kind = "vpn";
	} elsif (-e "/etc/NetworkManager/system-connections/tor-$countrycode.nordvpn-$servertype") {
		$kind = "tor";
	} elsif (-e "/etc/NetworkManager/system-connections/double-at-$countrycode.nordvpn-$servertype") {
		$kind = "double-at";
	}
	if ($kind eq "") {
		$userInfo{code} = 1; # there is empty connection file
		return \%userInfo;
	}

	open my $file, "/etc/NetworkManager/system-connections/$kind-$countrycode.nordvpn-$servertype" or $userInfo{code} = 2;
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

sub setCountry
{
	my ($country) = @_;
	this->{id_country} = $country;
	print "country: ", $country."\n" if DEBUG > 0;
}

sub setServerType
{
	my ($type) = @_;
	this->{id_serverType} = $type;
	print "type: ", $type."\n" if DEBUG > 0;
}

### helper functions
sub getCountryList
{
	my $vpnlist  = ();
	my $duallist = ();
	my $torlist  = {};
	my $filedir  = '/etc/openvpn/';

	my $dir;
	my @tmplist;
	my $file;
	my $type;
	my $country;
	my $start;
	my $proto;

	if (opendir $dir, $filedir) {
	    my @tmplist = readdir $dir;
	    closedir $dir;
	    
	    foreach my $file (@tmplist) {
		next unless ($file =~ /(vpn|tor|double-(\w{2}))-([a-z][a-z][a-z0-9]?)\.nordvpn-(tcp|udp)\.ovpn/i);
		($type, $start, $country, $proto) = ($1, $2, $3, $4);
		if ($type eq 'vpn' ) {
		    $vpnlist->{$country} = 1;
		} elsif ($type eq 'tor') {
		    $torlist->{$country} = 1;
		} else { # $type eq 'double-'
		    $duallist->{$start . "-" . $country} = 1;
		}
	    }
	}
	print "Returning " . scalar(keys %$vpnlist) . " VPN configs, " . scalar(keys %$torlist) . " TOR configs, and " . scalar(keys %$duallist) . " tunneled VPN configs\n" if DEBUG > 1;
	return wantarray ? ($vpnlist, $duallist, $torlist) : $vpnlist;
}

sub get_connections
{
	my $object = Net::DBus->system
		->get_service("org.freedesktop.NetworkManager")
		->get_object("/org/freedesktop/NetworkManager/Settings",
				 "org.freedesktop.NetworkManager.Settings");

	return $object->ListConnections();
}

sub get_vpn_connection
{
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

sub set_default_vpn
{
	my ($configfile, $ccode, $type, $vpntype) = @_;
	my $uuid = "";
	my $remote = "";
	my $return_code = 0;
	my $pty = this->{pty};
	my $spawn_out;

	print STDERR "Setting default vpn: \$configfile = '$configfile', \$ccode = '$ccode', \$type = '$type', \$vpntype = '$vpntype'\n" if DEBUG > 0;

	my $sysconnections = "/etc/NetworkManager/system-connections/";
	my $id = $vpntype . "-" . $ccode . ".nordvpn-" . $type;
	if (-r $sysconnections . $id &&
	    -r '/etc/ca-certificates/' . $id . ".ca" &&
	    -r '/etc/ca-certificates/' . $id . ".auth") {
	    unless (open IN, $sysconnections.$id) {
		my $status = this->{statusOutput};
		my $net_status = "Could not open VPN config file for reading. Reason: " . $! . "\n";
		$status->setText($net_status);
		my $cursor = $status->textCursor;
		$cursor->movePosition(Qt::TextCursor::End());
		$status->setTextCursor($cursor);
		$status->repaint();
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
		$pty->spawn("/usr/bin/nmcli conn up uuid $uuid && echo \"VPN activation successful\"");
	    } catch {
		warn "caught error: $_\n";
		$return_code = 2;
	    };

	} else {
	    my $status = this->{statusOutput};
	    $net_status .= "No system connection file found.\n";
	    this->{statusOutput} = $status;
	    return 1;
	}
	if ($uuid eq "") {
	    $return_code = 1;
	}
	if ($return_code != 0) {
	    return $return_code;
	}

	my $vpn_ini;
	unless (open $vpn_ini, ">", INI_FILE) {
		my $status = this->{statusOutput};
		my $net_status = "Could not create '" . INI_FILE . "'  Reason: " . $! . "\n";
		$status->setText($net_status);
		my $cursor = $status->textCursor;
		$cursor->movePosition(Qt::TextCursor::End());
		$status->setTextCursor($cursor);
		$status->repaint();
		return(1);
	}	print $vpn_ini "[default-vpn]\n";
	print $vpn_ini "id=$id\n";
	print $vpn_ini "uuid=$uuid\n";
	print $vpn_ini "remote=$remote\n";
	print $vpn_ini "monitor=enabled\n";
	close $vpn_ini;

	### set the vpn to start after boot
	my $vpn_d;
	unless (open $vpn_d, ">", DISPATCH_FILE) {
		my $status = this->{statusOutput};
		my $net_status = "Could not create '" . DISPATCH_FILE . "'  Reason: " . $! . "\n";
		$status->setText($net_status);
		my $cursor = $status->textCursor;
		$cursor->movePosition(Qt::TextCursor::End());
		$status->setTextCursor($cursor);
		$status->repaint();
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

sub updateStatus
{
#	print "I am updateStatus!\n" if DEBUG > 0;
	print "." if DEBUG > 0;
	my $status = this->{statusOutput};
	my $pty = this->{pty};
	my $active_flag = $pty->is_active();
	while ( my $output = $pty->read(0) ) {
		$net_status .= $output;
		$active_flag = 1;
	}
	if ($active_flag) {
			$internalTimer->start(1000);
		$last_pty_read = time();
	} else {
		if ( time() - $last_pty_read > 5*60 ) { # keep text for 5 min
			my $nordvpn_status = showNetStatus();
			if ($nordvpn_status == NET_PROTECTED) {
				$internalTimer->start(5*60*1000);
			} else {
				$internalTimer->start(60*1000);
			}
		} elsif ( time() - $last_pty_read > 60 ) { # slow down refresh after 1 minute
			$internalTimer->start(20*1000);
		}
	}

	my $current_status = get_net_status();
	my $tmp_previous = $previous_status;
	$previous_status = $current_status;

	if ($current_status == NET_BROKEN && $tmp_previous != NET_BROKEN) {
		$net_status .= "Network state changed to NET_BROKEN.\n";
	}
	elsif ($current_status == NET_ERROR && $tmp_previous != NET_ERROR) {
		$net_status .= "Network state changed to NET_ERROR.\n";
	}
	elsif ($current_status == NET_UNKNOWN && $tmp_previous != NET_UNKNOWN) {
		$net_status .= "Network state changed to NET_UNKNOWN.\n";
	}
	if ($tmp_previous == NET_CRIPPLED && $current_status != NET_CRIPPLED) {
		$cancelButton->setEnabled(1);
		$net_status .= "Network restored from safemode.\n";
	}
	if ($current_status == NET_CRIPPLED && $tmp_previous != NET_CRIPPLED) {
		$cancelButton->setEnabled(0);
		$net_status .= "Network placed in safemode, check VPN settings.\n";
	}
	if ($current_status == NET_PROTECTED && $tmp_previous != NET_PROTECTED) {
		$okButton->setEnabled(1);
		$buttonTimer->stop();
		this->{turnoffButton}->setEnabled(1);
	}

	$status->setText($net_status);
	my $cursor = $status->textCursor;
	$cursor->movePosition(Qt::TextCursor::End());
	$status->setTextCursor($cursor);
	$status->repaint();
}

sub reenableButton {
    $okButton->setEnabled(1);
    $buttonTimer->stop();
}

1;

