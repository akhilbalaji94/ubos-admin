#!/usr/bin/perl
#
# A general-purpose superclass for TemplateProcessors.
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

package UBOS::TemplateProcessor::TemplateProcessor;

use fields;

##
# Constructor
# return: the created TemplateProcessor object
sub new {
    my $self = shift;

    unless( ref $self ) {
        $self = fields::new( $self );
    }

    return $self;
}

1;



