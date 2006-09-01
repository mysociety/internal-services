#!/usr/bin/perl
#
# MaPit.pm:
# Implementation of MaPit functions, to be called by RABX.
#
# Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: MaPit.pm,v 1.52 2006-09-01 11:43:41 francis Exp $
#

package MaPit;

use strict;

use DBI;
use DBD::Pg;

use Geography::NationalGrid;
use Geo::HelmertTransform;
use Data::Dumper;

use mySociety::Config;
use mySociety::DBHandle qw(dbh);
use mySociety::MaPit;
use mySociety::Util;
use mySociety::VotingArea;
use mySociety::GeoUtil;

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

=head1 CONSTANTS

=over 4

=item BAD_POSTCODE 2001

String is not in the correct format for a postcode.

=item POSTCODE_NOT_FOUND 2002

The postcode was not found in the database.

=item AREA_NOT_FOUND 2003

The area ID refers to a non-existent area.

=back


=head1 FUNCTIONS

=over 4

=cut

# Special cases to represent parliaments, assemblies themselves.
use constant DUMMY_ID => 1000000;
use constant DUMMY_ID_MAX => 1999999;
use constant DUMMY_ID_9ZZ_MIN => 1000000;
use constant DUMMY_ID_9ZZ_MAX => 1000099;
use constant DUMMY_ID_9ZY_MIN => 1000100; # AnimalAid
use constant DUMMY_ID_9ZY_MAX => 1000199;

