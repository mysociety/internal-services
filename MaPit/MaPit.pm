#!/usr/bin/perl
#
# MaPit.pm:
# Implementation of MaPit functions, to be called by RABX.
#
# Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: MaPit.pm,v 1.13 2005-02-04 11:10:02 chris Exp $
#

package MaPit;

use strict;

use DBI;
use DBD::Pg;
use Data::Dumper;

use mySociety::Config;
use mySociety::DBHandle qw(dbh);
use mySociety::MaPit;
use mySociety::Util;
use mySociety::VotingArea;

mySociety::DBHandle::configure(
        Name => mySociety::Config::get('MAPIT_DB_NAME'),
        User => mySociety::Config::get('MAPIT_DB_USER'),
        Password => mySociety::Config::get('MAPIT_DB_PASS'),
        Host => mySociety::Config::get('MAPIT_DB_HOST', undef),
        Port => mySociety::Config::get('MAPIT_DB_PORT', undef)
    );

=head1 NAME

MaPit

=head1 DESCRIPTION

Implementation of MaPit

=head1 FUNCTIONS

=over 4

=cut

# Special cases to represent parliaments, assemblies themselves.
use constant DUMMY_ID => 1000000;

my %special_cases = (
        # Enclosing areas.
        mySociety::VotingArea::WMP_AREA_ID => {
            type => 'WMP',
            name => 'House of Commons'
        },
        
        mySociety::VotingArea::EUP_AREA_ID => {
            type => 'EUP',
            name => 'European Parliament'
        },

        mySociety::VotingArea::LAE_AREA_ID => {
            type => 'LAE',
            name => 'London Assembly' # Proportionally elected area
        },

        mySociety::VotingArea::LAS_AREA_ID => {
            type => 'LAS',
            name => 'London Assembly' # Containing body
        },

        mySociety::VotingArea::SPA_AREA_ID => {
            type => 'SPA',
            name => 'Scottish Parliament'
        },

        mySociety::VotingArea::WAS_AREA_ID => {
            type => 'WAS',
            name => 'National Assembly for Wales'
        },

        mySociety::VotingArea::NIA_AREA_ID => {
            type => 'NIA',
            name => 'Northern Ireland Assembly'
        },

        # Test data
        1000001 => {
            type => 'CTY',
            name => "Everyone's County Council"
        },
        1000002 => {
            type => 'CED',
            name => 'Chest Westerton ED'
        },
        1000003 => {
            type => 'DIS',
            name => 'Our District Council'
        },
        1000004 => {
            type => 'DIW',
            name => 'Chest Westerton Ward'
        },
        1000005 => {
            type => 'WMP',
            name => 'House of Commons'
        },
        1000006 => {
            type => 'WMC',
            name => 'Your and My Society'
        },
        1000007 => {
            type => 'EUP',
            name => 'European Parliament'
        },
        1000008 => {
            type => 'EUR',
            name => 'Windward Euro Region'
        }
    );

# Map area type to ID of "fictional" (i.e., not in DB) enclosing area.
my %enclosing_areas = (
        'LAC' => [mySociety::VotingArea::LAE_AREA_ID, mySociety::VotingArea::LAS_AREA_ID],
        'SPC' => [mySociety::VotingArea::SPA_AREA_ID],
        'WAC' => [mySociety::VotingArea::WAS_AREA_ID],
        'NIE' => [mySociety::VotingArea::NIA_AREA_ID],
        'WMC' => [mySociety::VotingArea::WMP_AREA_ID],
        'EUR' => [mySociety::VotingArea::EUP_AREA_ID],
    );

=item get_generation

Return current MaPit data generation.

=cut
sub get_generation () {
    return scalar(dbh()->selectrow_array('select id from current_generation'));
}

=item get_voting_areas POSTCODE

Return voting area IDs for POSTCODE.

