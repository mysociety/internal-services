#!/usr/bin/perl
#
# BoundaryLine.pm:
# Functions relating to BoundaryLine import
#
# Copyright (c) 2006 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: BoundaryLine.pm,v 1.8 2007-08-23 22:58:51 matthew Exp $
#

use strict;
package BoundaryLine;

use File::stat;
use Data::Dumper;
use mySociety::Polygon;
use Geo::OSBoundaryLine;
use Area;

use vars qw(@ISA @EXPORT_OK %interesting_areas @interesting_areas %childmap %parentmap);
@ISA = qw(Exporter);
@EXPORT_OK = qw(
    doublesize
    %interesting_areas
    @interesting_areas
    %childmap
    %parentmap
    load_ntf_file
);

# Record the size of a double for use later.
my $doublesize = length(pack('d', 0));
sub doublesize { return $doublesize; }

%interesting_areas = map { $_ => 1 } (
    @interesting_areas = (
#
# Types of areas about which we care:
#
# AREA_CODE What
# --------- --------------------------------------------
 'LBO',   # London Borough
 'LBW',   # London Borough Ward

 'GLA',   # GLA
 'LAC',   # GLA Constituency

 'CTY',   # County
 'CED',   # County Electoral Division

 'DIS',   # District
 'DIW',   # District Ward

 'UTA',   # Unitary Authority
 'UTE',   # Unitary Authority Electoral Division
 'UTW',   # Unitary Authority Ward

 'MTD',   # Metropolitan District
 'MTW',   # Metropolitan District Ward

 'SPE',   # Scottish Parliament Electoral Region
 'SPC',   # Scottish Parliament Constituency

 'WAE',   # Welsh Assembly Electoral Region
 'WAC',   # Welsh Assembly Constituency

 'WMC',   # Westminster Constituency

 'EUR',   # European Region

# 'CPC'    # Civil Parish
    )
);

# Areas for which we compute parentage, and their parent types.
%parentmap = qw(
        CED CTY
        DIW DIS
        LBW LBO
        MTW MTD
        UTW UTA
        UTE UTA
    );
# Can't list CPC (parish) here, because a CPC may have either a DIS or UTA
# parent.

# But put CPC in here so that we can pick up parents of CPCs at load time.
#$childmap{DIS}->{CPC} = 1;
#$childmap{UTA}->{CPC} = 1;

foreach (keys %parentmap) {
    $childmap{$parentmap{$_}}->{$_} = 1;
}

