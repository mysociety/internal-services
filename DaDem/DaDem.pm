#!/usr/bin/perl
#
# DaDem.pm:
# Implementation of DaDem functions, to be called by RABX.
#
# Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: DaDem.pm,v 1.12 2004-12-13 14:54:31 francis Exp $
#

package DaDem;

use strict;
use mySociety::DaDem;
use mySociety::VotingArea;
use mySociety::Config;

use DBI;
use DBD::Pg;

=head1 NAME

DaDem

=head1 DESCRIPTION

Implementation of DaDem.

=head1 FUNCTIONS

=over 4

=cut
sub dbh () {
    our $dbh;
    $dbh ||= DBI->connect('dbi:Pg:dbname=' .  mySociety::Config::get('DADEM_DB_NAME'),
                        mySociety::Config::get('DADEM_DB_USER'),
                        mySociety::Config::get('DADEM_DB_PASS'),
                        { RaiseError => 1, AutoCommit => 0 });

    return $dbh;
}

# Dummy data, for test purposes.
my %dummy_representatives = (
        2000001 => {
            type => mySociety::VotingArea::CED,
            'voting_area' => 1000002,
            name => 'Jim Tackson',
            contact_method => 'email',
            email => 'jim.tackson@dummy.mysociety.org'
        },

        2000002 => {
            'type' => mySociety::VotingArea::DIW,
            'voting_area' => 1000004,
            'name' => 'Mefan Stagdalinski',
            'contact_method' => 'email',
            'email' => 'mefan.stagdalinksi@dummy.mysociety.org'
        },
        
        2000003 => {
            'type' => mySociety::VotingArea::DIW,
            'voting_area' => 1000004,
            'name' => 'Manno Itchell',
            'contact_method' => 'email',
            'email' => 'manno.itchell@dummy.mysociety.org'
        },
        
        2000004 => {
            'type' => mySociety::VotingArea::DIW,
            'voting_area' => 1000004,
            'name' => 'Gil Phyford',
            'contact_method' => 'email',
            'email' => 'gil.phyford@dummy.mysociety.org'
        },
        
        2000005 => {
            'type' => mySociety::VotingArea::WMC,
            'voting_area' => 1000006,
            'name' => 'Andrea Bryant',
            'contact_method' => 'email',
            'email' => 'Andrea.Bryant@westsussex.gov.uk'
        },
        
        2000006 => {
            'type' => mySociety::VotingArea::EUR,
            'voting_area' => 1000008,
            'name' => 'Lis Chrightfoot',
            'contact_method' => 'email',
            'email' => 'chris-fyrtest@ex-parrot.com'
        },
        
        2000007 => {
            'type' => mySociety::VotingArea::EUR,
            'voting_area' => 1000008,
            'name' => 'Crames Jonin',
            'contact_method' => 'fax',
            'fax' => '0000000000'
        },
        
        2000008 => {
            'type' => mySociety::VotingArea::EUR,
            'voting_area' => 1000008,
            'name' => 'Lom Toosemore',
            'contact_method' => 'email',
            'email' => 'lom.toosemore@dummy.mysociety.org'
        },
        
        2000009 => {
            'type' => mySociety::VotingArea::EUR,
            'voting_area' => 1000008,
            'name' => 'Brike Macken',
            'contact_method' => 'email',
            'email' => 'brike.macken@dummy.mysociety.org'
        },
        
        2000010 => {
            'type' => mySociety::VotingArea::EUR,
            'voting_area' => 1000008,
            'name' => 'Yowena Roung',
            'contact_method' => 'email',
            'email' => 'yowena.roung@dummy.mysociety.org'
        },
        
        2000011 => {
            'type' => mySociety::VotingArea::EUR,
            'voting_area' => 1000008,
            'name' => 'Ancis Frirving',
            'contact_method' => 'email',
            'email' => 'francis@flourish.org'
        },
        
        2000012 => {
            'type' => mySociety::VotingArea::EUR,
            'voting_area' => 1000008,
            'name' => 'Stom Teinberg',
            'contact_method' => 'fax',
            'fax' => 'TOMS_FAX' # don't call config here as this hash is statically initialised
        },

        # Users with bouncing email/unsendable faxes
        2000013 => {
            type => mySociety::VotingArea::EUR,
            voting_area => 1000008,
            name => 'Johnny No-Email',
            contact_method => 'email',
            email => 'thisaddressbounces@flourish.org'
        },

        2000014 => {
            type => mySociety::VotingArea::EUR,
            voting_area => 1000008,
            name => 'Freddy No-Fax',
            contact_method => 'fax',
            fax => '1471'
        }

#            'name' => 'Tu Stily',
    );

my %dummy_areas;
foreach (keys %dummy_representatives) {
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
    my $y = dbh()->selectall_arrayref('select id from representative where area_id = ?', {}, $id);
    if (!$y) {
        throw RABX::Error("Area $id not found", mySociety::DaDem::UNKNOWN_AREA);
    } else {
        return [ map { $_->[0] } @$y ];
    }
}

=item get_representative_info ID

Given the ID of a representative, return a reference to a hash of information
about that representative, including:

=over 4

=item type

Numeric code for the type of voting area (for instance, CED or ward) for which
the representative is returned.

=item name

The representative's name.

=item contact_method

How to contact the representative.

=item email

The representative's email address (only specified if contact_method is
CONTACT_EMAIL).

=item fax

The representative's fax number (only specified if contact_method is
CONTACT_FAX).

=back

or, on failure, an error code.

=cut
sub get_representative_info ($) {
    my ($id) = @_;
    
    # Dummy postcode case
    if (exists($dummy_representatives{$id})) {
        my $ret = $dummy_representatives{$id};
        $ret->{'fax'} = mySociety::Config::get("TOMS_FAX") if (defined($ret->{'fax'}) && $ret->{'fax'} eq 'TOMS_FAX');
        return $ret;
    }

    # Real data case
    if (my ($area_id, $area_type, $name, $party, $method, $email, $fax) = dbh()->selectrow_array('select area_id, area_type, name, party, method, email, fax from representative where id = ?', {}, $id)) {

        return {
                voting_area => $area_id,
                type => $mySociety::VotingArea::type_to_id{$area_type},
                name => $name,
                party => $party,
                method => $method,
                email => $email,
                fax => $fax
            };
    } else {
        throw RABX::Error("Representative $id not found", mySociety::DaDem::REP_NOT_FOUND);
    }
}

=item get_representatives_info ARRAY

Return a reference to a hash of information on all of the representative IDs
given in ARRAY.

=cut
sub get_representatives_info ($) {
    my ($ary) = @_;
    return { (map { $_ => get_representative_info($_) } @$ary) };
}

=item admin_get_stats

=cut
sub admin_get_stats ($) {
    () = @_;
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

#    my $rows = dbh()->selectall_arrayref('select type, count(*) from area group by type', {});
#    warn Dumper($rows);
#    foreach (@$rows) {
#        my ($type, $count) = @$_; 
#        $ret{'area_count_'. $type} = $count;
#    }

    return \%ret;
}

1;

