#!/usr/bin/perl
#
# Represents the local host.
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

package UBOS::Host;

use UBOS::Apache2;
use UBOS::Configuration;
use UBOS::Logging;
use UBOS::Roles::apache2;
use UBOS::Roles::generic;
use UBOS::Roles::mysql;
use UBOS::Roles::postgresql;
use UBOS::Roles::tomcat8;
use UBOS::Site;
use UBOS::Tor;
use UBOS::Utils qw( readJsonFromFile myexec );
use Socket;
use Sys::Hostname qw();

my $SITES_DIR              = '/var/lib/ubos/sites';
my $HOST_CONF_FILE         = '/etc/ubos/config.json';
my $AFTER_BOOT_FILE        = '/var/lib/ubos/after-boot'; # put this into /var, so it stays on the partition
my $READY_FILE             = '/run/ubos-admin-ready';
my $LAST_UPDATE_FILE       = '/etc/ubos/last-ubos-update'; # not /var, as /var might move from system to system
my $HOSTNAME_CALLBACKS_DIR = '/etc/ubos/hostname-callbacks';

my $_hostConf              = undef; # allocated as needed
my $_rolesOnHostInSequence = undef; # allocated as needed
my $_rolesOnHost           = undef; # allocated as needed
my $_sites                 = undef; # allocated as needed
my $_osReleaseInfo         = undef; # allocated as needed
my $_allNics               = undef; # allocated as needed
my $_physicalNics          = undef; # allocated as needed

##
# Obtain the host Configuration object.
# return: Configuration object
sub config {
    unless( $_hostConf ) {
        my $raw = readJsonFromFile( $HOST_CONF_FILE );
        my $now = UBOS::Utils::now();

        $raw->{hostname}        = Sys::Hostname::hostname;
        $raw->{now}->{unixtime} = $now;
        $raw->{now}->{tstamp}   = UBOS::Utils::time2string( $now );

        $_hostConf = UBOS::Configuration->new( 'Host', $raw );
    }
    return $_hostConf;
}

##
# Helper method to read /etc/os-release
# Return: hash with found values (may be empty)
sub _getOsReleaseInfo {
    unless( defined( $_osReleaseInfo )) {
        $_osReleaseInfo = {};
        
        if( -e '/etc/os-release' ) {
            my $osRelease = UBOS::Utils::slurpFile( '/etc/os-release' );
            while( $osRelease =~ m!([-_a-zA-Z0-9]+)=\"([-_a-zA-Z0-9])\"!mg ) {
                $_osReleaseInfo->{$1} = $2;
            }
        }
    }
    return $_osReleaseInfo;
}

##
# Determine the current device's class.
# return: deviceClass, or undef
sub deviceClass {
    my $ret;

    my $osReleaseInfo = _getOsReleaseInfo();
    if( exists( $osReleaseInfo->{'UBOS_DEVICECLASS'} )) {
        return $osReleaseInfo->{'UBOS_DEVICECLASS'};
    }
    return undef;
}

##
# Determine the current device's kernel package name.
# return: kernel package name, or undef
sub kernelPackageName {
    my $ret;

    my $osReleaseInfo = _getOsReleaseInfo();
    if( exists( $osReleaseInfo->{'UBOS_KERNELPACKAGE'} )) {
        return $osReleaseInfo->{'UBOS_KERNELPACKAGE'};
    }
    return undef;
}

##
# Determine this host's hostname.
# return: hostname
sub hostname {
    return config()->get( 'hostname' );
}

##
# Determine all Sites currently installed on this host.
# return: hash of siteId to Site
sub sites {
    unless( $_sites ) {
        $_sites = {};

        if ( $< == 0 ) {
            # If we are root, we read the full files, otherwise the public files
            foreach my $f ( <"$SITES_DIR/*-full.json"> ) {
                my $siteJson = readJsonFromFile( $f );
                my $site     = UBOS::Site->new( $siteJson );
                $_sites->{$site->siteId()} = $site;
            }
        } else {
            foreach my $f ( <"$SITES_DIR/*-world.json"> ) {
                my $siteJson = readJsonFromFile( $f );
                my $site     = UBOS::Site->new( $siteJson );
                $_sites->{$site->siteId()} = $site;
            }
        }
    }
    return $_sites;
}

##
# Find a particular Site in the provided hash, or currently installed on this host.
# $siteId: the Site identifier
# $sites: hash of siteid to Site (defaults to sites installed on host)
# return: the Site, or undef
sub findSiteById {
    my $siteId = shift;
    my $sites  = shift || sites();

    return $sites->{$siteId};
}

