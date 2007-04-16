#!/usr/bin/perl
#
# DaDem.pm:
# Implementation of DaDem functions, to be called by RABX.
#
# Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: DaDem.pm,v 1.80 2007-04-16 23:11:42 matthew Exp $
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
use mySociety::MaPit;

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

=head1 CONSTANTS

=head2 Error codes

=over 4

=item UNKNOWN_AREA 3001

Area ID refers to a non-existent area.

=item REP_NOT_FOUND 3002

Representative ID refers to a non-existent representative.

=item AREA_WITHOUT_REPS 3003

Area ID refers to an area for which no representatives are returned.

=item PERSON_NOT_FOUND 3004

Preson ID refers to a non-existent person.

=back

=head2 Other codes

=over 4

=item CONTACT_FAX 101

Means of contacting representative is fax.

=item CONTACT_EMAIL 102

Means of contacting representative is email.

=back


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
            'fax' => 'TOMS_FAX', # don't call config here as this hash is statically initialised
            'email' => 'tom@mysociety.org'
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
            'email' => 'thisaddressbounces@parliament.uk'
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
        },

        # Specific to other organisations which need to test
        2000100 => {
            'type' => 'WMC',
            'voting_area' => 1000100,
            'name' => 'Old Chapel',
            'method' => 'fax',
            'fax' => '01732 366533'
        },
     );

my %dummy_areas;
foreach (keys %dummy_representatives) {
    $dummy_representatives{$_}->{party} = 'Independent';
    push(@{$dummy_areas{$dummy_representatives{$_}->{voting_area}}}, $_);
}

# Given method, email and fax returns if it looks like a known contact
sub check_valid_method($$$) {
    my ($method, $fax, $email) = @_;

    my $faxvalid = defined($fax) && ($fax =~ m/^(\+44|0)[\d\s]+\d$/);
    my $emailvalid = defined($email) && (Mail::RFC822::Address::valid($email));

    return !(
            (($method eq 'unknown')
            or ($method eq 'email' and (!$emailvalid))
            or ($method eq 'fax' and (!$faxvalid))
            or ($method eq 'either') # 'either' is deprecated, as it is confusing
            ));
}


=item get_representatives ID_or_ARRAY [ALL]

Given the ID of an area (or an ARRAY of IDs of several areas), return a list of
the representatives returned by that area, or, for an array, a hash mapping
area ID to a list of representatives for each; or, on failure, an error code.
The default is to return only current reprenatives.  If ALL has value 1, then
even deleted representatives are returned. 

=cut
sub get_representatives ($;$) {
    my ($id, $all) = @_;
    
    if (ref($id)) {
        if (ref($id) eq 'ARRAY') {
            return { (map { $_ => get_representatives($_, $all) } @$id) };
        } else {
            throw RABX::Error("Argument must be a scalar ID or an array in get_representatives, not " . ref($id));
        }
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
    } 
    
    if ($all) {
        return [ map { $_->[0] } @$y ];
    } else {
        return [ map { $_->[0] } grep { !($_->[1]) } @$y ];
    }
}

=item get_area_status AREA_ID

Get the electoral status of area AREA_ID.  Can be any of these:
    none - no special status
    pending_election - representative data invalid due to forthcoming election
    recent_election - representative data invalid because we haven't updated since election

