#!/usr/bin/perl
#
# MaPit.pm:
# Implementation of MaPit functions, to be called by RABX.
#
# Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: MaPit.pm,v 1.2 2004-11-19 12:25:44 francis Exp $
#

package MaPit;

use strict;

use mySociety::MaPit;
use mySociety::Util;
use mySociety::VotingArea;
use mySociety::Config;

use DBI;
use DBD::SQLite;
use Data::Dumper;

=head1 NAME

MaPit

=head1 DESCRIPTION

Implementation of MaPit

=head1 FUNCTIONS

=over 4

=cut
sub dbh () {
    our $dbh;
    $dbh ||= DBI->connect('dbi:SQLite:dbname=' .  mySociety::Config::get('MAPIT_SQLITE_DB'), 
            '', '', { RaiseError => 1, AutoCommit => 0 });
    return $dbh;
}

# Special cases to represent parliaments, assemblies themselves.
use constant DUMMY_ID => 1000000;

my %special_cases = (
        # Enclosing areas.
        mySociety::VotingArea::WMP_AREA_ID => {
            type => mySociety::VotingArea::WMP,
            name => 'House of Commons'
        },
        
        mySociety::VotingArea::EUP_AREA_ID => {
            type => mySociety::VotingArea::EUP,
            name => 'European Parliament'
        },

        mySociety::VotingArea::LAE_AREA_ID => {
            type => mySociety::VotingArea::LAE,
            name => 'London Assembly'
        },

        # Test data
        1000001 => {
            type => mySociety::VotingArea::CTY,
            name => 'Everyone\'s County Council'
        },
        1000002 => {
            type => mySociety::VotingArea::CED,
            name => 'Chest Westerton ED'
        },
        1000003 => {
            type => mySociety::VotingArea::DIS,
            name => 'Our District Council'
        },
        1000004 => {
            type => mySociety::VotingArea::DIW,
            name => 'Chest Westerton Ward'
        },
        1000005 => {
            type => mySociety::VotingArea::WMP,
            name => 'House of Commons'
        },
        1000006 => {
            type => mySociety::VotingArea::WMC,
            name => 'Your and My Society'
        },
        1000007 => {
            type => mySociety::VotingArea::EUP,
            name => 'European Parliament'
        },
        1000008 => {
            type => mySociety::VotingArea::EUR,
            name => 'Windward Euro Region'
        }
    );

# Map area type to ID of "fictional" (i.e., not in DB) enclosing area.
my %enclosing_areas = (
        mySociety::VotingArea::LAC => mySociety::VotingArea::LAE_AREA_ID,
        mySociety::VotingArea::WMC => mySociety::VotingArea::WMP_AREA_ID,
        mySociety::VotingArea::EUR => mySociety::VotingArea::EUP_AREA_ID
    );

=item get_voting_areas POSTCODE

Return voting area IDs for POSTCODE.

=cut
sub get_voting_areas ($) {
    my ($pc) = @_;
    
    my $ret = undef;
    
    $pc =~ s/\s+//g;
    $pc = uc($pc);

    # Dummy postcode case
    if ($pc eq 'ZZ99ZZ') {
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
                ( map { $mySociety::VotingArea::type_to_id{$_->[0]} => $_->[1] } @{
                        dbh()->selectall_arrayref('select type, id from postcode_area, area where postcode_area.area_id = area.id and postcode_area.postcode_id = ?', {}, $pcid)
                    })
            };
    }

    # Add fictional enclosing areas.
    foreach my $ty (keys %enclosing_areas) {
        if (exists($ret->{$ty})) {
            my $encl = $enclosing_areas{$ty};
            $ret->{$special_cases{$encl}->{type}} = $enclosing_areas{$ty};
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
        throw RABX::Error("Voting area not found id $id", mySociety::MaPit::AREA_NOT_FOUND) unless (($type, $name, $parent_area_id) = dbh()->selectrow_array('select type, name, parent_area_id from area where id = ?', {}, $id));
     
        $ret = {
                name => $name,
                parent_area_id => $parent_area_id,
                type => $mySociety::VotingArea::type_to_id{$type}
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
    my $row = dbh()->selectcol_arrayref('select id from area where parent_area_id = ?', {}, $id);
    return $row;
}

=item admin_get_stats

=cut
sub admin_get_stats ($) {
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