##
# Find a particular Site in the provided hash, or currently installed on this host,
# by a complete or partial siteid match.
# $id: the complete or partial Site identifier
# $sites: hash of siteid to Site (defaults to sites installed on host)
# return: the Site, or undef
sub findSiteByPartialId {
	my $id    = shift;
    my $sites = shift || sites();

    my $ret;
    if( $id =~ m!^(.*)\.\.\.$! ) {
        my $partial    = $1;
        my @candidates = ();

        foreach my $siteId ( keys %$sites ) {
            my $site = $sites->{$siteId};

            if( $siteId =~ m!^$partial! ) {
                push @candidates, $site;
            }
        }
        if( @candidates == 1 ) {
            $ret = $candidates[0];

        } elsif( @candidates ) {
            $@ = "There is more than one site whose siteid starts with $partial: "
               . join( " vs ", map { $_->siteId } @candidates )
               . '.';
            return undef;

        } else {
            $@ = "No site found whose siteid starts with $partial.";
            return undef;
        }

    } else {
        $ret = $sites->{$id};
        unless( $ret ) {
            $@ = "No site found with siteid $id.";
            return undef;
        }
    }
    return $ret;
}

##
# Find a particular Site in the provided hash, or currently installed on this host,
# by its hostname
# $host: hostname
# $sites: hash of siteid to Site (defaults to sites installed on host)
# return: the Site
sub findSiteByHostname {
    my $host  = shift;
    my $sites = shift || sites();

    foreach my $siteId ( keys %$sites ) {
        my $site = $sites->{$siteId};

        if( $site->hostname eq $host ) {
            return $site;
        }
    }
    $@ = 'No Site found with hostname '. $host;
    return undef;
}

##
# Find a particular AppConfiguration in the provided hash of sites, or currently installed on this host,
# by a complete app config id match.
sub findAppConfigurationById {
    my $appConfigId = shift;
    my $sites       = shift || sites();

    foreach my $siteId ( keys %$sites ) {
        my $site       = $sites->{$siteId};
        my $appConfigs = $site->appConfigs;

        foreach my $appConfig ( @$appConfigs ) {
            if( $appConfig->appConfigId eq $appConfigId ) {
                return $appConfig;
            }
        }
    }
    return undef;
}

##
# Find a particular AppConfiguration in the provided hash of sites, or currently installed on this host,
# by a complete or partial app config id match.
# $id: the complete or partial app config identifier
# $sites: hash of siteid to Site (defaults to sites installed on host)
# return: the Site, or undef
sub findAppConfigurationByPartialId {
    my $id    = shift;
    my $sites = shift || sites();

    my $ret;
    if( $id =~ m!^(.*)\.\.\.$! ) {
        my $partial    = $1;
        my @candidates = ();

        foreach my $siteId ( keys %$sites ) {
            my $site       = $sites->{$siteId};
            my $appConfigs = $site->appConfigs;

            foreach my $appConfig ( @$appConfigs ) {
                if( $appConfig->appConfigId =~ m!^$partial! ) {
                    push @candidates, [ $appConfig, $site ];
                }
            }
        }
        if( @candidates == 1 ) {
            $ret = $candidates[0][0];

        } elsif( @candidates ) {
            $@ = "There is more than one AppConfiguration whose app config id starts with $partial: "
                 . join( " vs ", map { "$_[0] (site $_[1] )" } @candidates ) . '.';
            return undef;

        } else {
            $@ = "No AppConfiguration found whose app config id starts with $partial.";
            return undef;
        }

    } else {
        foreach my $siteId ( keys %$sites ) {
            my $site = $sites->{$siteId};

            $ret = $site->appConfig( $id );

            if( $ret ) {
                last;
            }
        }
        unless( $ret ) {
            $@ = "No AppConfiguration found with app config id $id.";
            return undef;
        }
    }
    return $ret;
}

##
# A site has been deployed.
# $site: the newly deployed or updated site
sub siteDeployed {
    my $site = shift;

    my $siteId         = $site->siteId;
    my $siteJson       = $site->siteJson;
    my $publicSiteJson = $site->publicSiteJson;
    my $hostname       = $site->hostname;

    debug( 'Host::siteDeployed', $siteId );

    UBOS::Utils::writeJsonToFile( "$SITES_DIR/$siteId-full.json",  $siteJson,       0600, 'root', 'root' );
    UBOS::Utils::writeJsonToFile( "$SITES_DIR/$siteId-world.json", $publicSiteJson, 0644, 'root', 'root' );

    UBOS::Utils::invokeCallbacks( "$HOSTNAME_CALLBACKS_DIR", 'deployed', $siteId, $hostname );

    $_sites = undef;
}

##
# A site has been undeployed.
# $site: the undeployed site
sub siteUndeployed {
    my $site = shift;

    my $siteId   = $site->siteId;
    my $hostname = $site->hostname;

    debug( 'Host::siteUndeployed', $siteId );

    UBOS::Utils::deleteFile( "$SITES_DIR/$siteId-world.json" );
    UBOS::Utils::deleteFile( "$SITES_DIR/$siteId-full.json" );

    UBOS::Utils::invokeCallbacks( "$HOSTNAME_CALLBACKS_DIR", 'undeployed', $siteId, $hostname );

    $_sites = undef;
}