=cut 
sub get_area_status($) {
    my ($area_id) = @_;
    my ($status) = dbh()->selectrow_array(q#
        select status from area_status where area_id = ?#, {}, $area_id);
    return 'none' if (!$status);
    return $status;
}

=item get_area_statuses

Get the current electoral statuses.  Can be any of these:
    none - no special status
    pending_election - representative data invalid due to forthcoming election
    recent_election - representative data invalid because we haven't updated since election

=cut 
sub get_area_statuses() {
    my $ref = dbh()->selectall_arrayref(q#
        select area_id,status from area_status#, {});
    return 'none' if (!$ref);
    return $ref;
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
is, listed as 'unknown', listed as 'fax' or 'email' without appropriate details
being present, or listed as 'either'. (There's a new policy to discourages
'eithers' at all, as they are confusing).

TODO: Check 'via' type as well somehow.

=cut
sub get_bad_contacts () {
    # Bad SQL voodoo.
    my $s = dbh()->prepare(q#
            select id,
                coalesce(representative_edited.email, representative.email) as email,
                coalesce(representative_edited.fax, representative.fax) as fax,
                coalesce(representative_edited.method, representative.method) as method,
                coalesce(representative_edited.deleted, false) as deleted,
                coalesce(representative_edited.editor, 'import') as editor,
                coalesce(representative_edited.name, representative.name) as name,
                representative.area_id
            from representative left join representative_edited on representative.id = representative_edited.representative_id
            where (order_id is null or order_id = 
                        (select max(order_id) from representative_edited where representative_id = representative.id)
                  ) 
                  and coalesce(representative_edited.method, representative.method) <> 'via'
                  and not(coalesce(representative_edited.deleted, false))
            order by representative.area_type, (editor = 'fyr-queue'),
                substring(representative.name from position(' ' in representative.name)+ 1),
                representative.name, representative.area_id
        #);

    $s->execute();
    my @bad;
    while (my ($id, $email, $fax, $method, $deleted, $editor, $name, $area_id) = $s->fetchrow_array()) {

        next if check_valid_method($method, $fax, $email);

        # XXX this is very slow, especially when there are a large number of
        # bad contacts at council level.
        my $bad = 1;
        if ($name eq "Democratic Services") {
            # If none of the representatives in the council have "via" set
            # as their contact method, then it doesn't matter that it is bad

            # Get all the child areas of the council ($area_id)
            my $children = mySociety::MaPit::get_voting_area_children($area_id);
            # And the representatives of them
            my $child_reps = get_representatives($children);
            my @child_reps;
            foreach (keys %$child_reps) {
                push @child_reps, @{$child_reps->{$_}};
            }
            
            # For each representative, get current status
            my $children_info = get_representatives_info(\@child_reps);

            # Loop through children to see if any have via
            my $child_has_via = 0;
            foreach (keys %$children_info) {
                my $child_info = $children_info->{$_};
                $child_has_via = 1 if $child_info->{method} eq 'via';
                #warn "child via " . $child_info->{id} if $child_info->{method} eq 'via';
            }

            # If none have "via" set, then ignore this bad contact
            if (!$child_has_via) {
                $bad = 0;
            }
            #warn "$area_id " . $name . " $bad ";
        }

        push(@bad, $id) if $bad;
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
    my $info = get_representatives_info([$id])->{$id};
    throw RABX::Error("Representative ID '$id' not found", mySociety::DaDem::REP_NOT_FOUND) if (!$info);
    return $info;
}

=item get_representatives_info ARRAY

Return a reference to a hash of information on all of the representative IDs
given in ARRAY.

=cut
sub get_representatives_info ($) {
    my ($ary) = @_;
    
    my ($bad) = grep(/([^\d]|^$)/, @$ary);
    throw RABX::Error("Bad representative ID '$bad'", mySociety::DaDem::REP_NOT_FOUND)
        if (defined($bad));
    
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
                    coalesce(representative_edited.deleted, false) as deleted,
                    coalesce(representative_edited.editor, 'import') as editor,
                    representative.whencreated as whencreated,
                    coalesce(representative_edited.whenedited, representative.whencreated) as whenlastedited,
                    (select count(*) from representative_edited where representative_edited.representative_id = representative.id) as edit_times,
                    person_id
                from representative 
                    left join representative_edited on representative.id = representative_edited.representative_id
                    left join parlparse_link on parlparse_link.representative_id = representative.id
                where (order_id is null
                       or order_id = (select max(order_id) from representative_edited where representative_id = representative.id)) and ($cond);
            #);
        $s->execute();
        while (my ($id, $area_id, $area_type, $name, $party, $email, $fax, $method, $deleted, $editor, $whencreated, $whenlastedited, $edit_times, $person_id) = $s->fetchrow_array()) {
            # Force these to be undef if blank.
            $email ||= undef;
            $fax ||= undef;
            $party = $mySociety::Parties::canonical{$party} if exists $mySociety::Parties::canonical{$party};

            $ret{$id} = {
                    id => $id,
                    voting_area => $area_id,
                    type => $area_type,
                    name => $name,
                    party => $party,
                    email => $email,
                    fax => $fax,
                    method => $method,
                    deleted => $deleted,
                    last_editor => $editor,
                    whencreated => $whencreated,
                    whenlastedited => $whenlastedited,
                    edit_times => $edit_times,
                    parlparse_person_id => $person_id
                };
        }

        $s->finish();
    }
    return \%ret;
}

=item get_same_person PERSON_ID

Returns an array of representative identifiers which are known to be the same
person as PERSON_ID. Currently, this information only covers MPs.

=cut

sub get_same_person ($) {
    my ($person_id) = @_;

    my $same = dbh()->selectcol_arrayref("select representative_id
            from parlparse_link where person_id = ? order by representative_id", {}, $person_id);

    if (!scalar(@$same)) {
        throw RABX::Error("Bad person ID '$person_id'", mySociety::DaDem::PERSON_NOT_FOUND);
    }

    return $same;
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

=item representative_count

Number of representatives in total (including deleted, out of generation)

=item area_count

Number of areas for which representative information is stored.

=back

=cut
sub admin_get_stats () {
    my %ret;

    $ret{'representative_count'} = scalar(dbh()->selectrow_array('select count(*) from representative', {}));
    my $r = dbh()->selectall_arrayref('select distinct area_id from representative', {});
    $ret{'area_count'} = $#$r;

    return \%ret;
}

=item get_representative_history ID

Given the ID of a representative, return an array of hashes of information
about changes to that representative's contact info.

=cut
sub get_representative_history ($) {
    my ($id) = @_;
    my $info = get_representatives_history([$id])->{$id};
    throw RABX::Error("Representative ID '$id' not found", mySociety::DaDem::REP_NOT_FOUND) if (!$info);
    return $info;
}

=item get_representatives_history ID

Given an array of ids of representatives, returns a hash from representative
ids to an array of history of changes to that representative's contact info.

=cut
sub get_representatives_history ($) {
    my ($ary) = @_;
    
    if (my ($bad) = grep(/^([^\d]|)$/, @$ary)) {
        throw RABX::Error("get_representatives_history: Bad representative ID '$bad'", mySociety::DaDem::REP_NOT_FOUND);
    }
    
    my %ret = ( );
    return \%ret if !(@$ary);

    my $cond = join(' or ', map { "representative.id = $_" } @$ary);

    # Get original data
    my $sth = dbh()->prepare("select * from representative where ($cond)");
    $sth->execute();
    while (my $original_data = $sth->fetchrow_hashref()) {
        my $id = $original_data->{'id'};
        $original_data->{'order_id'} = 0;
        $original_data->{'note'} = "Original data";
        $original_data->{'editor'} = 'import';
        $original_data->{'whenedited'} = $original_data->{'whencreated'};
        $original_data->{'deleted'} = 0;
        $original_data->{'valid_method'} = check_valid_method($original_data->{'method'}, $original_data->{'fax'}, $original_data->{'email'}) ? 1 : 0;
        push @{$ret{$id}}, $original_data;
    }
    foreach my $id (keys %ret) {
        my $arr = $ret{$id};
        throw RABX::Error("get_representative_history: not exactly one original row for '$id'") if (scalar(@{$arr}) != 1);
    }

    # Get historical data
    $sth = dbh()->prepare("
            select id, area_id, area_type, order_id, whenedited, editor, note,
                coalesce(representative_edited.name, representative.name) as name,
                coalesce(representative_edited.party, representative.party) as party,
                coalesce(representative_edited.email, representative.email) as email,
                coalesce(representative_edited.fax, representative.fax) as fax,
                coalesce(representative_edited.method, representative.method) as method,
                coalesce(representative_edited.deleted, false) as deleted
            from representative, representative_edited 
            where 
            representative.id = representative_edited.representative_id
            and ($cond)
            order by order_id");
    $sth->execute();
    while (my $hash_ref = $sth->fetchrow_hashref()) {
        my $id = $hash_ref->{'id'};
        $hash_ref->{'valid_method'} = check_valid_method($hash_ref->{'method'}, $hash_ref->{'fax'}, $hash_ref->{'email'}) ? 1 : 0;
        push @{$ret{$id}}, $hash_ref;
    }
    
    return \%ret;
} 

=item admin_edit_representative ID DETAILS EDITOR NOTE

Alters data for a representative, updating the override table
representative_edited. ID contains the representative id, or undefined
to make a new one (in which case DETAILS needs to contain area_id and
area_type).  DETAILS is a hash from name, party, method, email and fax to their
new values, or DETAILS is not defined to delete the representative. Every
value has to be present - or else values are reset to their initial ones when
import first happened.  Any modification counts as an undeletion.  EDITOR is
the name of the person who edited the data.  NOTE is any explanation of why /
where from.  Returns ID, or if ID was undefined the new id.

=cut
sub admin_edit_representative ($$$$) {
    my ($id, $newdata, $editor, $note) = @_;

    throw RABX::Error("admin_edit_representative: please specify editor") if !$editor;

    # Create new one
    if (!$id) {
        dbh()->do('insert into representative
            (area_id, area_type, name, party, method, email, fax, import_key, whencreated)
            values (?, ?, ?, ?, ?, ?, ?, ?, ?)', {}, 
            $newdata->{area_id}, $newdata->{area_type}, 
            $newdata->{name}, $newdata->{party}, $newdata->{method}, 
            $newdata->{email}, $newdata->{fax}, undef, time());
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
        if ($newdata->{'email'} && $email && $newdata->{'email'} eq $email) { $newdata->{'email'} = undef; };
        if ($newdata->{'fax'} && $fax && $newdata->{'fax'} eq $fax) { $newdata->{'fax'} = undef; };
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

=item admin_mark_failing_contact ID METHOD X EDITOR COMMENT

Report that a delivery to representative ID by METHOD ('email' or 'fax') to the
number or address X failed. Marks the representative as having unknown contact
details if X is still the current contact method for that representative.
EDITOR is the name of the entity making the correction (e.g. 'fyr-queue'),
COMMENT is an extra comment to add to the change log of the representatives
details.

=cut
sub admin_mark_failing_contact ($$$$$) {
    my ($id, $method, $x, $editor, $comment) = @_;
    throw RABX::Error("Bad METHOD '$method'") unless (defined($method) and $method =~ m#^(email|fax)$#);
    throw RABX::Error("EDITOR must be specified") unless (defined($editor));

    # Lock row, get the current details of the representative, compare them to
    # those we've been passed, then update.
    my $i = dbh()->selectrow_array('select id from representative where id = ? for update', {}, $id);
    throw RABX::Error("Bad representative ID '$id'", mySociety::DaDem::REP_NOT_FOUND) if (!defined($i));

    my $r = get_representative_info($i);

    if (($r->{method} eq $method || $r->{method} eq 'either') and $r->{$method} eq $x and (!$r->{deleted})) {
        my $newmethod;
        if ($r->{method} eq $method) {
            $newmethod = 'unknown';
        } elsif ($method eq 'email') {
            $newmethod = 'fax';
        } else {
            $newmethod = 'email';
        }
        $r->{method} = $newmethod;
        admin_edit_representative($id, $r, $editor, "Failed delivery with contact '$x': $comment");
    }

    dbh()->commit();
}

=item admin_set_area_status AREA_ID NEW_STATUS

Set the electoral status of an area given by AREA_ID.  NEW_STATUS can have
any of the values described for get_area_status.

=cut 
sub admin_set_area_status($$) {
    my ($area_id, $new_status) = @_;
    throw RABX::Error("NEW_STATUS must be 'none', 'pending_election' or 'recent_election'")
        unless ($new_status eq 'none' || $new_status eq 'pending_election' || $new_status eq 'recent_election');
    dbh()->do("delete from area_status where area_id = ?", {}, $area_id);
    dbh()->do("insert into area_status (area_id, status) values (?, ?)", {}, $area_id, $new_status);
    dbh()->commit();
}

=item admin_get_raw_council_status

Returns how many councils are not in the made-live state.

=cut
sub admin_get_raw_council_status() {
    my $count = dbh()->selectrow_array('select count(*) from raw_process_status
        where status <> \'made-live\'');
    return $count;
}

=item admin_get_diligency_council TIME

Returns how many edits each administrator has made to the raw council data
since unix time TIME.  Data is returned as an array of pairs of count, name
with largest counts first.

=cut

sub admin_get_diligency_council($) {
    my ($from_time) = @_;
    my $edit_activity = dbh()->selectall_arrayref("select count(*) as c, editor 
        from raw_input_data_edited where whenedited >= ? 
        group by editor order by c desc", {}, $from_time);
    return $edit_activity;
}

=item admin_get_diligency_reps TIME

Returns how many edits each administrator has made to representatives since
unix time TIME.  Data is returned as an array of pairs of count, name with
largest counts first.

=cut

sub admin_get_diligency_reps($) {
    my ($from_time) = @_;
    my $edit_activity = dbh()->selectall_arrayref("select count(*) as c, editor 
        from representative_edited where whenedited >= ? 
        group by editor order by c desc", {}, $from_time);
    return $edit_activity;
}

1;