sub load_ntf_file {
    my ($filename, $shapes, $onscode_to_shape, $area_type_to_shape, $aaid_to_shape) = @_;

    printf STDERR "\r%s (%.2fMB) ", $filename, stat($filename)->size() / (1024.*1024);
    my $ntf = new Geo::OSBoundaryLine::NTFFile($filename);
    print STDERR "loaded.\n";

    # Within each file, cache a list of collection ID to area object. We
    # use this to determine area parents at load time.
    my %collectid_to_area;
    my %collectid_to_parent_collectid;

    # Each administrative area will be represented by at least one
    # collection-of-features. So we go through all the collections and
    # collect all the associated shapes for processing. But collections
    # also contain child areas (e.g. a DIS collection will contain all
    # the DIW collections for its contained wards), so we don't recurse
    # down.
    foreach my $collectid (keys %{$ntf->{collections}}) {
        my $C = $ntf->{collections}->{$collectid};
        my ($area_type, $ons_code, $aaid, $name, $non_inland_area) = map { $C->attributes()->{$_} } qw(area_type ons_code admin_area_id name non_inland_area);

        next unless (defined($area_type) && exists($interesting_areas{$area_type}));

        # Detached subparts of administrative areas are named with a
        # suffix "(DET NO n)". Remove it.
        $name =~ s#\(DET( NO \d+|)\)\s*##gi;
        # Says which districts are boroughs, like we care
        $name =~ s#\(B\)$##;
        $name =~ s#\s+$##;

        # Bounding rectangle of this shape.
        my ($minx, $miny, $maxx, $maxy) = (1e8, 1e8, -1e8, -1e8);

        # List of [sense, packed polygon data].
        my @parts = ( );

        # For each part, obtain a list of vertices and update the bounding
        # rectangle.
        my ($vx, $vy);
        foreach my $part ($C->flatten(1)) {
            my ($poly, $sense) = @$part;
            my @verts = $poly->vertices();

            # save a vertex coordinate
            ($vx, $vy) = @{$verts[0]} unless (defined($vx));
            foreach (@verts) {
                my ($x, $y) = @$_;
                $minx = $x if ($x < $minx);
                $maxx = $x if ($x > $maxx);
                $miny = $y if ($y < $miny);
                $maxy = $y if ($y > $maxy);
            }

            my $polydata = pack('d*', map { @$_ } @verts);
            push(@parts, [$sense, $polydata]);
            @verts = ( );
        }
        my $hectares = $C->flatten_area(1);

        # Determine whether this is a new shape or a new part of a previous
        # shape.
        my $row;
        if (defined($ons_code) && exists($onscode_to_shape->{$ons_code})) {
            $row = $onscode_to_shape->{$ons_code};
            if ($name ne $row->name()) {
                print STDERR "\rONS code $ons_code is used for '", $row->name(), "' and for '$name'\n";
                undef $row;
            } else {
                print STDERR "\rsecond shape for ONS code $ons_code; combining\n";
            }
        }

        if (!defined($row) && exists($aaid_to_shape->{$area_type . $aaid})) {
            $row = $aaid_to_shape->{$area_type . $aaid};
            if ($name ne $row->name()) {
                print STDERR "\radmin area id $aaid is used for ${area_type}s '", $row->name(), "' and for '$name'\n";
                undef $row;
            } else {
                print STDERR "\rsecond shape for admin area id $aaid; combining\n";
            }
        }

        if (!defined($row)) {
            # New shape. Compute once-only values and save the thing.

            # We need to identify a single point inside the polygon. This
            # is used to find the areas which enclose this area in the case
            # where that cannot be computed by other means (e.g. ONS code).
            # XXX finding the centroid would be better!
            # XXX this is actually broken, since a point inside this
            # polygon might actually lie in a hole. In principle we should
            # move this to later, when all the parts for this shape have
            # been assembled.
            my ($cx, $cy);
            do {
                $cx = $vx + rand(20) - 10;
                $cy = $vy + rand(20) - 10;
            } while (!mySociety::Polygon::is_point_in_poly($cx, $cy, length($parts[0]->[1]) / (2 * $doublesize), $parts[0]->[1]));

            # Determine areas covered by devolved assemblies using
            # Euro-regions, which are coterminous with them.
            my $devolved;
            if ($area_type eq 'EUR') {
                $devolved = 'E';
                if ($name =~ /London/) {
                    $devolved = 'L';
                } elsif ($name =~ /Scotland/) {
                    $devolved = 'S';
                } elsif ($name =~ /Wales/) {
                    $devolved = 'W';
                }
            }

            $row = new Area(
                            filename => $filename,
                            area_type => $area_type,
                            ons_code => $ons_code,
                            devolved => $devolved,
                            aaid => $aaid,
                            name => $name,
                            parts => \@parts,
                            minx => $minx,
                            miny => $miny,
                            maxx => $maxx,
                            maxy => $maxy,
                            cx => $cx,
                            cy => $cy,
                            non_inland_area => $non_inland_area,
                            hectares => $hectares
                        );
            
            $onscode_to_shape->{$ons_code} = $row if (defined($ons_code));
            $aaid_to_shape->{$area_type . $aaid} = $row;
            push(@{$area_type_to_shape->{$area_type}}, $row);

            push(@$shapes, $row);
        } else {
            # Shape already exists. Form union of its parts and ours.
            push(@{$row->parts()}, @parts);
            $row->minx($minx) if ($minx < $row->minx());
            $row->maxx($maxx) if ($maxx > $row->maxx());
            $row->miny($miny) if ($miny < $row->miny());
            $row->maxy($maxy) if ($maxy > $row->maxy());
            $row->non_inland_area($row->non_inland_area() + $non_inland_area);
            $row->hectares($row->hectares() + $hectares);
        }

        $collectid_to_area{$C->id()} = $row;

        # If this is an area for which we maintain a parent/child mapping,
        # then go through each of its parts linking them up appropriately.
        if (exists($childmap{$area_type})) {
            foreach my $part ($C->parts()) {
                # Only consider child collections which are of the
                # appropriate type to be children of this area.
                next unless ($part->isa("Geo::OSBoundaryLine::CollectionOfFeatures")
                                && exists($childmap{$area_type}->{$part->attributes()->area_type()}));

                # Don't actually match up the parent and child rows here as
                # we may not have seen all the referenced IDs yet. Save a
                # link which we process later.
                die "#" . $part->id() . " already has a parent, #$collectid_to_parent_collectid{$part->id()}, not " . $C->id() . "\n"
                    if (exists($collectid_to_parent_collectid{$part->id()}) && $collectid_to_parent_collectid{$part->id()} ne $C->id());
                $collectid_to_parent_collectid{$part->id()} = $C->id();
            }
        }
    }

    # Now use the map of parent collection IDs to fix up the parent/child
    # mapping.
    #print STDERR "\n";
    foreach my $child (keys %collectid_to_parent_collectid) {
        my $parent = $collectid_to_parent_collectid{$child};
        die "child collection ID #$child does not exist but was referenced by another area" if (!exists($collectid_to_area{$child}));
        $collectid_to_area{$child}->parent($collectid_to_area{$parent});
        $collectid_to_area{$parent}->children($collectid_to_area{$child});
        #printf STDERR "%s lies inside %s\n", $collectid_to_area{$child}->name(), $collectid_to_area{$parent}->name();
    }

    undef $ntf;
}

1;