##
# Determine the roles that this host has chosen to use and support. For now, this is
# fixed.
# return: hash of role name to Role
sub rolesOnHost {
    unless( $_rolesOnHost ) {
        my @inSequence = rolesOnHostInSequence();
        $_rolesOnHost = {};
        foreach my $role ( @inSequence ) {
            $_rolesOnHost->{ $role->name } = $role;
        }
    }
    return $_rolesOnHost;
}

##
# Determine the roles that this host has chosen to use and support, in sequence
# of installation: databases before middleware before web server.
# return: the Roles, in sequence
sub rolesOnHostInSequence {
    unless( $_rolesOnHostInSequence ) {
        $_rolesOnHostInSequence = [
                UBOS::Roles::mysql->new,
                UBOS::Roles::postgresql->new,
                # UBOS::Roles::mongo->new,
                UBOS::Roles::generic->new,
                UBOS::Roles::tomcat8->new,
                UBOS::Roles::apache2->new ];
    }
    return @$_rolesOnHostInSequence;
}

##
# Create a new siteid
# return: the siteid
sub createNewSiteId {
    return 's' . UBOS::Utils::randomHex( 40 );
}

##
# Create a new appconfigid
# return: the appconfigid
sub createNewAppConfigId {
    return 'a' . UBOS::Utils::randomHex( 40 );
}

##
# Determine whether this is a valid hostname
# $hostname: the hostname
# return: 1 or 0
sub isValidHostname {
    my $hostname = shift;

    if( ref( $hostname )) {
        error( 'Supposed hostname is not a string:', ref( $hostname ));
        return 0;
    }

    unless( $hostname =~ m!^(?=.{1,255}$)[0-9A-Za-z](?:(?:[0-9A-Za-z]|-){0,61}[0-9A-Za-z])?(?:\.[0-9A-Za-z](?:(?:[0-9A-Za-z]|-){0,61}[0-9A-Za-z])?)*\.?$|^\*$! ) {
        # regex originally from http://stackoverflow.com/a/1420225/200304
        return 0;
    }
    return 1;
}

##
# Determine whether this is a syntactically valid Site id
# $siteId: the Site id
# return: 1 or 0
sub isValidSiteId {
    my $siteId = shift;

    if( ref( $siteId )) {
        error( 'Supposed siteId is not a string:', ref( $siteId ));
        return 0;
    }
    if( $siteId =~ m/^s[0-9a-f]{40}$/ ) {
        return 1;
    } else {
        return 0;
    }
}

##
# Determine whether this is a syntactically valid AppConfiguration id
# $appConfigId: the AppConfiguration id
# return: 1 or 0
sub isValidAppConfigId {
    my $appConfigId = shift;

    if( ref( $appConfigId )) {
        error( 'Supposed appConfigId is not a string:', ref( $appConfigId ));
        return 0;
    }
    if( $appConfigId =~ m/^a[0-9a-f]{40}$/ ) {
        return 1;
    } else {
        return 0;
    }
}

##
# Execute the named triggers
# $triggers: array of trigger names
sub executeTriggers {
    my $triggers = shift;

    my @triggerList;
    if( ref( $triggers ) eq 'HASH' ) {
        @triggerList = keys %$triggers;
    } elsif( ref( $triggers ) eq 'ARRAY' ) {
        @triggerList = @$triggers;
    } else {
        fatal( 'Unexpected type:', $triggers );
    }

    debug( 'Host::executeTriggers:', @triggerList );

    foreach my $trigger ( @triggerList ) {
        if( 'httpd-reload' eq $trigger ) {
            UBOS::Apache2::reload();
        } elsif( 'httpd-restart' eq $trigger ) {
            UBOS::Apache2::restart();
        } elsif( 'tomcat8-reload' eq $trigger ) {
            UBOS::Tomcat8::reload();
        } elsif( 'tomcat8-restart' eq $trigger ) {
            UBOS::Tomcat8::restart();
        } elsif( 'tor-reload' eq $trigger ) {
            UBOS::Tor::reload();
        } elsif( 'tor-restart' eq $trigger ) {
            UBOS::Tor::restart();
        } else {
            warning( 'Unknown trigger:', $trigger );
        }
    }
}

