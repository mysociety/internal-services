#!/usr/bin/perl
#
# Common.pm:
# Common stuff for data importing.
#
# Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: Common.pm,v 1.4 2004-12-01 17:15:09 francis Exp $
#

package Common;

use strict;

use String::Ediff;

@Common::ISA = qw(Exporter);
@Common::EXPORT = qw(
        &current_generation
        &new_generation
        &make_new_generation_active
        &get_area_id
        &get_postcode_id
        &trim_spaces
        &move_compass_to_start
        &placename_match_metric
    );

# current_generation DBH
# Return the current generation ID.
sub current_generation ($) {
    my ($dbh) = @_;
    return scalar($dbh->selectrow_array('select id from current_generation'));
}

# new_generation DBH
# Return the new generation ID, creating a new generation if necessary.
sub new_generation ($) {
    my ($dbh) = @_;
    my $id = $dbh->selectrow_array('select id from new_generation');
    if (!defined($id)) {
        $id = $dbh->selectrow_array(q#select nextval('generation_id_seq')#);
        $dbh->do('insert into generation (id, created) values (?, ?)', {}, $id, time());
    }
    return $id;
}

# make_new_generation_active DBH
# Make the new generation active (i.e. so that it becomes the current
# generation.)
sub make_new_generation_active ($) {
    my ($dbh) = @_;
    $dbh->do(q#update generation set active = 't' where id = (select new_generation.id from new_generation)#);
}

# get_area_id DBH NAME TYPE ONSCODE UNITID GEOMHASH
# Form area ID from name and other information.
sub get_area_id ($$$$$$) {
    my ($dbh, $name, $type, $onscode, $unitid, $geomhash) = @_;
    my $id;
    my $gen = new_generation($dbh);
    
    if (defined($onscode)) {
        $id = $dbh->selectrow_array('select id from area where ons_code = ? and type = ? for update', {}, $onscode, $type);
    } elsif (defined($geomhash)) {
        $id = $dbh->selectrow_array('select id from area where geom_hash = ? and type = ? for update', {}, $geomhash, $type);
    }
    
    if (defined($id)) {
        my $n = $dbh->selectrow_array('select name from area_name where area_id = ?', {}, $id);
        if (defined($n) and $n eq $name) {
            # This is the same area.
            $dbh->do('update area set generation_high = ? where area.id = ?', {}, $gen, $id);
            return $id;
        }
    }

    # No existing area. Create a new one.
    $id = $dbh->selectrow_array(q#select nextval('area_id_seq')#);
    $dbh->do('insert into area (id, unit_id, ons_code, geom_hash, type, generation_low, generation_high) values (?, ?, ?, ?, ?, ?, ?)',
            {}, $id, $unitid, $onscode, $geomhash, $type, $gen, $gen);
    $dbh->do(q#insert into area_name (area_id, name_type, name) values (?, 'O', ?)#, {}, $id, $name);

    return $id;
}

# get_postcode_id DBH POSTCODE EASTING NORTHING
# Form postcode ID.
sub get_postcode_id ($$$$) {
    my ($dbh, $pc, $E, $N) = @_;
    my $c = ($pc =~ m#^BT# ? 'I' : 'G');
    my $id;
    $id = $dbh->selectrow_array('select id from postcode where postcode = ?', {}, $pc);
    if (defined($id)) {
        $dbh->do('update postcode set coordsyst = ?, easting = ?, northing = ? where id = ?', {}, $c, $E, $N, $id);
        return $id;
    }

    $id = $dbh->selectrow_array(q#select nextval('postcode_id_seq')#);
    $dbh->do('insert into postcode (id, postcode, coordsyst, easting, northing) values (?, ?, ?, ?, ?)', {}, $id, $pc, $c, $E, $N);
    return $id;
}

# trim_spaces STRING
# Remove leading and trailing white space from string.
# Can pass by reference or, pass by value and return
sub trim_spaces ($) {
    $_[0] =~ s/\s+$//;
    $_[0] =~ s/^\s+//;
    return $_[0];
}

# move_compass_to_start STRING
# Move compass directions (North, South, East, West) to start of string
# and to have that order.  Requires a lowercase string, and ignores
# spaces.
sub move_compass_to_start {
    my ($match) = @_;

    # Move compass points to start
    my $compass = "";
    foreach my $dir ("north", "south", "east", "west") {
        while ($match =~ m/($dir)/) {
            $match =~ s/^(.*)($dir)(.*)$/$1$3/;
            $compass .= "$dir";
        }
    }
    return $compass . $match;
}

# Generate metric as to number of common characters between two strings
# 
sub placename_match_metric {
    my ($match1, $match2) = @_;

    # First remove non-alphabetic chars
    $match1 =~ s/[^[:alpha:]]//g;
    $match2 =~ s/[^[:alpha:]]//g;
    # Lower case only
    $match1 = lc($match1);
    $match2 = lc($match2);

    # Move compass points to start
    $match1 = move_compass_to_start($match1);
    $match2 = move_compass_to_start($match2);

    # Then find common substrings
    my $ixes = String::Ediff::ediff($match1, $match2);
    #print " ediff " . $g->{name} . ", " . $d->{name} . "\n";
    #print "  matching $match1, $match2\n";
    my $common_len = 0;
    if ($ixes ne "") {
        my @ix = split(" ", $ixes);
        # Add up length of each common substring
        for (my $i = 0; $i < scalar(@ix); $i+=8) {
            my $common = $ix[$i + 1] - $ix[$i];
            my $common2 = $ix[$i + 5] - $ix[$i + 4];
            die if $common != $common2;

            die if $ix[$i + 2] != 0;
            die if $ix[$i + 3] != 0;

            die if $ix[$i + 6] != 0;
            die if $ix[$i + 7] != 0;

            $common_len += $common;
        }
    }
    # e.g. "Kew" matching "Kew Ward" was too short for ediff
    # to catch, but exact substring matching will find it
    if ($common_len == 0 and index($match1, $match2) >= 0) {
        $common_len = length($match2);
    }
    if ($common_len == 0 and index($match2, $match1) >= 0) {
        $common_len = length($match1);
    }
    return $common_len;
}

1;
