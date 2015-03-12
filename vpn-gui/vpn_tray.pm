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

use vpn_window;
use vpn_ipc qw(getMonitorState);
use QtCore4;
use QtGui4;
use QtCore4::isa qw(Qt::Dialog);
use QtCore4::slots
    setIcon => [],
    showMessage => [],
    iconActivated => ['QSystemTrayIcon::ActivationReason'],
    hideWindow => [],
    messageClicked => [];
use File::Basename;


# monitor state / net status
use constant {
	UNPROTECTED => 0,
	PROTECTED   => 1,
	OFFLINE     => 2,
	BROKEN      => 2,
	ERROR       => 2,	# OFFLINE, BROKEN and ERROR use same icon
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
	my $index = ERROR;

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
			$index = ERROR;
		} elsif ( $task eq "retrying" || $task eq "temporary" ) {
			$index = REFRESH;
		} elsif ( $task eq "crippled" || $task eq "uncrippling" || $network eq "CRIPPLED") {
			$index = CRIPPLED;
		} elsif ( $network eq "UNPROTECTED" ) {
			$index = UNPROTECTED;
		} elsif ( $network eq "PROTECTED" || $network eq "CONFIRMING" || $network eq "UNCONFIRMED") {
			$index = PROTECTED;
		} elsif ( $network eq "BROKEN" || $network eq "OFFLINE" ) {
			$index = BROKEN;
		}

		if ( $monitor eq "Enabled" ) {
			$index = $index + GUARD;
		}
	}

	my $icon = this->{iconComboBox}->itemIcon($index);
	this->{trayIcon}->setIcon($icon);
	this->{windowIcon} = $icon;
	this->{trayIcon}->setToolTip(this->{iconComboBox}->itemText($index));

# temporary debug code
print "\tSystray - State change current_state = $current_state_string\tindex = $index\n";

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


sub hideWindow
{
	my $window = this->{MainWindow};
	$window->hide();
	this->{show} = 0;
	setVisible(this->{show});
}


sub createIconGroupBox
{
	this->{iconGroupBox} = Qt::GroupBox(this->tr('Tray Icon'));

	this->{iconLabel} = Qt::Label('Icon:');

	this->{iconComboBox} = Qt::ComboBox();

	# icon for monitor disabled
	this->{iconComboBox}->insertItem( UNPROTECTED , 
	   Qt::Icon(dirname($0).'/images/tray-unprotected-ignore.png'), this->tr('Unprotected'));
	this->{iconComboBox}->insertItem( PROTECTED , 
	   Qt::Icon(dirname($0).'/images/tray-protected-ignore.png'), this->tr('Protected'));
	this->{iconComboBox}->insertItem( BROKEN , 
	   Qt::Icon(dirname($0).'/images/tray-broken-ignore.png'), this->tr('Offline'));
	this->{iconComboBox}->insertItem( CRIPPLED , 
	   Qt::Icon(dirname($0).'/images/tray-crippled-guard.png'), this->tr('Safe-Mode'));
	this->{iconComboBox}->insertItem( REFRESH , 
	   Qt::Icon(dirname($0).'/images/tray-refresh-guard.png'), this->tr('Refreshing'));

	# icon for monitor enabled
	this->{iconComboBox}->insertItem( UNPROTECTED+GUARD , 
	   Qt::Icon(dirname($0).'/images/tray-unprotected-guard.png'), this->tr('Unprotected'));
	this->{iconComboBox}->insertItem( PROTECTED+GUARD , 
	   Qt::Icon(dirname($0).'/images/tray-protected-guard.png'), this->tr('Protected'));
	this->{iconComboBox}->insertItem( BROKEN+GUARD , 
	   Qt::Icon(dirname($0).'/images/tray-broken-guard.png'), this->tr('Offline'));
	this->{iconComboBox}->insertItem( CRIPPLED+GUARD , 
	   Qt::Icon(dirname($0).'/images/tray-crippled-guard.png'), this->tr('Safe-Mode'));
	this->{iconComboBox}->insertItem( REFRESH+GUARD , 
	   Qt::Icon(dirname($0).'/images/tray-refresh-guard.png'), this->tr('Refreshing'));

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

	this->{quitAction} = Qt::Action(this->tr('&Quit'), this);
	this->connect(this->{quitAction}, SIGNAL 'triggered()', qApp, SLOT 'quit()');
}


sub createTrayIcon
{
	this->{trayIconMenu} = Qt::Menu(this);
	this->{trayIconMenu}->addAction(this->{minimizeAction});
	this->{trayIconMenu}->addAction(this->{maximizeAction});
	this->{trayIconMenu}->addSeparator();
	this->{trayIconMenu}->addAction(this->{quitAction});

	this->{trayIcon} = Qt::SystemTrayIcon(this);
	this->{trayIcon}->setContextMenu(this->{trayIconMenu});
}

1;
