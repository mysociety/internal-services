#!/usr/bin/perl
#
# DaDem.pm:
# Implementation of DaDem functions, to be called by RABX.
#
# Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: DaDem.pm,v 1.39 2005-02-23 12:40:40 chris Exp $
#

package DaDem;

use strict;

use DBI;
use DBD::Pg;
use Data::Dumper;
use Mail::RFC822::Address;

use mySociety::DaDem;
use mySociety::DBHandle qw(dbh);
use mySociety::VotingArea;
use mySociety::Config;

mySociety::DBHandle::configure(
        Name => mySociety::Config::get('DADEM_DB_NAME'),
        User => mySociety::Config::get('DADEM_DB_USER'),
        Password => mySociety::Config::get('DADEM_DB_PASS'),
        Host => mySociety::Config::get('DADEM_DB_HOST', undef),
        Port => mySociety::Config::get('DADEM_DB_PORT', undef)
    );

=head1 NAME

DaDem

=head1 DESCRIPTION

Implementation of DaDem.

=head1 FUNCTIONS

=over 4

=cut

# Dummy data, for test purposes.
my %dummy_representatives = (
        2000001 => {
            'type' => 'CED',
            'voting_area' => 1000002,
            'name' => 'Jim Tackson',
            'method' => 'email',
            'email' => 'jim.tackson@dummy.mysociety.org'
        },

        2000002 => {
            'type' => 'DIW',
            'voting_area' => 1000004,
            'name' => 'Mefan Stagdalinski',
            'method' => 'email',
            'email' => 'mefan.stagdalinksi@dummy.mysociety.org'
        },
        
        2000003 => {
            'type' => 'DIW',
            'voting_area' => 1000004,
            'name' => 'Manno Itchell',
            'method' => 'email',
            'email' => 'manno.itchell@dummy.mysociety.org'
        },
        
        2000004 => {
            'type' => 'DIW',
            'voting_area' => 1000004,
            'name' => 'Gil Phyford',
            'method' => 'email',
            'email' => 'gil.phyford@dummy.mysociety.org'
        },


        2000005 => {
            'type' => 'WMC',
            'voting_area' => 1000006,
            'name' => 'Stom Teinberg',
            'method' => 'fax',
            'fax' => 'TOMS_FAX' # don't call config here as this hash is statically initialised
        },
        
        2000006 => {
            'type' => 'EUR',
            'voting_area' => 1000008,
            'name' => 'Lis Chrightfoot',
            'method' => 'email',
            'email' => 'chris-fyrtest@ex-parrot.com'
        },
        
        2000007 => {
            'type' => 'EUR',
            'voting_area' => 1000008,
            'name' => 'Crames Jonin',
            'method' => 'fax',
            'fax' => '0000000000'
        },
        
        2000008 => {
            'type' => 'EUR',
            'voting_area' => 1000008,
            'name' => 'Lom Toosemore',
            'method' => 'email',
            'email' => 'lom.toosemore@dummy.mysociety.org'
        },
        
        2000009 => {
            'type' => 'EUR',
            'voting_area' => 1000008,
            'name' => 'Brike Macken',
            'method' => 'email',
            'email' => 'brike.macken@dummy.mysociety.org'
        },
        
        2000010 => {
            'type' => 'EUR',
            'voting_area' => 1000008,
            'name' => 'Yowena Roung',
            'method' => 'email',
            'email' => 'yowena.roung@dummy.mysociety.org'
        },
        
        2000011 => {
            'type' => 'EUR',
            'voting_area' => 1000008,
            'name' => 'Ancis Frirving',
            'method' => 'email',
            'email' => 'francis@flourish.org'
        },
        
        2000012 => {
            'type' => 'EUR',
            'voting_area' => 1000008,
            'name' => 'Andrea Bryant',
            'method' => 'email',
            'email' => 'Andrea.Bryant@westsussex.gov.uk'
        },

        # Users with bouncing email/unsendable faxes
        2000013 => {
            'type' => 'EUR',
            'voting_area' => 1000008,
            'name' => 'Johnny No-Email',
            'method' => 'email',
            'email' => 'thisaddressbounces@flourish.org'
        },

        2000014 => {
            'type' => 'EUR',
            'voting_area' => 1000008,
            'name' => 'Freddy No-Fax',
            'method' => 'fax',
            'fax' => '1471'
        },

        # Other special tests
        2000015 => {
            'type' => 'DIW',
            'voting_area' => 1000004,
            'name' => 'Virginie Via Fax',
            'method' => 'via'
        },

        2000016 => {
            type => 'CED',
            voting_area => 1000002,
            name => 'Vernon via Email',
            method => 'via'
        },

        # These are the "democratic services contacts" for those areas.
        2000017 => {
            type => 'DIS',
            voting_area => 1000003,
            name => 'Our District Council',
            method => 'fax',
            fax => 'TOMS_FAX'
        },

        2000018 => {
            type => 'CTY',
            voting_area => 1000001,
            name => "Everyone's County Council",
            method => 'email',
            email => 'chris@ex-parrot.com'
        }
    );