##
# Update all the code currently installed on this host.
# $syncFirst: if true, perform a pacman -Sy; otherwise only a pacman -Su
# $showPackages: if true, show the package files that were installed
# return: if -1, reboot
sub updateCode {
    my $syncFirst    = shift;
    my $showPackages = shift;

    debug( 'Host::UpdateCode', $syncFirst, $showPackages );

    my $ret = 0;
    my $cmd;
    if( -x '/usr/bin/pacman-db-upgrade' ) {
        # not sure when this can be removed again
        $cmd = 'pacman-db-upgrade';
        unless( UBOS::Logging::isDebugActive() ) {
            $cmd .= ' > /dev/null';
        }
        myexec( $cmd );
    }

    if( $syncFirst ) {
        $cmd = 'pacman -Syu --noconfirm';
    } else {
        $cmd = 'pacman -Su --noconfirm';
    }

    my $out;
    if( myexec( $cmd, undef, \$out ) != 0 ) {
        error( 'Command failed:', $cmd, "\n$out" );

    } elsif( UBOS::Logging::isDebugActive() ) {
        print $out;
    }

    if( $showPackages ) {
        my @lines     = split /\n/, $out;
        my @installed = map { my $s = $_; $s =~ s!^.*installing\s+!!; $s =~ s!\.\.\.\s*!!; $s; } grep /^installing /, @lines;
        my @upgraded  = map { my $s = $_; $s =~ s!^.*upgrading\s+!!;  $s =~ s!\.\.\.\s*!!; $s; } grep /^upgrading / , @lines;

        if( @installed ) {
            print 'Packages installed: ' . join( ' ', @installed ) . "\n";
        }
        if( @upgraded ) {
            print 'Packages upgraded: ' . join( ' ', @upgraded ) . "\n";
        }
        if( scalar( @installed ) + scalar( @upgraded ) == 0 ) {
            print "No packages installed or upgraded.\n";
        }
    }

    if( -x '/usr/bin/pacman-db-upgrade' ) {
        # not sure when this can be removed again
        $cmd = 'pacman-db-upgrade';
        unless( UBOS::Logging::isDebugActive() ) {
            $cmd .= ' > /dev/null';
        }
        myexec( $cmd );
    }

    UBOS::Utils::saveFile( $LAST_UPDATE_FILE, UBOS::Utils::time2string( time() ) . "\n", 0644, 'root', 'root' );

    # if installed kernel package is now different from running kernel: signal to reboot
    my $kernelPackageName = kernelPackageName();
    if( $kernelPackageName ) { # This will be undef in a container, so a container will never reboot automatically
        my $kernelPackageVersion = packageVersion( $kernelPackageName );
        if( $kernelPackageVersion ) {
            my $kernelVersion;
            myexec( 'uname -r', undef, \$kernelVersion );
            $kernelVersion =~ s!^\s+!!;
            $kernelVersion =~ s!\s+$!!;
            $kernelVersion =~ s!-ARCH$!!; # somehow there's a -ARCH at the end

            if( $kernelPackageVersion ne $kernelVersion ) {
                # reboot necessary
                $ret = -1;
            }
        }
    }
    return $ret;
}

##
# Clean package cache
sub purgeCache {

    my $cmd = 'pacman -Sc --noconfirm';
    unless( UBOS::Logging::isDebugActive() ) {
        $cmd .= ' > /dev/null';
    }
    myexec( $cmd );
}

##
# Make sure the named packages are installed
# $packages: List or hash of packages
# $quiet: if false, and an actual download needs to be performed, print progress message
# return: number of actually installed packagesm or negative number if error
sub ensurePackages {
    my $packages = shift;
    my $quiet    = shift;

    unless( defined( $quiet )) {
        $quiet = 1;
    }
    my @packageList;
    if( ref( $packages ) eq 'HASH' ) {
        @packageList = keys %$packages;
    } elsif( ref( $packages ) eq 'ARRAY' ) {
        @packageList = @$packages;
    } elsif( ref( $packages )) {
        fatal( 'Unexpected type:', $packages );
    } elsif( defined( $packages )) {
        @packageList = ( $packages );
    } else {
        @packageList = ();
    }

    debug( 'ensurePackages', @packageList );

    # only install what isn't installed yet
    my @filteredPackageList = grep { myexec( "pacman -Q $_ > /dev/null 2>&1" ) } @packageList;

    if( @filteredPackageList ) {
        unless( $quiet ) {
            print "Downloading packages...\n";
        }
        my $err;
        my $cmd = 'pacman -S --noconfirm ' . join( ' ', @filteredPackageList );
        unless( UBOS::Logging::isDebugActive() ) {
            $cmd .= ' > /dev/null';
        }

        if( myexec( $cmd, undef, undef, \$err )) {
            $@ = 'Failed to install package(s). Pacman says: ' . $err;
            return -1;
        }
    }
    return 0 + @filteredPackageList;
}

##
# Install the provided package files
# $packageFiles: List of package files
# $showPackages: if true, show the package files that were installed
# return: number of installed packages
sub installPackageFiles {
    my $packageFiles = shift;
    my $showPackages = shift;

    my $err;
    my $cmd = 'pacman -U --noconfirm ' . join( ' ', @$packageFiles );
    unless( UBOS::Logging::isDebugActive() ) {
        $cmd .= ' > /dev/null';
    }

    if( myexec( $cmd, undef, undef, \$err )) {
        error( 'Failed to install package file(s). Pacman says:', $err );
        return 0;
    }
    if( $showPackages ) {
        if( @$packageFiles ) {
            print 'Packages installed: ' . join( ' ', @$packageFiles ) . "\n";
        } else {
            print "No packages installed.\n";
        }
    }
    return 0 + ( @$packageFiles );
}