my %special_cases = (
        # Enclosing areas.
        mySociety::VotingArea::WMP_AREA_ID => {
            type => 'WMP',
            name => 'House of Commons'
        },
        
        mySociety::VotingArea::HOL_AREA_ID => {
            type => 'HOL',
            name => 'House of Lords'
        },

        mySociety::VotingArea::HOC_AREA_ID => {
            type => 'HOC',
            name => 'United Kingdom', # Dummy constituency
            parent_area_id => mySociety::VotingArea::HOL_AREA_ID
        },

        mySociety::VotingArea::EUP_AREA_ID => {
            type => 'EUP',
            name => 'European Parliament'
        },

        mySociety::VotingArea::LAE_AREA_ID => {
            type => 'LAE',
            name => 'London Assembly', # Proportionally elected area
            parent_area_id => mySociety::VotingArea::LAS_AREA_ID
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

        # ZZ9 9ZZ test data
        1000001 => {
            type => 'CTY',
            name => "Everyone's County Council"
        },
        1000002 => {
            type => 'CED',
            name => 'Chest Westerton ED',
            parent_area_id => 1000001
        },
        1000003 => {
            type => 'DIS',
            name => 'Our District Council'
        },
        1000004 => {
            type => 'DIW',
            name => 'Chest Westerton Ward',
            parent_area_id => 1000003
        },
        1000005 => {
            type => 'WMP',
            name => 'House of Commons'
        },
        1000006 => {
            type => 'WMC',
            name => 'mySociety Test Constituency'
        },
        1000007 => {
            type => 'EUP',
            name => 'European Parliament'
        },
        1000008 => {
            type => 'EUR',
            name => 'Windward Euro Region'
        },
        # ZZ9 9ZY test data
        1000100 => {
            type => 'WMC',
            name => 'AnimalAid Test Constituency'
        },
   );

# Map area type to ID of "fictional" (i.e., not in DB) enclosing area.
my %enclosing_areas = (
        'LAC' => [mySociety::VotingArea::LAE_AREA_ID, mySociety::VotingArea::LAS_AREA_ID],
        'SPC' => [mySociety::VotingArea::SPA_AREA_ID],
        'WAC' => [mySociety::VotingArea::WAS_AREA_ID],
        'NIE' => [mySociety::VotingArea::NIA_AREA_ID],
        'WMC' => [mySociety::VotingArea::WMP_AREA_ID],
        'EUR' => [mySociety::VotingArea::EUP_AREA_ID],
        'HOL' => [mySociety::VotingArea::HOL_AREA_ID],
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

    if ($pc =~ m/^ZZ9/) {
        # Dummy postcode cases
        my $min = DUMMY_ID;
        my $max = DUMMY_ID_MAX;
        if ($pc eq 'ZZ99ZZ') {
            $min = DUMMY_ID_9ZZ_MIN;
            $max = DUMMY_ID_9ZZ_MAX
        } elsif ($pc eq 'ZZ99ZY') {
            $min = DUMMY_ID_9ZY_MIN;
            $max = DUMMY_ID_9ZY_MAX
        }
        $ret = {
                map { $special_cases{$_}->{type} => $_ } grep { $_ >= $min && $_ <= $max } keys(%special_cases)
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

=item get_voting_area_info AREA

Return information about the given voting area. Return value is a reference to
a hash containing elements,

=over 4

=item type

OS-style 3-letter type code, e.g. "CED" for county electoral division;

=item name

name of voting area;

=item parent_area_id

(if present) the ID of the enclosing area.

=item area_id

the ID of the area itself

=item generation_low, generation_high, generation

the range of generations of the area database for which this area is to 
be used and the current active generation.

=back

=cut
sub get_voting_area_info ($) {
    my ($id) = @_;

    throw RABX::Error("ID must be defined", RABX::Error::INTERFACE)
        if (!defined($id));

    my $generation = get_generation();

    my $ret;
    if (exists($special_cases{$id})) {
        $ret = $special_cases{$id};
        $ret->{'area_id'} = $id;
        $ret->{'parent_area_id'} = undef if (!defined($ret->{'parent_area_id'}));
        $ret->{'generation_low'} = 0 if (!defined($ret->{'generation_low'}));
        $ret->{'generation_high'} = $generation if (!defined($ret->{'generation_high'}));
        $ret->{'generation'} = $generation;
    } else {
        # Real data
        my ($type, $name, $os_name, $parent_area_id, $generation_low, $generation_high);
        throw RABX::Error("Voting area not found id $id", mySociety::MaPit::AREA_NOT_FOUND)
            unless (($type, $name, $os_name, $parent_area_id, $generation_low, $generation_high) = dbh()->selectrow_array("
            select type, a1.name as name, a2.name as os_name, parent_area_id,
                   generation_low, generation_high
                from area
                left join area_name as a1 on a1.area_id = area.id and a1.name_type = 'F'
                left join area_name as a2 on a2.area_id = area.id and a2.name_type = 'O'
                where id = ?
            ", {}, $id));
     
        $ret = {
                name => $name,
                os_name => $os_name,
                parent_area_id => $parent_area_id,
                type => $type,
                area_id => $id,
                generation_low => $generation_low,
                generation_high => $generation_high,
                generation => $generation
            };
    }

    # Annotate with information about the representative type returned for that
    # area.
    foreach (qw(type_name attend_prep general_prep rep_name rep_name_plural
                rep_name_long rep_name_long_plural rep_suffix rep_prefix)) {
        no strict 'refs';
        $ret->{$_} = ${"mySociety::VotingArea::$_"}{$ret->{type}};
    }
    return $ret;
}

=item get_voting_areas_info ARY

As get_voting_area_info, only takes an array of ids, and returns an array of hashes.

=cut
sub get_voting_areas_info ($) {
    my ($ary) = @_;
    return { (map { $_ => get_voting_area_info($_) } grep { defined($_) } @$ary) };
}

=item get_voting_area_geometry AREA [POLYGON_TYPE]

Return geometry information about the given voting area. Return value is a
reference to a hash containing elements. Coordinates with names ending _e and
_n are UK National Grid eastings and northings. Coordinates ending _lat and
_lon are WGS84 latitude and longitude.

centre_e, centre_n, centre_lat, centre_lon - centre of bounding rectangle
min_e, min_n, min_lat, min_lon - south-west corner of bounding rectangle
max_e, max_n, max_lat, max_lon - north-east corner of bounding rectangle
area - approximate surface area of the constituency, in metres squared
(this is taken from the OS data, but roughly agrees with the polygon's area)
parts - number of parts the polygon of the boundary has

If POLYGON_TYPE is present, then the hash also contains a member 'polygon'.
This is an array of parts. Each part is a hash of the following values:

sense - a positive value to include the part, negative to exclude (a hole)
points - an array of pairs of (eastings, northings) if POLYGON_TYPE is 'ng",
or (latitude, longitude) if POLYGON_TYPE is 'wgs84'.

If for some reason any of the values above are not known, they will not
be present in the array. For example, we currently only have data
for Westminster constituencies in Great Britain. Northern Ireland has
a separate Ordnance Survey, from whom we do not have the data. So
for Northern Ireland constituencies an empty hash will be returned.

=cut
sub get_voting_area_geometry ($;$) {
    my ($id, $polygon_type) = @_;

    throw RABX::Error("ID must be defined", RABX::Error::INTERFACE) if (!defined($id));
    throw RABX::Error("POLYGON_TYPE must be 'ng' or 'wgs84'", RABX::Error::INTERFACE) if (defined($polygon_type) &&
        $polygon_type ne 'ng' && $polygon_type ne 'wgs84');

    my $generation = get_generation();

    if (exists($special_cases{$id})) {
        throw RABX::Error("Special case areas not yet covered for get_voting_area_geometry", mySociety::MaPit::AREA_NOT_FOUND)
    } else {
        # Real data
        throw RABX::Error("Voting area not found at all id $id", mySociety::MaPit::AREA_NOT_FOUND)
            unless (dbh()->selectrow_array("select id from area where id = ?", {}, $id));

        my ($centre_e, $centre_n, $min_e, $min_n, $max_e, $max_n, $area, $parts);
        return {} unless (($centre_e, $centre_n, $min_e, $min_n, $max_e, $max_n, $area, $parts) = dbh()->selectrow_array("
            select centre_e, centre_n, min_e, min_n, max_e, max_n, area, parts
                from area_geometry
                where area_id = ?
            ", {}, $id));

        my ($centre_lat, $centre_lon) = mySociety::GeoUtil::national_grid_to_wgs84($centre_e, $centre_n, 'G');
        my ($min_lat, $min_lon) = mySociety::GeoUtil::national_grid_to_wgs84($min_e, $min_n, 'G');
        my ($max_lat, $max_lon) = mySociety::GeoUtil::national_grid_to_wgs84($max_e, $max_n, 'G');
     
        my $ret = {
                centre_e => $centre_e, centre_n => $centre_n,
                min_e => $min_e, min_n => $min_n,
                max_e => $max_e, max_n => $max_n,
                centre_lat => $centre_lat, centre_lon => $centre_lon,
                min_lat => $min_lat, min_lon => $min_lon,
                max_lat => $max_lat, max_lon => $max_lon,
                area => $area, parts => $parts
            };

        if ($polygon_type) {
            my $doublesize = length(pack('d', 0));
            my $intsize = length(pack('i', 0));

            my @part_array;
            my $polygon_array = [];
            my $polygon;
            throw RABX::Error("Voting area geometry info not found id $id", mySociety::MaPit::AREA_NOT_FOUND)
                unless (($polygon) = dbh()->selectrow_array("
                select polygon from area_geometry where area_id = ?", {}, $id));
            while (length($polygon)) {
                my $part;
                my $sense = unpack('i', substr($polygon, 0, $intsize));
                my $vertex_count = unpack('i', substr($polygon, $intsize, $intsize));
                my @vertices = unpack('d*', substr($polygon, 2*$intsize, $vertex_count * $doublesize * 2));
                die "internal vertex count mismatch: ".($vertex_count * 2)." vs ".scalar(@vertices)
                    if $vertex_count * 2 != scalar(@vertices);
                $polygon = substr($polygon, 2*$intsize + $vertex_count * $doublesize * 2);

                $part->{sense} = $sense;
                $part->{points} = [];
                for (my $i = 0; $i < @vertices; $i += 2) {
                    if ($polygon_type eq 'ng') {
                        push @{$part->{points}}, [$vertices[$i], $vertices[$i+1]];
                    } else {
                        my ($lat, $lon) = mySociety::GeoUtil::national_grid_to_wgs84($vertices[$i], $vertices[$i+1], 'G');
                        push @{$part->{points}}, [$lat, $lon];
                    }
                }
                push @$polygon_array, $part;
            }
            $ret->{'polygon'} = $polygon_array;
        }
        return $ret;
    }

    throw RABX::Error("Flow of execution should never get here");
}

=item get_voting_areas_geometry ARY

As get_voting_area_geometry, only takes an array of ids, and returns an array of hashes.

=cut
sub get_voting_areas_geometry ($;$) {
    my ($ary) = @_;
    return { (map { $_ => get_voting_area_geometry($_) } grep { defined($_) } @$ary) };
}


=item get_areas_by_type TYPE [ALL]

Returns an array of ids of all the voting areas of type TYPE.
TYPE is the three letter code such as WMC. By default only
gets active areas in current generation, if ALL is true then
gets all areas for all generations.

=cut
sub get_areas_by_type ($;$) {
    my ($type, $all) = @_;

    throw RABX::Error("Please specify type") unless $type;
    throw RABX::Error("Type must be three capital letters") unless $type =~ m/^[A-Z][A-Z][A-Z]$/;
    throw RABX::Error("Type unknown") unless defined($mySociety::VotingArea::known_types{$type});

    if ($type eq 'HOC') {
        return [ mySociety::VotingArea::HOC_AREA_ID ];
    }

    my $generation = get_generation();
    my $ret;
    
    if ($all) {
        $ret = dbh()->selectcol_arrayref('
            select id from area where type = ?
            ', {}, $type);
    } else {
        $ret = dbh()->selectcol_arrayref('
            select id from area 
                where generation_low <= ? and ? <= generation_high
                and type = ?
            ', {}, $generation, $generation, $type);
    }

    return $ret;
}

=item get_example_postcode ID

Given an area ID, returns one postcode that maps to it.

=cut
sub get_example_postcode ($);
sub get_example_postcode ($) {
    my ($area_id) = @_;
        # XXX this will break with the new Scottish constituencies stuff
    # Have to catch special cases here.
    if (exists($special_cases{$area_id})) {
        if ($area_id >= DUMMY_ID_9ZZ_MIN && $area_id <= DUMMY_ID_9ZZ_MAX) {
            return "ZZ9 9ZZ";
        } elsif ($area_id >= DUMMY_ID_9ZY_MIN && $area_id <= DUMMY_ID_9ZY_MAX) {
            return "ZZ9 9ZY";
        } else {
            # These aren't in the database. First try finding a child area:
            my $child = (grep { !exists($special_cases{$_}) || $area_id >= DUMMY_ID } @{get_voting_area_children($area_id)})[0];
            if (defined($child)) {
                # Get a postcode in the child.
                return get_example_postcode($child);
            } else {
                # Area has no children. That means it must be LAE.
                warn "area $area_id has no children...\n";
                return get_example_postcode(mySociety::VotingArea::LAS_AREA_ID);
            }
        }
    }
    
    my $pc = scalar(dbh()->selectrow_array("select postcode from postcode, postcode_area
        where postcode.id = postcode_area.postcode_id and area_id = ?
        limit 1", {}, $area_id));

    if (!defined($pc)
        && scalar(dbh()->selectrow_array('select type from area where id = ?',
                    {}, $area_id)) eq 'WMC') {
        # This could be because it's a new Scottish constituency.
        my ($council_area_id, $ward_area_id) = dbh()->selectrow_array('select council_area_id, ward_area_id from new_scottish_constituencies_fixup where constituency_area_id = ?', {}, $area_id);
        if (defined($council_area_id)) {
            return get_example_postcode($council_area_id);
        } elsif (defined($ward_area_id)) {
            return get_example_postcode($ward_area_id);
        } else {
            throw RABX::Error("Voting area not found id $area_id");
        }
    }

    return $pc;
}

=item get_voting_area_children ID

Return array of ids of areas whose parent areas are ID.

=cut
sub get_voting_area_children ($) {
    my ($id) = @_;
    # This is horrid, because some parent_area_ids are fixed up in MaPit, not
    # the database.
    my $type = get_voting_area_info($id)->{type};
    if ($type eq 'LAS') {
        return [@{dbh()->selectcol_arrayref("select id from area where type = 'LAC'")}, mySociety::VotingArea::LAS_AREA_ID];
    } else {
        return dbh()->selectcol_arrayref('select id from area where parent_area_id = ?', {}, $id);
    }
}

=item get_location POSTCODE [PARTIAL]

Return the location of the given POSTCODE. The return value is a reference to
a hash containing elements.  If PARTIAL is present set to 1, will use only
the first part of the postcode, and generate the mean coordinate.  If PARTIAL
is set POSTCODE can optionally be just the first part of the postcode.

=over 4

=item coordsyst

=item easting

=item northing

Coordinates of the point in a UTM coordinate system. The coordinate system is
identified by the coordsyst element, which is "G" for OSGB (the Ordnance Survey
"National Grid" for Great Britain) or "I" for the Irish Grid (used in the
island of Ireland).

=item wgs84_lat

=item wgs84_lon

Latitude and longitude in the WGS84 coordinate system, expressed as decimal
degrees, north- and east-positive.

=back

=cut
sub get_location ($;$) {
    my ($pc, $partial) = @_;
    
    my $ret = undef;

    $pc =~ s/\s+//g;
    $pc = uc($pc);

    my %result = (
            coordsyst => 'G',
            # default data
            easting => 0,
            northing => 0
        );

    if ($pc !~ m/^ZZ9/) {
        # Real data
        if ($partial) {
            if (mySociety::Util::is_valid_postcode($pc)) {
                $pc =~ s/\d[A-Z]{2}$//g;
            }
            throw RABX::Error("Partial postcode '$pc' is not valid.", mySociety::MaPit::BAD_POSTCODE) unless (mySociety::Util::is_valid_partial_postcode($pc));
            my ($min_c, $max_c, $E, $N) = dbh()->selectrow_array("select min(coordsyst), max(coordsyst), avg(easting), avg(northing) from postcode where postcode like ? || '%'", {}, $pc);
            if ($E && $N) {
                throw RABX::Error("Multiple coordinate systems for one partial postcode '$pc'.", mySociety::MaPit::POSTCODE_NOT_FOUND) if ($min_c ne $max_c);
                $result{coordsyst} = $min_c;
                $result{easting} = $E;
                $result{northing} = $N;
            } else {
                throw RABX::Error("Partial postcode '$pc' not found.", mySociety::MaPit::POSTCODE_NOT_FOUND);
            }
        } else {
            throw RABX::Error("Postcode '$pc' is not valid.", mySociety::MaPit::BAD_POSTCODE) unless (mySociety::Util::is_valid_postcode($pc));
            if (my ($coordsyst, $E, $N) = dbh()->selectrow_array('select coordsyst, easting, northing from postcode where postcode = ?', {}, $pc)) {
                $result{coordsyst} = $coordsyst;
                $result{easting} = $E;
                $result{northing} = $N;
            } else {
                throw RABX::Error("Postcode '$pc' not found.", mySociety::MaPit::POSTCODE_NOT_FOUND);
            }
        }
    }

    my ($lat, $lon) = mySociety::GeoUtil::national_grid_to_wgs84($result{easting}, $result{northing}, $result{coordsyst});
    $result{wgs84_lat} = $lat;
    $result{wgs84_lon} = $lon;

    return \%result;
}

=item admin_get_stats

Returns a hash of statistics about the database. (Bit slow as count of postcodes is
very slow).

=cut
sub admin_get_stats () {
    () = @_;
    my %ret;

    $ret{'postcode_count'} = scalar(dbh()->selectrow_array('select count(*) from postcode', {}));
    $ret{'area_count'} = scalar(dbh()->selectrow_array('select count(*) from area', {}));

    my $rows = dbh()->selectall_arrayref('select type, count(*) from area group by type', {});
    foreach (@$rows) {
        my ($type, $count) = @$_; 
        $ret{'area_count_'. $type} = $count;
    }

    return \%ret;
}

1;