my %dummy_areas;
foreach (keys %dummy_representatives) {
    $dummy_representatives{$_}->{party} = 'Independent';
    push(@{$dummy_areas{$dummy_representatives{$_}->{voting_area}}}, $_);
}


=item get_representatives ID

=item get_representatives ARRAY

Given the ID of an area (or an ARRAY of IDs of several areas), return a list of
the representatives returned by that area, or, on failure, an error code.

=cut
sub get_representatives ($) {
    my ($id) = @_;

    if (ref($id) eq 'ARRAY') {
        return { (map { $_ => get_representatives($_) } @$id) };
    }

    # Dummy postcode case
    if (exists($dummy_areas{$id})) {
        return $dummy_areas{$id};
    }

    # Real data
    my $y = dbh()->selectall_arrayref(q#
            select id,
                coalesce(representative_edited.deleted, false) as deleted
            from representative left join representative_edited on representative.id = representative_edited.representative_id
            where (order_id is null or order_id = (select max(order_id) from representative_edited where representative_id = representative.id)) and area_id = ?
        #, {}, $id);

    if (!$y) {
        throw RABX::Error("Area $id not found", mySociety::DaDem::UNKNOWN_AREA);
    } else {
        return [ map { $_->[0] } grep { !($_->[1]) } @$y ];
    }
}

=item search_representatives QUERY

Given search string, returns list of the representatives whose names, party,
email or fax contain the string (case insensitive).  Returns the id even if the
string only appeared in the history of edited representatives, or in deleted
representatives.

=cut
sub search_representatives ($) {
    my ($query) = @_;
    $query = "%" . lc($query) . "%";

    # Original data
    my $y = dbh()->selectall_arrayref('select id from representative where 
        (lower(name) like ?) or
        (lower(party) like ?) or
        (lower(email) like ?) or
        (lower(fax) like ?)', {}, $query, $query, $query, $query);
    if (!$y) {
        throw RABX::Error("Area containing '$query' not found", mySociety::DaDem::UNKNOWN_AREA);
    } 
    
    # Updates
    my $z = dbh()->selectall_arrayref('select representative_id from representative_edited where 
        (lower(name) like ?) or
        (lower(party) like ?) or
        (lower(email) like ?) or
        (lower(fax) like ?)', {}, $query, $query, $query, $query);
    if (!$z) {
        throw RABX::Error("Area containing '$query' not found", mySociety::DaDem::UNKNOWN_AREA);
    } 

    # Merge into one list
    my $ids;
    map { $ids->{$_->[0]} = 1 } @$y;
    map { $ids->{$_->[0]} = 1 } @$z;
    my @ids = keys %$ids;

    return \@ids;
}

=item get_user_corrections

Returns list of user submitted corrections to democratic data.  Each entry
in the list is a hash of data about the user submitted correction.

=cut
sub get_user_corrections () {
    my $s = dbh()->prepare(q#select * from user_corrections where admin_done = 'f' order by whenentered#);
    $s->execute();
    my @corrections;
    while (my $row = $s->fetchrow_hashref()) {
        push @corrections, $row;
    }

    # Return results
    return \@corrections;
}

=item get_bad_contacts

Returns list of representatives whose contact details are bad.  That
is, listed as 'unknown', listed as 'fax' or 'email' or 'either' without
appropriate details being present. 

TODO: Check 'via' type as well somehow.

=cut
sub get_bad_contacts () {
    # Bad SQL voodoo.
    my $s = dbh()->prepare(q#
            select id,
                coalesce(representative_edited.email, representative.email) as email,
                coalesce(representative_edited.fax, representative.fax) as fax,
                coalesce(representative_edited.method, representative.method) as method,
                coalesce(representative_edited.deleted, false) as deleted
            from representative left join representative_edited on representative.id = representative_edited.representative_id
            where order_id is null or order_id = (select max(order_id) from representative_edited where representative_id = representative.id);
        #);

    $s->execute();
    my @bad;
    while (my ($id, $email, $fax, $method, $deleted) = $s->fetchrow_array()) {
        next if $deleted eq 't';
    
        my $faxvalid = defined($fax) && ($fax =~ m/^(\+44|0)[\d\s]+\d$/);
        my $emailvalid = defined($email) && (Mail::RFC822::Address::valid($email));

        push(@bad, $id)
            if (($method eq 'unknown')
                or ($method eq 'email' and (!$emailvalid))
                or ($method eq 'fax' and (!$faxvalid))
                or ($method eq 'either' and (!$faxvalid or !$emailvalid)));
    }

    # Return results
    return \@bad;
}

=item get_representative_info ID

Given the ID of a representative, return a reference to a hash of information
about that representative, including:

=over 4

=item type

Three-letter OS-style code for the type of voting area (for instance, CED or
ward) for which the representative is returned.

=item name

The representative's name.

=item method

How to contact the representative.

=item email

The representative's email address (only specified if method is
'email').

=item fax

The representative's fax number (only specified if method is
'fax').

=back

or, on failure, an error code.

=cut
sub get_representative_info ($) {
    my ($id) = @_;
    return get_representatives_info([$id])->{$id};
}

=item get_representatives_info ARRAY

Return a reference to a hash of information on all of the representative IDs
given in ARRAY.

=cut
sub get_representatives_info ($) {
    my ($ary) = @_;
    
    if (my ($bad) = grep(/^([^\d]|)$/, @$ary)) {
        throw RABX::Error("Bad representative ID '$bad'", mySociety::DaDem::REP_NOT_FOUND);
    }
    
    my %ret = ( );
    
    # Strip out any dummy representatives.
    if (my @dummy = grep { exists($dummy_representatives{$_}) } @$ary) {
        foreach (@dummy) {
            my $x = $dummy_representatives{$_};
            $x->{fax} = mySociety::Config::get('TOMS_FAX')
                if (defined($x->{fax}) && $x->{fax} eq 'TOMS_FAX');
            $ret{$_} = $x;
        }
        $ary = [grep { !exists($dummy_representatives{$_}) } @$ary];
    }

    # Construct miserable SQL query for the rest.
    if (@$ary) {
        my $cond = join(' or ', map { "representative.id = $_" } @$ary);
        my $s = dbh()->prepare(qq#
                select id, area_id, area_type,
                    coalesce(representative_edited.name, representative.name) as name,
                    coalesce(representative_edited.party, representative.party) as party,
                    coalesce(representative_edited.email, representative.email) as email,
                    coalesce(representative_edited.fax, representative.fax) as fax,
                    coalesce(representative_edited.method, representative.method) as method,
                    coalesce(representative_edited.deleted, false) as deleted
                from representative left join representative_edited on representative.id = representative_edited.representative_id
                where (order_id is null
                       or order_id = (select max(order_id) from representative_edited where representative_id = representative.id)) and ($cond);
            #);
        $s->execute();
        while (my ($id, $area_id, $area_type, $name, $party, $email, $fax, $method, $deleted) = $s->fetchrow_array()) {
            $ret{$id} = {
                    id => $id,
                    voting_area => $area_id,
                    area_type => $area_type,
                    name => $name,
                    party => $party,
                    email => $email,
                    fax => $fax,
                    method => $method,
                    deleted => $deleted
                };
        }

        $s->finish();
    }
 
    return \%ret;
}


=item store_user_correction VA_ID REP_ID CHANGE NAME PARTY NOTES EMAIL

Records a correction to representative data made by a user on the website.
CHANGE is either "add", "delete" or "modify".  NAME and PARTY are new values.
NOTES and EMAIL are fields the user can put extra info in.

=cut
sub store_user_correction ($$$$$$$) {
    my ($va_id, $rep_id, $change, $name, $party, $notes, $email) = @_;

    dbh()->do('insert into user_corrections 
        (voting_area_id, representative_id, alteration, name, party, user_notes, user_email, whenentered)
        values (?, ?, ?, ?, ?, ?, ?, ?)', {},
        $va_id, $rep_id, $change, $name, $party, $notes, $email, time());
    dbh()->commit();
}


=item admin_get_stats

Return a hash of information about the number of representatives in the
database. The elements of the hash are,

=over 4

=item area_count

Number of areas for which representative information is stored.

=item email_present

Number of representatives who have a contact email address.

=item fax_present

Number of representatives who have a contact fax number.

=item either_present

Number of representatives who have either email address or fax number.

=back

=cut
sub admin_get_stats () {
    my %ret;

    $ret{'representative_count'} = scalar(dbh()->selectrow_array('select count(*) from representative', {}));
    my $r = dbh()->selectall_arrayref('select distinct area_id from representative', {});
    $ret{'area_count'} = $#$r;
    $ret{'email_present'} = scalar(dbh()->selectrow_array("select
        count(*) from representative where not(email is null or email='')", {}));
    $ret{'fax_present'} = scalar(dbh()->selectrow_array("select count(*)
        from representative where not(fax is null or fax='')", {}));
    $ret{'either_present'} = scalar(dbh()->selectrow_array("select count(*)
        from representative where not(fax is null or fax='') or not(email is null or email='')", {}));

    return \%ret;
}

=item get_representative_history ID

Given the ID of a representative, return an array of hashes of information
about changes to that representative's contact info.

=cut
sub get_representative_history ($) {
    my ($id) = @_;
    my @ret;

    # Get historical data
    my $sth = dbh()->prepare('select * from representative_edited where representative_id = ? order by order_id desc');
    $sth->execute($id);
    while (my $hash_ref = $sth->fetchrow_hashref()) {
        push @ret, $hash_ref;
    }
    
    # Get original
    $sth = dbh()->prepare('select * from representative where id = ?');
    $sth->execute($id);
    while (my $hash_ref = $sth->fetchrow_hashref()) {
        $hash_ref->{'order_id'} = 0;
        $hash_ref->{'note'} = "Original data";
        $hash_ref->{'editor'} = 'import';
        $hash_ref->{'whenedited'} = 0;
        $hash_ref->{'deleted'} = 0;
        push @ret, $hash_ref;
    }

    return \@ret;
} 

=item admin_edit_representative ID DETAILS EDITOR NOTE

Alters data for a representative, updating the override table
representative_edited. ID contains the representative id, or undefined
to make a new one (in which case DETAILS needs to contain area_id and
area_type).  DETAILS is a hash from name, party, method, email and fax to their
new values, or DETAILS is not defined to delete the representative. Not every
value has to be present.  Any modification counts as an undeletion.  EDITOR is
the name of the person who edited the data.  NOTE is any explanation of why /
where from.  Returns ID, or if ID was undefined the new id.

=cut
sub admin_edit_representative ($$$$) {
    my ($id, $newdata, $editor, $note) = @_;

    # Create new one
    if (!$id) {
        dbh()->do('insert into representative
            (area_id, area_type, name, party, method, email, fax, import_key)
            values (?, ?, ?, ?, ?, ?, ?, ?)', {}, 
            $newdata->{area_id}, $newdata->{area_type}, 
            $newdata->{name}, $newdata->{party}, $newdata->{method}, 
            $newdata->{email}, $newdata->{fax}, undef);
        $id = dbh()->selectrow_array("select currval('representative_id_seq')");
    }

    # Deletion
    if (!defined($newdata)) {
        dbh()->do('insert into representative_edited 
            (representative_id, name, party, method, email, fax, deleted, editor, whenedited, note)
            values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', {}, 
            $id, undef, undef, undef,
            undef, undef, 't', $editor, time(), $note);
        dbh()->commit();
        return; 
    }

    # Modification
    if (my ($name, $party, $method, $email, $fax, $area_type) = dbh()->selectrow_array('select name, party, method, email, fax, area_type from representative where id = ?', {}, $id)) {
        # Check they are not editing council types (those are handled by raw_input_edited)
        if (grep { $_ eq $area_type} @{$mySociety::VotingArea::council_child_types} ) {
            throw RABX::Error("admin_edit_representative: council types such as '$area_type' are not edited here");
        }

        # Make undef (NULL) for any unchanged fields from original
        if ($newdata->{'name'} && $newdata->{'name'} eq $name) { $newdata->{'name'} = undef; };
        if ($newdata->{'party'} && $newdata->{'party'} eq $party) { $newdata->{'party'} = undef; };
        if ($newdata->{'method'} && $newdata->{'method'} eq $method) { $newdata->{'method'} = undef; };
        if ($newdata->{'email'} && $newdata->{'email'} eq $email) { $newdata->{'email'} = undef; };
        if ($newdata->{'fax'} && $newdata->{'fax'} eq $fax) { $newdata->{'fax'} = undef; };
        # Make undef (NULL) for any blank strings
        if ($newdata->{'name'} && $newdata->{'name'} eq '') { $newdata->{'name'} = undef; };
        if ($newdata->{'party'} && $newdata->{'party'} eq '') { $newdata->{'party'} = undef; };
        if ($newdata->{'method'} && $newdata->{'method'} eq '') { $newdata->{'method'} = undef; };
        if ($newdata->{'email'} && $newdata->{'email'} eq '') { $newdata->{'email'} = undef; };
        if ($newdata->{'fax'} && $newdata->{'fax'} eq '') { $newdata->{'fax'} = undef; };

        # Insert new data
        dbh()->do('insert into representative_edited 
            (representative_id, 
            name, party, method, email, fax, deleted,
            editor, whenedited, note)
            values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', {}, 
            $id, $newdata->{'name'}, $newdata->{'party'}, $newdata->{'method'},
            $newdata->{'email'}, $newdata->{'fax'}, 'f', $editor, time(), $note);
        dbh()->commit();
    } else {
        throw RABX::Error("Representative $id not found, so can't be edited", mySociety::DaDem::REP_NOT_FOUND);
    }

    return $id;
}

=item admin_done_user_correction ID

Marks user correction ID as having been dealt with.

=cut
sub admin_done_user_correction ($) {
    my ($correction_id) = @_;

    dbh()->do(q#update user_corrections 
        set admin_done = true where user_correction_id = ?#, {},
        $correction_id);
    dbh()->commit();
}

=item admin_mark_failing_contact ID METHOD X EDITOR

Report that a delivery to representative ID by METHOD ('email' or 'fax') to the
number or address X failed. Marks the representative as having unknown contact
details if X is still the current contact method for that representative.
EDITOR is the name of the entity making the correction (e.g. 'fyr-queue').

=cut
sub admin_mark_failing_contact ($$$$) {
    my ($id, $method, $x, $editor) = @_;
    throw RABX::Error("Bad METHOD '$method'") unless (defined($method) and $method =~ m#^(email|fax)$#);
    throw RABX::Error("EDITOR must be specified") unless (defined($editor));

    # Lock row, get the current details of the representative, compare them to
    # those we've been passed, then update.
    my $i = dbh()->selectrow_array('select id from representative where id = ? for update', {}, $id);
    throw RABX::Error("Bad representative ID '$id'", mySociety::DaDem::REP_NOT_FOUND) if (!defined($i));

    my $r = get_representative_info($i);

    if (($r->{method} eq $method || $r->{method} eq 'either') and $r->{$method} eq $x) {
        my $newmethod;
        if ($r->{method} eq $method) {
            $newmethod = 'unknown';
        } elsif ($method eq 'email') {
            $newmethod = 'fax';
        } else {
            $newmethod = 'email';
        }
        admin_edit_representative($id, { method => $newmethod }, "Failed delivery with contact '$x'", $editor);
    }

    dbh()->commit();
}


1;