##
# Determine the version of an installed package
# $packageName: name of the package
# return: version of the package, or undef
sub packageVersion {
    my $packageName = shift;

    my $cmd = "pacman -Q '$packageName'";
    my $out;
    my $err;
    if( myexec( $cmd, undef, \$out, \$err )) {
        return undef;
    }
    if( $out =~ m!$packageName\s+(\S+)! ) {
        return $1;
    } else {
        error( 'Cannot parse pacman -Q output:', $out );
        return undef;
    }
}

##
# Ensure that snapper is configured. Called during package install only.
sub ensureSnapperConfig {

    # Determine the btrfs filesystems
    my $out;
    if( myexec( "findmnt --json --types btrfs", undef, \$out, \$out )) {
        error( "findmnt failed:", $out );
        return undef;
    }
    $out =~ s!^\s+!!;
    $out =~ s!\s+$!!;

    if( $out ) {
        my $findmntJson = UBOS::Utils::readJsonFromString( $out );
        my @targets     = map { $_->{target} } @{$findmntJson->{filesystems}};

        foreach my $target ( @targets ) {
            my $configName = $target;
            $configName =~ s!/!!g;
            unless( $configName ) {
                $configName = 'root';
            }

            unless( -e "/etc/snapper/configs/$configName" ) {
                my $err;
                if( myexec( "snapper -c '$configName' create-config -t ubos-default '$target'", undef, \$err, \$err )) {
                    error( 'snapper (create-config) failed of config', $configName, $target, $err );
                }
            }
        }
        my $err;
        if( myexec( 'snapper setup-quota', undef, \$err, \$err ) && $err !~ /qgroup already set/ ) {
            error( 'snapper setup-quota failed:', $err );
        }
    }
    1;
}

##
# Create a "pre" filesystem snapshot
# return: string to be passed into postSnapshot to perform the corresponding "post" snapshot
sub preSnapshot {

    # Determine the btrfs filesystems
    my $out;
    if( myexec( "findmnt --json --types btrfs", undef, \$out, \$out )) {
        error( "findmnt failed:", $out );
        return undef;
    }
    $out =~ s!^\s+!!;
    $out =~ s!\s+$!!;

    if( $out ) {
        my $findmntJson = UBOS::Utils::readJsonFromString( $out );
        my @targets     = map { $_->{target} } @{$findmntJson->{filesystems}};
        my $ret;
        my $sep = '';
        foreach my $target ( @targets ) {
            my $configName = $target;
            $configName =~ s!/!!g;
            unless( $configName ) {
                $configName = 'root';
            }

            if( -e "$target/etc/snapper/configs/$configName" ) {
                my $snapNumber;
                my $err;
                if( myexec( "snapper -c '$configName' create --type pre --print-number", undef, \$snapNumber, \$err )) {
                    error( 'snapper (pre) failed of config', $configName, $snapNumber, $err );
                } else {
                    $snapNumber =~ s!^\s+!!;
                    $snapNumber =~ s!\s+$!!;
                    $ret .= "$sep$target=$snapNumber";
                    $sep = ',';
                }
            }
        }
        if( $ret ) {
            return $ret;
        }
    }
    return undef;
}

##
# Create a "post" filesystem snapshot
# $preInfo: the return value of preSnapshot from the corresponding "pre" snapshot
sub postSnapshot {
    my $preInfo = shift;

    foreach my $item ( split ",", $preInfo ) {
        if( $item =~ m!^(.+)=(\d+)$! ) {
            my $target     = $1;
            my $snapNumber = $2;

            my $configName = $target;
            $configName =~ s!/!!g;
            unless( $configName ) {
                $configName = 'root';
            }

            if( -e "$target/etc/snapper/configs/$configName" ) {
                my $out;
                if( myexec( "snapper -c '$configName' create --type post --pre-number '$snapNumber'", undef, \$out, \$out )) {
                    error( 'snapper (post) failed of config', $configName, ', number', $snapNumber, $out );
                }
            }
        }
    }
}

##
# Prevent interruptions of this script
sub preventInterruptions {
    $SIG{'HUP'}  = 'IGNORE';
    $SIG{'INT'}  = 'IGNORE';
    $SIG{'QUIT'} = 'IGNORE';
}

my $dbTypes           = {}; # cache
my $dbDriverInstances = {}; # cache: maps short-name to host:port to instance of driver

