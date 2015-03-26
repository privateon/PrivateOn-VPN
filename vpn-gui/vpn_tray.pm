package vpn_tray;

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
use feature 'state';

use QtCore4;
use QtGui4;
use QtCore4::isa qw(Qt::Dialog);
use QtCore4::slots
    setIcon => [],
    showMessage => [],
    iconActivated => ['QSystemTrayIcon::ActivationReason'],
    hideWindow => [],
    messageClicked => [],
    showAbout => [];
use File::Basename qw(dirname);
use vpn_ipc qw(getMonitorState);


# monitor state / net status
use constant {
	UNPROTECTED => 0,	# UNPROTECTED and NEGATIVE use the same icon
	PROTECTED   => 1,	# PROTECTED, CONFIRMING and UNCONFIRMED use the same icon
	OFFLINE     => 2,	# OFFLINE, BROKEN and ERROR use the same icon
	CRIPPLED    => 3,
	REFRESH     => 4,
	GUARD       => 5	# Increment GUARD to basic state, e.g. PROTECTED+GUARD
};


sub NEW
{
	my ( $class, $window) = @_;
	$class->SUPER::NEW();
	this->{MainWindow} = $window;
	this->{show} = 0;
	this->findIconPath();
	this->createIconGroupBox();

	my $internalTimer = Qt::Timer(this);  # create internal timer
	this->connect($internalTimer, SIGNAL('timeout()'), SLOT('setIcon()'));
	$internalTimer->start(10000);	  # emit signal every 10 second
	this->{timer} = $internalTimer;

	this->createActions();
	this->createTrayIcon();

	this->connect(this->{showIconCheckBox}, SIGNAL 'toggled(bool)', this->{trayIcon}, SLOT 'setVisible(bool)');
	this->connect(this->{trayIcon}, SIGNAL 'messageClicked()', this, SLOT 'messageClicked()');
	this->connect(this->{trayIcon}, SIGNAL 'activated(QSystemTrayIcon::ActivationReason)', this, SLOT 'iconActivated(QSystemTrayIcon::ActivationReason)');

	setIcon();

	my $mainLayout = Qt::VBoxLayout();
	$mainLayout->addWidget(this->{iconGroupBox});
	this->setLayout($mainLayout);

	# define about-window
	this->{about} = Qt::MessageBox(this);
	this->{about}->setWindowModality(Qt::NonModal());
	this->{about}->setWindowTitle(this->tr('About PrivateOn VPN'));
	this->{about}->setText('PrivateOn VPN<br>&nbsp;&nbsp;Version 0.9');
this->{about}->setDetailedText('             PrivateOn VPN  -  Privacy Software
                 Version 0.9  (GitHub Release)
      
        VPN Manager for configuring, monitoring 
               and controlling VPN connections.

                    Copyright (C) 2014-2015
    PrivateOn / Tietosuojakone Oy, Helsinki, Finland
  All rights reserved. Use is subject to license terms.
                  License:  Artistic License 2.0
');
	this->{about}->setIconPixmap(Qt::Pixmap( this->{iconPath} . '/PrivateOn-logo.png' ));
	this->{about}->addButton(this->tr('Close'), Qt::MessageBox::AcceptRole());

	this->{iconComboBox}->setCurrentIndex(1);
	this->{trayIcon}->show();

	this->setWindowTitle(this->tr('Systray'));
	this->resize(400, 300);
}


sub iconActivated
{
	my ($reason) = @_;
	if ($reason == Qt::SystemTrayIcon::Trigger()) {
		if (this->{show} == 0) {
			showMessage();
		} else {
			hideWindow();
		}
	}
}


sub setVisible
{
	my ($visible) = @_;
	$visible = this->{show};
	this->{minimizeAction}->setEnabled($visible);
	this->{maximizeAction}->setEnabled(!$visible);
}


sub setIcon
{
	my $index = OFFLINE;

	state $previous_state_string = "";
	my $current_state_string = getMonitorState();

	# do nothing if state has not changed
	if ($current_state_string eq $previous_state_string) {
		this->{timer}->start(10000);    # next setIcon in 10 seconds
		return;
	}

	# if we got this far, something has changed
	if ($current_state_string =~ /(\S+)-(\S+)-(\S+)/) {
		my $monitor = $1;
		my $task = $2;
		my $network = $3;

		if ( $task eq "unknown" || $network eq "UNKNOWN" || $network eq "ERROR" ) {
			$index = OFFLINE;
		} elsif ( $task eq "retrying" || $task eq "temporary" ) {
			$index = REFRESH;
		} elsif ( $task eq "crippled" || $task eq "uncrippling" || $network eq "CRIPPLED" ) {
			$index = CRIPPLED;
		} elsif ( $network eq "UNPROTECTED" || $network eq "NEGATIVE" ) {
			$index = UNPROTECTED;
		} elsif ( $network eq "PROTECTED" || $network eq "CONFIRMING" || $network eq "UNCONFIRMED" ) {
			$index = PROTECTED;
		} elsif ( $network eq "BROKEN" || $network eq "OFFLINE" ) {
			$index = OFFLINE;
		}

		if ( $monitor eq "Enabled" ) {
			$index = $index + GUARD;
		}
	}

	my $icon = this->{iconComboBox}->itemIcon($index);
	this->{trayIcon}->setIcon($icon);
	this->{windowIcon} = $icon;
	this->{trayIcon}->setToolTip(this->{iconComboBox}->itemText($index));

	this->{timer}->start(10000);	# next setIcon in 10 seconds
	$previous_state_string = $current_state_string;
	return;
}


sub showMessage
{
	my $window = this->{MainWindow};
	if ($window->isMaximized()) {
		$window->hide();
		this->{show} = 0;
	} else {
		$window->resize(640, 256);
		$window->show();
		this->{show} = 1;
	}
	setVisible(this->{show});
}


sub showAbout
{
	this->{about}->show();
	# move about-window to the center of the screen
	my $screen_width = Qt::Application::desktop()->availableGeometry()->width();
	my $screen_height = Qt::Application::desktop()->availableGeometry()->height();
	my $about_width = this->{about}->width();
	my $about_height = this->{about}->height();
	this->{about}->move( ($screen_width-$about_width)/2 , ($screen_height-$about_height)/2 );
}


sub hideWindow
{
	my $window = this->{MainWindow};
	$window->hide();
	this->{show} = 0;
	setVisible(this->{show});
}


sub findIconPath
{
	# find path to images directory, resolve symlink if necessary
	my $images_path;
	if ( -l $0 ) {
		$images_path = dirname(readlink($0)) . '/images';
	} else {
		$images_path = dirname($0) . '/images';
	}
	this->{iconPath} = $images_path;
}


sub createIconGroupBox
{
	this->{iconGroupBox} = Qt::GroupBox(this->tr('Tray Icon'));
	this->{iconLabel} = Qt::Label('Icon:');
	this->{iconComboBox} = Qt::ComboBox();



	# icon for monitor disabled
	this->{iconComboBox}->insertItem( UNPROTECTED , 
	   Qt::Icon(this->{iconPath} . '/tray-unprotected-ignore.png'), this->tr('Unprotected'));
	this->{iconComboBox}->insertItem( PROTECTED , 
	   Qt::Icon(this->{iconPath} . '/tray-protected-ignore.png'), this->tr('Protected'));
	this->{iconComboBox}->insertItem( OFFLINE , 
	   Qt::Icon(this->{iconPath} . '/tray-broken-ignore.png'), this->tr('Offline'));
	this->{iconComboBox}->insertItem( CRIPPLED , 
	   Qt::Icon(this->{iconPath} . '/tray-crippled-guard.png'), this->tr('Safe-Mode'));
	this->{iconComboBox}->insertItem( REFRESH , 
	   Qt::Icon(this->{iconPath} . '/tray-refresh-guard.png'), this->tr('Refreshing'));

	# icon for monitor enabled
	this->{iconComboBox}->insertItem( UNPROTECTED+GUARD , 
	   Qt::Icon(this->{iconPath} . '/tray-unprotected-guard.png'), this->tr('Unprotected'));
	this->{iconComboBox}->insertItem( PROTECTED+GUARD , 
	   Qt::Icon(this->{iconPath} . '/tray-protected-guard.png'), this->tr('Protected'));
	this->{iconComboBox}->insertItem( OFFLINE+GUARD , 
	   Qt::Icon(this->{iconPath} . '/tray-broken-guard.png'), this->tr('Offline'));
	this->{iconComboBox}->insertItem( CRIPPLED+GUARD , 
	   Qt::Icon(this->{iconPath} . '/tray-crippled-guard.png'), this->tr('Safe-Mode'));
	this->{iconComboBox}->insertItem( REFRESH+GUARD , 
	   Qt::Icon(this->{iconPath} . '/tray-refresh-guard.png'), this->tr('Refreshing'));

	# check that we got all icons, 5 basic states * 2 Enabled/disabled
	if ( this->{iconComboBox}->count() < 10 ) {
		print "\nError: Some icons failed to load. Icon count = " . this->{iconComboBox}->count() . "/10 \n";
	}

	this->{showIconCheckBox} = Qt::CheckBox(this->tr('Show icon'));
	this->{showIconCheckBox}->setChecked(1);

	my $iconLayout = Qt::HBoxLayout();
	$iconLayout->addWidget(this->{iconLabel});
	$iconLayout->addWidget(this->{iconComboBox});
	$iconLayout->addStretch();
	$iconLayout->addWidget(this->{showIconCheckBox});
	this->{iconGroupBox}->setLayout($iconLayout);
}


sub createActions
{
	this->{minimizeAction} = Qt::Action(this->tr('Mi&nimize'), this);
	this->connect(this->{minimizeAction}, SIGNAL 'triggered()', this, SLOT 'hideWindow()');

	this->{maximizeAction} = Qt::Action(this->tr('&Restore'), this);
	this->connect(this->{maximizeAction}, SIGNAL 'triggered()', this, SLOT 'showMessage()');

	this->{aboutAction} = Qt::Action(this->tr('&About'), this);
	this->connect(this->{aboutAction}, SIGNAL 'triggered()', this, SLOT 'showAbout()');

	this->{quitAction} = Qt::Action(this->tr('&Quit'), this);
	this->connect(this->{quitAction}, SIGNAL 'triggered()', qApp, SLOT 'quit()');
}


sub createTrayIcon
{
	this->{trayIconMenu} = Qt::Menu(this);
	this->{trayIconMenu}->addAction(this->{minimizeAction});
	this->{trayIconMenu}->addAction(this->{maximizeAction});
	this->{trayIconMenu}->addAction(this->{aboutAction});
	this->{trayIconMenu}->addSeparator();
	this->{trayIconMenu}->addAction(this->{quitAction});

	this->{trayIcon} = Qt::SystemTrayIcon(this);
	this->{trayIcon}->setContextMenu(this->{trayIconMenu});
}

1;
