#!/usr/bin/perl -w -I../perllib -I ../../perllib
#
# april2009-construct-new.pl:
# Create the boundaries of the new Unitary Authorities in Cheshire and Bedfordshire
#
# Copyright (c) 2009 UK Citizens Online Democracy. All rights reserved.
# Email: matthew@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: april2009-construct-new.pl,v 1.1 2009-04-02 17:34:44 matthew Exp $
#

use strict;

use DBI;
use DBD::Pg;
use Geo::OSBoundaryLine;
use mySociety::Polygon;

use Common;
use Area;
use BoundaryLine qw(doublesize);

die "argument is the District Council ShapeFile" unless @ARGV;
my $file = $ARGV[0];

# @shapes
# List of Area objects for each area we're interested in.
my @shapes;
my %onscode_to_shape;
my %area_type_to_shape;
# We may have several shapes in files with the same administrative area ID. We
# amalgamate them before writing them to the database.
my %aaid_to_shape;
BoundaryLine::load_shapefile($file, \@shapes, \%onscode_to_shape, \%area_type_to_shape, \%aaid_to_shape);

my $dbh = Common::connect_to_mapit_database();

my %districts = (
    21068 => [ 'Vale Royal District', 'Chester District', 'Ellesmere Port and Neston District' ], # Cheshire West + Chester
    21069 => [ 'Crewe and Nantwich District', 'Congleton District', 'Macclesfield District' ], # Cheshire East
    21070 => [ 'Mid Bedfordshire District', 'South Bedfordshire District' ], # Central Beds
);

for my $id (keys %districts) {
    print "Creating area $id\n";
    my $A = new Area(area_type => 'UTA', name => $id, country => 'E', minx => 10000000, maxx => 0, miny => 10000000, maxy => 0, alreadyexists => 1, parts => [ ]);
    my $names = $districts{$id};
    for my $council (@$names) {
        my $othershape;
        foreach (@{$area_type_to_shape{DIS}}) {
            if ($council eq $_->{name}) {
                $othershape = $_;
                last;
            }
        }
        die "No other shape for $council" unless $othershape;
        push(@{$A->parts()}, @{$othershape->parts()});
        $A->minx($othershape->minx()) if ($othershape->minx() < $A->minx());
        $A->miny($othershape->miny()) if ($othershape->miny() < $A->miny());
        $A->maxx($othershape->maxx()) if ($othershape->maxx() > $A->maxx());
        $A->maxy($othershape->maxy()) if ($othershape->maxy() > $A->maxy());
        $A->cx($othershape->cx()) if (!defined($A->cx()));
        $A->cy($othershape->cy()) if (!defined($A->cy()));
    }

    my $centre_e = ($A->minx() + $A->maxx()) / 2;
    my $centre_n = ($A->miny() + $A->maxy()) / 2;

    my $binary_poly; # format as documented in mapit-schema.sql
    my $parts_count = scalar(@{$A->parts()});
    my $calculated_surface_area;
    foreach (@{$A->parts()}) {
        my ($sense, $vv) = @$_;
        my $vertices_count = length($vv) / (2 * doublesize());
        print STDERR "  ... part $sense sense $vertices_count vertices\n";
        $binary_poly .= pack('i', $sense);
        $binary_poly .= pack('i', $vertices_count);
        $binary_poly .= $vv;
        
        # Calculate area from the polygon 
        my $surface_area = abs(mySociety::Polygon::poly_area($vertices_count, $vv));
        if ($sense > 0) {  
            $calculated_surface_area += $surface_area;
        } elsif ($sense < 0) {
            $calculated_surface_area -= $surface_area;
        } else {
            die "zero sense value for part in " . $A->name();
        }
    }
    die "Calculated surface zero or negative ($calculated_surface_area) for " . $A->name() if ($calculated_surface_area <= 0);

    print STDERR "\tDB identifier: " . $id . "\n";
    print STDERR "\tBounds: " . $A->minx() . "E " . $A->miny() . "N - " . $A->maxx() . "E " . $A->maxy() . "N\n";
    print STDERR "\tCentre: $centre_e E $centre_n N ";
    print STDERR "\tcalc area $calculated_surface_area m2, parts $parts_count\n";

    $dbh->do("delete from area_geometry where area_id = ?", {}, $id);

    $dbh->do("insert into area_geometry (
        area_id, centre_e, centre_n, min_e, min_n,
        max_e, max_n, area, parts
    ) values (
        ?, ?, ?, ?, ?,
        ?, ?, ?, ?
    ) ", {}, 
        $id, $centre_e, $centre_n, $A->minx(), $A->miny(),
        $A->maxx(), $A->maxy(), $calculated_surface_area, $parts_count
    );

    # Horrid. To insert a value into a BYTEA column we need to do a little
    # parameter-binding dance:
    my $s = $dbh->prepare(q#update area_geometry set polygon = ? where area_id = ?#);
    $s->bind_param(1, $binary_poly, { pg_type => DBD::Pg::PG_BYTEA });
    $s->bind_param(2, $id);
    $s->execute();
}

$dbh->commit();