##
# Return which database types are available.
# return: hash of short-name to package name
sub _findDatabases {
    unless( %$dbTypes ) {
        my $full = UBOS::Utils::findPerlModuleNamesInPackage( 'UBOS::Databases' );
        foreach my $fileName ( keys %$full ) {
            my $packageName = $full->{$fileName};

            if( $packageName =~ m!::([A-Za-z0-9_]+)Driver$! ) {
                my $shortName = $1;
                $shortName =~ s!([A-Z])!lc($1)!ge;
                $dbTypes->{$shortName} = $packageName;
            }
        }
    }
    return $dbTypes;
}

##
# Return an instance of a database driver for the given short-name
# $shortName: short name of the database type, e.g. 'mysql'
# $dbHost: host on which the database runs
# $dbPort: port on which the database can be reached on that port
# return: database driver, e.g. an instance of UBOS::Databases::MySqlDriver
sub obtainDbDriver {
    my $shortName = shift;
    my $dbHost    = shift;
    my $dbPort    = shift || 'default';
    
    my $ret = $dbDriverInstances->{$shortName}->{"$dbHost:$dbPort"};
    unless( $ret ) {
        my $dbs = _findDatabases();
        my $db  = $dbs->{$shortName};
        if( $db ) {
            $ret = UBOS::Utils::invokeMethod( $db . '::new', $db, $dbHost, $dbPort );
            
            if( $dbPort eq 'default' ) {
                $dbDriverInstances->{$shortName}->{"$dbHost:default"} = $ret;
                $dbPort = $ret->defaultPort();
            }
            $dbDriverInstances->{$shortName}->{"$dbHost:$dbPort"} = $ret;
        }
    }
    return $ret;
}

##
# Ensure that pacman has been initialized. This may generate a key pair, which
# means it cannot be pre-installed; it also may take some time, depending on
# how much entropy is available.
sub ensurePacmanInit {
    # If the time is completely off, chances are we are on a Raspberry Pi or
    # such that hasn't connected to the network. In which case we set the system
    # time to the time of the last build
    # The BeagleBone Black apparently initializes with Jan 1, 2000.
    if( time() < 1000000000 ) { # September 2001
        my $osRelease = UBOS::Utils::slurpFile( '/etc/os-release' );
        if( $osRelease =~ m!^BUILD_ID="?(\d\d\d\d)(\d\d)(\d\d)-(\d\d)(\d\d)(\d\d)"?$!m ) {
            my( $year, $month, $day, $hour, $min, $sec ) = ( $1, $2, $3, $4, $5, $6 );

            my $ds = sprintf( '%.2d%.2d%.2d%.2d%.4d.%.2d', $month, $day, $hour, $min, $year, $sec );

            myexec( "date $ds" );
        }
    }
    if( -x '/usr/bin/pacman-db-upgrade' ) {
        myexec( 'pacman-db-upgrade' ); # not sure when this can be removed again
    }
    
    myexec( "pacman-key --init" );

    # We trust the Arch people, Arch Linux ARM, Uplink Labs' EC2 packages and ourselves
    my $err;
    myexec( "pacman -Q archlinux-keyring    > /dev/null 2>&1 && pacman-key --populate archlinux",    undef, undef, \$err );
    myexec( "pacman -Q archlinuxarm-keyring > /dev/null 2>&1 && pacman-key --populate archlinuxarm", undef, undef, \$err );
    myexec( "pacman -Q ec2-keyring          > /dev/null 2>&1 && pacman-key --populate ec2"         , undef, undef, \$err );
    myexec( "pacman-key --populate ubos" );
}

##
# Determine the fingerprint of the host key
sub gpgHostKeyFingerprint {

    my $out;
    my $err;
    if( myexec( 'GNUPGHOME=/etc/pacman.d/gnupg gpg --fingerprint pacman@localhost', undef, \$out, \$err )) {
        error( 'Cannot determine host key', $out, $err );
        return '';
    }
    # gpg: WARNING: unsafe permissions on homedir '/etc/pacman.d/gnupg'
    # pub   rsa2048/B0B434F0 2015-02-15
    #       Key fingerprint = 26FC BC8B 874A 9744 7718  5E8C 5311 6A36 B0B4 34F0
    # uid       [ultimate] Pacman Keyring Master Key <pacman@localhost>
    # 2016-07: apparently the "Key fingerprint =" is not being emitted any more

    my $ret;
    if( $out =~ m!((\s+[0-9A-F]{4}){10})!m ) {
        $ret = $1;
        $ret =~ s!\s+!!g;
    } else {
        error( 'Unexpected fingerprint format:', $out );
        $ret = '';
    }
    return $ret;
}

