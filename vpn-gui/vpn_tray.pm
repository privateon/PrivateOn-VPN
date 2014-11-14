package vpn_tray;

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
use QtCore4;
use QtGui4;
use MainWindow;
use File::Basename;
use vpn_status qw(get_nordvpn_status get_net_status);
use QtCore4::isa qw( Qt::Dialog );
use QtCore4::slots
    setIcon => [],
    showMessage => [],
    iconActivated => ['QSystemTrayIcon::ActivationReason'],
    hideWindow => [],
    messageClicked => [];

sub NEW
{
    my ( $class, $window) = @_;
    $class->SUPER::NEW();
    this->{MainWindow} = $window;
    this->{show} = 0;
    this->createIconGroupBox();

    my $internalTimer = Qt::Timer(this);  # create internal timer
    this->connect($internalTimer, SIGNAL('timeout()'), SLOT('setIcon()'));
    $internalTimer->start(0);	  # emit signal after 0 second
    this->{timer} = $internalTimer;

    this->createActions();
    this->createTrayIcon();

    this->connect(this->{showIconCheckBox}, SIGNAL 'toggled(bool)', this->{trayIcon}, SLOT 'setVisible(bool)');
    this->connect(this->{trayIcon}, SIGNAL 'messageClicked()', this, SLOT 'messageClicked()');
    this->connect(this->{trayIcon}, SIGNAL 'activated(QSystemTrayIcon::ActivationReason)', this, SLOT 'iconActivated(QSystemTrayIcon::ActivationReason)');

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
    my ($index) = @_;
    
    if (get_net_status() != 0) {
        $index = 0; # network is down
    } else {
        if (get_nordvpn_status() == 1) {
            $index = 1; # vpn is up
        } else {
            $index = 2; # vpn is down
        }
    }
    my $icon = this->{iconComboBox}->itemIcon($index);
    this->{trayIcon}->setIcon($icon);
    this->{windowIcon} = $icon;

    this->{trayIcon}->setToolTip(this->{iconComboBox}->itemText($index));
    this->{timer}->start(1000 * 10);
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
    this->{iconComboBox}->addItem(Qt::Icon(dirname($0).'/images/protected.png'), this->tr('Protected'));
    this->{iconComboBox}->addItem(Qt::Icon(dirname($0).'/images/unprotected.png'), this->tr('Unprotected'));
    this->{iconComboBox}->addItem(Qt::Icon(dirname($0).'/images/broken.png'), this->tr('No Net'));

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
