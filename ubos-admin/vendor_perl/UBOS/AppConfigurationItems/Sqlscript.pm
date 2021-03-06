#!/usr/bin/perl
#
# An AppConfiguration item that is a SQL script to be run.
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

# FIXME: This currently only works with MySQL

use strict;
use warnings;

package UBOS::AppConfigurationItems::Sqlscript;

use base qw( UBOS::AppConfigurationItems::AppConfigurationItem );
use fields;

use UBOS::Databases::MySqlDriver;
use UBOS::Logging;
use UBOS::Utils qw( saveFile slurpFile );

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

    debug( 'Sqlscript::deployOrCheck', $doIt, $defaultFromDir, $defaultToDir );

    return $self->_runIt( $doIt, $defaultFromDir, $defaultToDir, $config );
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

    # do nothing

    debug( 'Sqlscript::undeployOrCheck', $doIt, $defaultFromDir, $defaultToDir );

    return 1;
}

##
# Run a post-deploy Perl script. May be overridden.
# $methodName: the type of post-install
# $defaultFromDir: the package directory
# $defaultToDir: the directory in which the installable was installed
# $config: the Configuration object that knows about symbolic names and variables
# return: success or fail
sub runPostDeployScript {
    my $self           = shift;
    my $methodName     = shift;
    my $defaultFromDir = shift;
    my $defaultToDir   = shift;
    my $config         = shift;

    return $self->_runIt( 1, $defaultFromDir, $defaultToDir, $config );
}

##
# Factored out run method for install and runPostDeploy
sub _runIt {
    my $self           = shift;
    my $doIt           = shift;
    my $defaultFromDir = shift;
    my $defaultToDir   = shift;
    my $config         = shift;
    
    my $ret              = 1;
    my $sourceOrTemplate = $self->{json}->{template};
    unless( $sourceOrTemplate ) {
        $sourceOrTemplate = $self->{json}->{source};
    }
    my $templateLang = $self->{json}->{templatelang};
    my $delimiter    = $self->{json}->{delimiter};
    my $name         = $self->{json}->{name};

    unless( $sourceOrTemplate =~ m#^/# ) {
        $sourceOrTemplate = "$defaultFromDir/$sourceOrTemplate";
    }

    unless( -r $sourceOrTemplate ) {
        error( 'Sqlscript::_runIt: file to run does not exist:', $sourceOrTemplate );
        return 0;
    }

    if( $doIt ) {
        my $content           = slurpFile( $sourceOrTemplate );
        my $templateProcessor = $self->_instantiateTemplateProcessor( $templateLang );

        my $sql    = $templateProcessor->process( $content, $config, $sourceOrTemplate );
        my $dbType = $self->{role}->name();

        my( $dbName, $dbHost, $dbPort, $dbUserLid, $dbUserLidCredential, $dbUserLidCredType )
                = UBOS::ResourceManager::findProvisionedDatabaseFor(
                        $dbType,
                        $self->{appConfig}->appConfigId,
                        $self->{installable}->packageName,
                        $name );

        my $dbDriver = UBOS::Host::obtainDbDriver( $dbType, $dbHost, $dbPort );
        unless( $dbDriver ) {
            error( 'Sqlscript::_runIt: unknown database type', $dbType );
            return 0;
        }

        $ret = $dbDriver->runBulkSqlAsAdmin( $dbName, $dbHost, $dbPort, $sql, $delimiter );
    }
    return $ret;
}

1;