##
# Make sure an OS user with the provided userId exists.
# If not, create the user with the specified group(s).
# $userId: user id
# $groupIds: zero or more groups
# $homeDir: desired location of home directory
# return: success or fail
sub ensureOsUser {
    my $userId   = shift;
    my $groupIds = shift;
    my $homeDir  = shift || "/home/$userId";

    my $out;
    my $err;
    if( myexec( "getent passwd $userId", undef, \$out, \$err )) {

        debug( 'Creating user', $userId );

        if( myexec( "sudo useradd -e '' -m -U $userId -d $homeDir", undef, undef, \$err )) {
            error( 'Failed to create user', $userId, ', error:', $err );
            return 0;
        }

        if( defined( $groupIds ) && @$groupIds ) {
            debug( 'Adding user to groups:', $userId, @$groupIds );

            if( myexec( "sudo usermod -a -G " . join(',', @$groupIds ) . " $userId", undef, undef, \$err )) {
                error( 'Failed to add user to groups:', $userId, @$groupIds, 'error:', $err );
                return 0;
            }
        }
        if( myexec( "sudo chown -R $userId $homeDir" )) {
            error( 'Failed to chown home dir of user', $userId, $homeDir );
            return 0;
        }
    }
    return 1;
}

##
# Add a command to run after the next boot. The command must be of the
# form "<tag>:<command>" where <tag> is either "bash" or "perleval".
# The bash commands must be bash-executable and will run as root.
# The perleval commands will be executed by eval'ing the command
# from ubos-admin-initialize
# @cmds: one or more commands
sub addAfterBootCommands {
    my @cmds = @_;

    my $afterBoot;
    if( -e $AFTER_BOOT_FILE ) {
        $afterBoot = UBOS::Utils::slurpFile( $AFTER_BOOT_FILE );
    }
    foreach my $cmd ( @cmds ) {
        if( $cmd =~ m!^(bash|perleval):! ) {
            $afterBoot .= "$cmd\n";
        } else {
            error( 'Invalid after-boot command syntax:', $cmd );
        }
    }
    UBOS::Utils::saveFile( $AFTER_BOOT_FILE, $afterBoot );
}

##
# If there are commands in the after-boot file, execute them, and then remove
# the file
sub runAfterBootCommandsIfNeeded {

    debug( 'Host::runAfterBootCommandsIfNeeded' );

    if( -e $AFTER_BOOT_FILE ) {
        my $afterBoot = UBOS::Utils::slurpFile( $AFTER_BOOT_FILE );

        my @lines = split( "\n", $afterBoot );
        foreach my $line ( @lines ) {
            if( $line =~ m!^bash:(.*)$! ) {
                my $cmd = $1;
                my $out;
                my $err;
                if( myexec( "/bin/bash", $cmd, \$out, \$err )) {
                    error( "Problem when running after-boot commands. Bash command:\n" . $cmd . "\nout: " . $out . "\nerr: " . $err );
                }
            } elsif( $line =~ m!^perleval:(.*)$! ) {
                my $cmd = $1;
                unless( eval( $cmd )) {
                    error( "Problem when running after-boot commands. Perl command:\n" . $cmd );
                }
            }
        }
        UBOS::Utils::deleteFile( $AFTER_BOOT_FILE );
    }
}

