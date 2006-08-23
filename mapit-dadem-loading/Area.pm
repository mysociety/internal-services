#!/usr/bin/perl
#
# Area.pm:
# Simple object to represent a single area, used by BoundaryLine loading code.
#
# Copyright (c) 2006 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: Area.pm,v 1.1 2006-08-23 00:34:56 francis Exp $
#

use strict;
package Area;

use fields qw(id area_type parts minx maxx miny maxy cx cy ons_code devolved country aaid name parent children deleted alreadyexists);

# Accessor methods
my $x = fields::new('Area');
foreach (keys %$x) {
    next if ($_ eq 'children');
    eval <<EOF;
sub $_ (\$;\$) {
    my (\$self, \$val) = \@_;
    if (\@_ == 2) {
        \$self->{$_} = \$val;
    } else {
        return \$self->{$_};
    }
}
EOF
}

# children [CHILD]
# Add a CHILD to the set of this area's children, or return the current set of
# children.
sub children ($;$) {
    my ($self, $ch) = @_;
    if (defined($ch)) {
        $self->{children}->{$ch} = $ch;
    } else {
        return grep { !$_->deleted() } values(%{$self->{children}});
    }
}

sub new ($%) {
    my ($class, %values) = @_;
    my $self = fields::new($class);
    $self->{deleted} = 0;
    $self->{alreadyexists} = 1; # whether the area should already be in the db
                                # (assume yes until told otherwise)
    foreach (keys %values) {
        $self->{$_} = $values{$_};  # syntax checks?
        $self->{$_} = $values{$_};  # syntax checks?
    }
    return bless($self, $class);
}

1;