=cut
sub get_voting_areas ($) {
    my ($pc) = @_;
    
    my $ret = undef;
    my $generation = get_generation();
    
    $pc =~ s/\s+//g;
    $pc = uc($pc);

    if ($pc eq 'ZZ99ZZ') {
        # Dummy postcode case
        $ret = {
                map { $special_cases{$_}->{type} => $_ } grep { $_ >= DUMMY_ID } keys(%special_cases)
            };
    } else {
        # Real data
        throw RABX::Error("Postcode '$pc' is not valid.", mySociety::MaPit::BAD_POSTCODE) unless (mySociety::Util::is_valid_postcode($pc));

        my $pcid = dbh()->selectrow_array('select id from postcode where postcode = ?', {}, $pc);
        throw RABX::Error("Postcode '$pc' not found.", mySociety::MaPit::POSTCODE_NOT_FOUND) if (!$pcid);

        # Also add pseudo-areas.
        $ret = {
                ( map { $_->[0] => $_->[1] } @{
                        dbh()->selectall_arrayref('
                        select type, id from postcode_area, area 
                            where postcode_area.area_id = area.id 
                            and postcode_area.postcode_id = ? 
                            and generation_low <= ? and ? <= generation_high
                        ', {}, $pcid, $generation, $generation)
                    })
            };
    }

    # Add fictional enclosing areas.
    foreach my $ty (keys %enclosing_areas) {
        if (exists($ret->{$ty})) {
            my $encls = $enclosing_areas{$ty};
            foreach my $encl (@$encls) {
                $ret->{$special_cases{$encl}->{type}} = $encl;
            }
        }
    }

    return $ret;
}

=item get_voting_area_info ID

=cut
sub get_voting_area_info ($) {
    my ($id) = @_;

    my $ret;
    if (exists($special_cases{$id})) {
        $ret = $special_cases{$id};
    } else {
        # Real data
        my ($type, $name, $parent_area_id);
        throw RABX::Error("Voting area not found id $id",
        mySociety::MaPit::AREA_NOT_FOUND) unless (($type, $name,
        $parent_area_id) = dbh()->selectrow_array("
            select type, name, parent_area_id from area, area_name 
                where area_name.area_id = area.id 
                and name_type = 'F'
                and id = ?
            ", {}, $id));
     
        $ret = {
                name => $name,
                parent_area_id => $parent_area_id,
                type => $type
            };
    }

    # Annotate with information about the representative type returned for that
    # area.
    foreach (qw(type_name attend_prep rep_name rep_name_plural
                rep_name_long rep_name_long_plural rep_suffix rep_prefix)) {
        no strict 'refs';
        $ret->{$_} = ${"mySociety::VotingArea::$_"}{$ret->{type}};
    }
    return $ret;
}

=item get_example_postcode ID

Given an area ID, returns one postcode that maps to it.

=cut
sub get_example_postcode ($) {
    my ($area_id) = @_;
    my $pc = scalar(dbh()->selectrow_array("select postcode from postcode, postcode_area
        where postcode.id = postcode_area.postcode_id and area_id = ?
        limit 1", {}, $area_id));
    throw RABX::Error("Voting area not found id $area_id") unless defined $pc;

    return $pc;
}

=item get_voting_areas_info ARY

=cut
sub get_voting_areas_info ($) {
    my ($ary) = @_;
    return { (map { $_ => get_voting_area_info($_) } @$ary) };
}

=item get_voting_area_children ID

=cut
sub get_voting_area_children ($) {
    my ($id) = @_;
    return dbh()->selectcol_arrayref('select id from area where parent_area_id = ?', {}, $id);
}

=item get_location POSTCODE

Return the location of the given POSTCODE, including the grid system to which
it is registered. The return value is a list of three elements: the coordinate
system ("G" for OSGB or "I" for the Irish grid) and eastings and northings in
meters.

=cut
sub get_location ($) {
    my ($pc) = @_;
    
    my $ret = undef;
    my $generation = get_generation();

    $pc =~ s/\s+//g;
    $pc = uc($pc);

    if ($pc eq 'ZZ99ZZ') {
        # Dummy postcode.
        return ['G', 0, 0]; # Somewhere off in the Atlantic
    } else {
        # Real data
        throw RABX::Error("Postcode '$pc' is not valid.", mySociety::MaPit::BAD_POSTCODE) unless (mySociety::Util::is_valid_postcode($pc));

        if (my ($coordsyst, $E, $N) = dbh()->selectrow_array('select coordsyst, easting, northing from postcode where postcode = ?', {}, $pc)) {
            return [$coordsyst, $E, $N];
        } else {
            throw RABX::Error("Postcode '$pc' not found.", mySociety::MaPit::POSTCODE_NOT_FOUND);
        }
    }
}

=item admin_get_stats

=cut
sub admin_get_stats () {
    () = @_;
    my %ret;

#    $ret{'postcode_count'} = scalar(dbh()->selectrow_array('select count(*) from postcode', {}));
    $ret{'postcode_count'} = "skipped";
    $ret{'area_count'} = scalar(dbh()->selectrow_array('select count(*) from area', {}));

    my $rows = dbh()->selectall_arrayref('select type, count(*) from area group by type', {});
    foreach (@$rows) {
        my ($type, $count) = @$_; 
        $ret{'area_count_'. $type} = $count;
    }

    return \%ret;
}

1;