##
# Deploy any site templates
sub deploySiteTemplatesIfNeeded {

    unless( config()->get( 'host.deploysitetemplatesonboot', 0 )) {
        return;
    }
    my $destDir = config()->get( 'host.deploysitetemplatesonbootdir', undef );
    if( !defined( $destDir ) || !$destDir || !-d $destDir ) {
        return;
    }
    my @templateFiles = <$destDir/*.json>;
    unless( @templateFiles ) {
        return;
    }
    my $cmd = 'ubos-admin deploy --skip-check-ready --template' . join( '', map { " --file '$_'" } @templateFiles );
    my $out;
    my $err;
    if( myexec( "/bin/bash", $cmd, \$out, \$err )) {
        error( "Problems with attempting to install site templates from $destDir:\n" . $cmd, "\nout: " . $out . "\nerr: " . $err );
        # if error, leave templates in place

    } else {
        UBOS::Utils::deleteFile( @templateFiles );
    }
}

##
# Determine the current network interfaces of this host and their properties.
# Unless $all is specified, this does not return loopback and virtual devices
#
# $all: if 1, list all nics including loopback and virtual devices
# return: hash, e.g. { enp0s1 => { index => 1, type => "ethernet", operational => 'carrier', setup => 'configured' }}}
sub nics {
    my $all = shift || 0;

    unless( defined( $_allNics )) {
        my $netctl;
        my $err; # swallow error messages
        myexec( "networkctl --no-pager --no-legend", undef, \$netctl, \$err );
        if( $err ) {
            debug( 'Host::nics: networkctl said:', $err );
        }

        $_allNics = {};
        foreach my $line ( split "\n", $netctl ) {
            if( $line =~ /^\s*(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*$/ ) {
                my( $index, $link, $type, $operational, $setup ) = ( $1, $2, $3, $4, $5 );

                my $n = {};

                $n->{index}       = $index;
                $n->{type}        = $type;
                $n->{operational} = $operational;
                $n->{setup}       = $setup;

                $_allNics->{$link} = $n;
            }
        }
    }
    if( $all ) {
        return $_allNics;
    }
    unless( defined( $_physicalNics )) {
        $_physicalNics = {};
        foreach my $nic ( keys %$_allNics ) {
            if(    $nic !~ m!^(ve-|docker-)!
                && $_allNics->{$nic}->{type} !~ m!^loopback! )
            {
                $_physicalNics->{$nic} = $_allNics->{$nic};
            }
        }
    }
    return $_physicalNics;
}

##
# Determine IP addresses assigned to a network interface given by a
# name or a wildcard expression, e.g. "enp2s0" or "enp*".
#
# $nic: the network interface
# return: the zero or more IP addresses assigned to the interface
sub ipAddressesOnNic {
    my $nic = shift;

    my $nicRegex = $nic;
    $nicRegex =~ s!\*!.*!g;

    my $netctl;
    my $err; # swallow error messages
    myexec( "networkctl --no-pager --no-legend status", undef, \$netctl, \$err );
            # can't ask nic directly as we need wildcard support
    if( $err ) {
        debug( 'Host::nics: networkctl said:', $err );
    }

    my @ret = ();

    my $hasSeenAddressLine = 0;
    foreach my $line ( split "\n", $netctl ) {
        if( $hasSeenAddressLine ) {
            if( $line =~ m!^\s*Gateway:! ) {
                # "Gateway:" is the next item after "Address:", so we know we are done
                last;
            } else {
                if( $line =~ m!\s*(\S+)\s*on\s*(\S+)\s*$! ) {
                    my $foundIp  = $1;
                    my $foundNic = $2;

                    if( $foundNic =~ m!$nicRegex! ) {
                        push @ret, $foundIp;
                    }
                }
            }
        } else {
            # have not found one already
            if( $line =~ m!^\s*Address:\s*(\S+)\s*on\s*(\S+)\s*$! ) {
                my $foundIp  = $1;
                my $foundNic = $2;

                if( $foundNic =~ m!$nicRegex! ) {
                    push @ret, $foundIp;
                }
                $hasSeenAddressLine = 1;
            }
        }
    }
    return @ret;
}

##
# Obtain a function that knows how to read manifest files from the default
# location.
# $packageIdentifier: the package identifier
# return: JSON
sub defaultManifestFileReader {
    my $packageIdentifier = shift;

    my $file = UBOS::Host::config()->get( 'package.manifestdir' ) . "/$packageIdentifier.json";
    return readJsonFromFile( $file );
}

#####
# Check whether the system is ready for the command
sub checkReady {

    if( -e $READY_FILE ) {
        my $ret = UBOS::Utils::slurpFile( $READY_FILE );
        $ret =~ s!^\s+!!;
        $ret =~ s!\s+$!!;
        return $ret;
    }
    my $out;
    myexec( 'systemctl is-system-running', undef, \$out );
    if( $out =~ m!starting!i ) {
        print <<END;
UBOS is not done initializing yet. Please wait until:
    systemctl is-system-running
says "running" or until this message goes away.
END
        return undef;
    }

    my @services = qw( ubos-admin ubos-httpd ubos-ready );

    foreach my $service ( @services ) {
        if( myexec( 'systemctl is-failed ' . $service, undef, \$out ) == 0 ) {
            # if is-failed is true, attempt to restart
            if( $< != 0 ) {
                print <<END;
Required service $service has failed. Try invoking your command again using 'sudo'.
END
            } else {
                print <<END;
Required service $service has failed. Attempting to restart. Try invoking your command again in a little while.
END
                myexec( 'systemctl restart ' . $service );
            }
            return undef;
        }
    }
    foreach my $service ( @services ) {
        if( myexec( 'systemctl is-active ' . $service, undef, \$out )) {
            if( $< != 0 ) {
                print <<END;
Required service $service is not active. Try invoking your command again using 'sudo'.
END
            } else {
                print <<END;
Required service $service is not active. Attempting to start. Try invoking your command again in a little while.
END
                myexec( 'systemctl start ' . $service );
            }
            return undef;
        }
    }
    
    if( $< == 0 ) {
        UBOS::Utils::saveFile( $READY_FILE, UBOS::Utils::time2string( time() ) . "\n", 0644, 'root', 'root' );
        my $ret = UBOS::Utils::slurpFile( $READY_FILE );
        $ret =~ s!^\s+!!;
        $ret =~ s!\s+$!!;
        return $ret;
    }
    return '';
}

##
# Determine when the host was last updated using ubos-admin update.
# return: timestamp, or undef
sub lastUpdated {
    my $ret;
    if( -e $LAST_UPDATE_FILE ) {
        $ret = UBOS::Utils::slurpFile( $LAST_UPDATE_FILE );
        $ret =~ s!^\s+!!;
        $ret =~ s!\s+$!!;
    } else {
        $ret = undef;
    }
    return $ret;
}

1;
