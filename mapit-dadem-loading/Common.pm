#!/usr/bin/perl
#
# Common.pm:
# Common stuff for data importing.
#
# Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: Common.pm,v 1.2 2004-11-29 19:00:58 chris Exp $
#

package Common;

use strict;

@Common::ISA = qw(Exporter);
@Common::EXPORT = qw(
        &current_generation
        &new_generation
        &make_new_generation_active
        &get_area_id
        &get_postcode_id
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



1;
