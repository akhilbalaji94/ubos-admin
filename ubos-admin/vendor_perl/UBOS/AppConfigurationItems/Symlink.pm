#!/usr/bin/perl
#
# An AppConfiguration item that is a symbolic link.
#
# This file is part of ubos-admin.
# (C) 2012-2017 Indie Computing Corp.
#
# ubos-admin is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# ubos-admin is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with ubos-admin.  If not, see <http://www.gnu.org/licenses/>.
#

use strict;
use warnings;

package UBOS::AppConfigurationItems::Symlink;

use base qw( UBOS::AppConfigurationItems::AppConfigurationItem );
use fields;

use UBOS::Logging;

##
# Constructor
# $json: the JSON fragment from the manifest JSON
# $role: the Role to which this item belongs to
# $appConfig: the AppConfiguration object that this item belongs to
# $installable: the Installable to which this item belongs to
# return: the created File object
sub new {
    my $self        = shift;
    my $json        = shift;
    my $role        = shift;
    my $appConfig   = shift;
    my $installable = shift;

    unless( ref $self ) {
        $self = fields::new( $self );
    }
    $self->SUPER::new( $json, $role, $appConfig, $installable );

    return $self;
}

##
# Install this item, or check that it is installable.
# $doIt: if 1, install; if 0, only check
# $defaultFromDir: the directory to which "source" paths are relative to
# $defaultToDir: the directory to which "destination" paths are relative to
# $config: the Configuration object that knows about symbolic names and variables
# return: success or fail
sub deployOrCheck {
    my $self           = shift;
    my $doIt           = shift;
    my $defaultFromDir = shift;
    my $defaultToDir   = shift;
    my $config         = shift;

    my $ret   = 1;
    my $names = $self->{json}->{names};
    unless( $names ) {
        $names = [ $self->{json}->{name} ];
    }
    my $source = $self->{json}->{source};

    debug( 'Symlink::deployOrCheck', $doIt, $defaultFromDir, $defaultToDir, $source, @$names );

    my $uname        = $self->{json}->{uname};
    my $gname        = $self->{json}->{gname};

    foreach my $name ( @$names ) {
        my $localName  = $name;
        $localName =~ s!^.+/!!;

        my $fromName = $source;
        $fromName =~ s!\$1!$name!g;      # $1: name
        $fromName =~ s!\$2!$localName!g; # $2: just the name without directories

        $fromName = $config->replaceVariables( $fromName );

        my $toName = $name;
        $toName = $config->replaceVariables( $toName );

        unless( $fromName =~ m#^/# ) {
            $fromName = "$defaultFromDir/$fromName";
        }
        unless( $toName =~ m#^/# ) {
            $toName = "$defaultToDir/$toName";
        }
        if( -e $fromName ) {
            if( $doIt ) {
                unless( -e $toName ) {
                    # These names sound a little funny for symlinks. Think "copy" instead of "link"
                    # and they make sense. We keep the names for consistency with other items.
                    # $fromName: the destination of the link
                    # $toName: the source of the link
                    UBOS::Utils::symlink( $fromName, $toName, $uname, $gname );
                } else {
                    error( 'Symlink::deployOrCheck: Cannot create symlink:', $toName );
                    $ret = 0;
                }
            }

        } else {
            # Cannot produce error message here, because some AppConfigItem before this one
            # might have created it.
        }
    }
    return $ret;
}

##
# Uninstall this item, or check that it is uninstallable.
# $doIt: if 1, uninstall; if 0, only check
# $defaultFromDir: the directory to which "source" paths are relative to
# $defaultToDir: the directory to which "destination" paths are relative to
# $config: the Configuration object that knows about symbolic names and variables
# return: success or fail
sub undeployOrCheck {
    my $self           = shift;
    my $doIt           = shift;
    my $defaultFromDir = shift;
    my $defaultToDir   = shift;
    my $config         = shift;

    my $ret   = 1;
    my $names = $self->{json}->{names};
    unless( $names ) {
        $names = [ $self->{json}->{name} ];
    }
    my $source = $self->{json}->{source};

    debug( 'Symlink::undeployOrCheck', $doIt, $defaultFromDir, $defaultToDir, $source, @$names );

    foreach my $name ( @$names ) {
        my $toName = $name;
        $toName = $config->replaceVariables( $toName );

        unless( $toName =~ m#^/# ) {
            $toName = "$defaultToDir/$toName";
        }

        if( $doIt ) {
            if( -e $toName ) {
                $ret &= UBOS::Utils::deleteFile( $toName );

            } else {
                error( 'Symlink::undeployOrCheck: file does not exist:', $toName );
                $ret = 0;
            }
        }
    }
    return $ret;
}

1;
