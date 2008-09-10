#!/usr/bin/perl -w -I../../perllib
#
# test-child-contacts.pl
#
# Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: francis@mysociety.org; WWW: http://www.mysociety.org/
#

my $rcsid = ''; $rcsid .= '$Id: test-child-contacts.pl,v 1.1 2008-09-10 08:27:10 dademcron Exp $';

use strict;
$| = 1; # flush STDOUT afer each write

use Data::Dumper;
use mySociety::MaPit;
use mySociety::DaDem;
use Common;

my $area_id = 2219;
my $bad = 1;

# Get all the child areas of the council ($area_id)
my $children = mySociety::MaPit::get_voting_area_children($area_id);
# And the representatives of them
my $child_reps = mySociety::DaDem::get_representatives($children);
my @child_reps;
foreach (keys %$child_reps) {
    push @child_reps, @{$child_reps->{$_}};
}

# For each representative, get current status
my $children_info = mySociety::DaDem::get_representatives_info(\@child_reps);

# Loop through children to see if any have via
my $child_has_via = 0;
foreach (keys %$children_info) {
    my $child_info = $children_info->{$_};
    if ($child_info->{method} eq 'via'){
        print Dumper($child_info);
        $child_has_via = 1;
    }
    #warn "child via " . $child_info->{id} if $child_info->{method} eq 'via';
}

# If none have "via" set, then ignore this bad contact
if (!$child_has_via) {
    $bad = 0;
}

print $bad;

