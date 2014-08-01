#!/usr/bin/perl
#
# A network configuration for a device that expects a network controller
# on the network that provides network services such as DHCP, DNS etc.
#
# This file is part of indiebox-networking.
# (C) 2012-2014 Indie Computing Corp.
#
# indiebox-networking is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# indiebox-networking is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with indiebox-networking.  If not, see <http://www.gnu.org/licenses/>.
#

use strict;
use warnings;

package IndieBox::Networking::NetConfigs::Client;

##
# Determine whether this network configuration could currently be activated.
# This return false, if, for example, this network configuration requires two
# ethernet interfaces, but the device has only one ethernet interface attached.
# This will also return true if this configuration is currently active.
# return: 1 or 0
sub isPossible {
    my $allNics = IndieBox::Networking::NetConfigUtils::getAllNics();
    
    return ( keys %$allNics ) > 0;
}

##
# Activate this network configuration.
sub activate {
    IndieBox::Networking::NetConfigUtils::setNetConfig( 1, undef );
}

##
# Return help text for this network configuration
# return: help text
sub help {
    return 'Connect to a network as DHCP and DNS client.';
}

1;