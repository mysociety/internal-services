#!/usr/bin/perl
#
# OSBoundaryLine.pm:
# Parse Ordnance Survey Boundary-Line data from its original NTF format.
#
# Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: OSBoundaryLine.pm,v 1.14 2006-08-23 11:47:35 francis Exp $
#

package Geo::OSBoundaryLine::Error;

@Geo::OSBoundaryLine::Error::ISA = qw(Error::Simple);

package Geo::OSBoundaryLine::Attribute;

=head1 NAME

Geo::OSBoundaryLine::Attribute

=head1 DESCRIPTION

Object representing attributes of administrative and voting areas in
Boundary-Line. These objects are constructed during the parsing process and
should be regarded as read-only by callers.

=head1 METHODS

=over 4

=item admin_area_id

Administrative area ID.

=item ons_code

ONS (Office of National Statistics) code for the area, or undef if none is
specified.

=item area_type

Type of area (e.g. 'WMC', 'CED', etc.).

=item name

Name of area.

=item non_inland_area

Non inland surface area in hectares.

=item non_type_codes

Any other type codes applicable to the area.

=back

=head1 DATA

=over 4

=item %area_types

Hash of area type to [type name, type of area code]. Type of area codes are
'AA', for administrative areas (e.g. counties); 'VA', for voting areas (e.g.
Westminster constituencies); and 'FA' for other areas (e.g. non-civil
parishes).

=back

=cut

my $debug = 0;

%Geo::OSBoundaryLine::Attribute::area_types = (
        CED => ['County electoral division', 'VA'],
        CPC => ['Civil parish or community', 'AA'],
        CTY => ['County', 'AA'],
        DIS => ['District', 'AA'],
        DIW => ['District ward', 'VA'],
        EUR => ['European region', 'VA'],
        GLA => ['Greater London Authority', 'AA'],
        LAC => ['Greater London Authority Assembly constituency', 'VA'],
        LBO => ['London borough', 'AA'],
        LBW => ['London borough ward', 'VA'],
        MTC => ['Scotland Metropolitan county', 'AA'],
        MTD => ['Description AC TY Metropolitan district', 'AA'],
        MTW => ['Metropolitan district ward', 'VA'],
        NCP => ['Non-civil parish or community', 'FA'],
        SPC => ['Scottish Parliament constituency', 'VA'],
        SPE => ['Scottish Parliament electoral region', 'AA'],
        UTA => ['Unitary authority', 'AA'],
        UTE => ['Unitary authority electoral division', 'VA'],
        UTW => ['Unitary authority ward', 'VA'],
        WAC => ['Welsh Assembly constituency', 'VA'],
        WAE => ['Welsh Assembly electoral region', 'AA'],
        WMC => ['Westminster constituency', 'VA']
    );

use fields qw(id admin_area_id ons_code area_type non_inland_area name non_type_codes type);

my %checks = (
        id => qr/^\d+$/,
        admin_area_id => qr/^\d+$/,
        non_inland_area => qr/^[\.\d]+$/,
        ons_code => sub { return !defined($_[0]) || $_[0] =~ /^[0-9A-Z]+$/ },
        area_type => sub { return defined($_[0]) && exists($area_types{$_[0]}) },
        name => qr/.*/,   # can be blank?
        non_type_codes => sub { return !defined($_[0]) || (ref($_[0]) eq 'ARRAY' && 0 == grep { !exists($area_types{$_}) } @{$_[0]}); },
        type => qr/^[AFTV]A$/
    );

sub new ($%) {
    my ($class, %a) = @_;
    my $self = fields::new($class);
    foreach (keys %a) {
        my $v = $a{$_};
        next unless (defined($v));
        $v =~ s# +$##;
        next if ($v eq '');
        if (!exists($checks{$_})) {
            die "unknown field '$_' in constructor for Geo::OSBoundaryLine::Attribute";
        } elsif ((ref($checks{$_}) eq 'Regexp' && $v !~ $checks{$_})
                 || (ref($checks{$_}) eq 'CODE' && !&{$checks{$_}}($v))) {
            throw Geo::OSBoundaryLine::Error("Bad value '$a{$_}' ['$v'] for field '$_' in constructor for Geo::OSBoundaryLine::Attribute");
        } else {
            $self->{$_} = $v;
        }
    }
    return $self;
}

# accessor methods
foreach (keys %checks) {
    eval 'sub ' . $_ . ' ($) { my $self = shift; return $self->{' . $_ . '} }';
}

package Geo::OSBoundaryLine::PolyAttribute;

=head1 NAME

Geo::OSBoundaryLine::PolyAttribute

=head1 DESCRIPTION

Object representing attributes of polygons in Boundary-Line. These objects are
constructed during the parsing process and should be regarded as read-only by
callers.

=head1 METHODS

=over 4

=item hectares

Area in hectares.

=back

=cut

use fields qw(id hectares);

my %poly_checks = (
        id => qr/^\d+$/,
        hectares => qr/^[\.\d]+$/,
    );

sub new ($%) {
    my ($class, %a) = @_;
    my $self = fields::new($class);
    foreach (keys %a) {
        my $v = $a{$_};
        next unless (defined($v));
        $v =~ s# +$##;
        next if ($v eq '');
        if (!exists($poly_checks{$_})) {
            die "unknown field '$_' in constructor for Geo::OSBoundaryLine::PolyAttribute";
        } elsif ((ref($poly_checks{$_}) eq 'Regexp' && $v !~ $poly_checks{$_})
                 || (ref($poly_checks{$_}) eq 'CODE' && !&{$poly_checks{$_}}($v))) {
            throw Geo::OSBoundaryLine::Error("Bad value '$a{$_}' ['$v'] for field '$_' in constructor for Geo::OSBoundaryLine::PolyAttribute");
        } else {
            $self->{$_} = $v;
        }
    }
    return $self;
}

# accessor methods
foreach (keys %poly_checks) {
    eval 'sub ' . $_ . ' ($) { my $self = shift; return $self->{' . $_ . '} }';
}

package Geo::OSBoundaryLine::Polygon;

=head1 NAME

Geo::OSBoundaryLine::Polygon

=head1 DESCRIPTION

Object representing a single polygon in Boundary-Line. Each such polygon is
nonselfintersecting and holefree.

=head1 METHODS

=over 4

=cut

use Scalar::Util qw(weaken);

use fields qw(ntf id attrid);

sub new ($$$$) {
    my ($class, $ntf, $id, $attrid) = @_;
    my $self = fields::new($class);
    # Weaken the reference back to the parent object so that GC doesn't fail
    # on the circular reference.
    $self->{ntf} = $ntf;
    weaken($self->{ntf});
    $self->{id} = $id;
    $self->{attrid} = $attrid;
    return bless($self, $class);
}

=item vertices

In scalar context, return the number of vertices the polygon has. In list
context, return a list of the vertex coordinates as [x, y] pairs.

=cut
sub vertices ($) {
    my $self = shift;
    my $n = wantarray() ? undef : 0;
    my @verts = ( );
    my $ntf = $self->{ntf};
    foreach (@{$ntf->{chains}->{$self->{id}}}) {
        my ($geom_id, $dir) = @$_;
        if (defined($n)) {
            $n += @{$ntf->{geometries}->{$geom_id}};
        } else {
            if ($dir == 1) {
                push(@verts, @{$ntf->{geometries}->{$geom_id}});
            } else {
                push(@verts, reverse(@{$ntf->{geometries}->{$geom_id}}));
            }
        }
    }
    return wantarray() ? @verts : $n;
}

package Geo::OSBoundaryLine::ComplexPolygon;

=back

=head1 NAME

Geo::OSBoundaryLine::ComplexPolygon

=head1 DESCRIPTION

Object representing a single complex polygon in Boundary-Line. A complex
polygon is represented by one or more simple polygon objects, each with an
associated sense, which is positive for an included area, and negative for a
hole.

=head1 METHODS

=over 4

=cut

use Scalar::Util qw(weaken);

use fields qw(ntf id parts attrid);

sub new ($$$$$) {
    my ($class, $ntf, $id, $parts, $attrid) = @_;
    my $self = fields::new($class);
    $self->{ntf} = $ntf;
    weaken($self->{ntf});
    $self->{id} = $id;
    $self->{parts} = $parts;
    $self->{attrid} = $attrid;
    return bless($self, $class);
}

=item parts

In scalar context, return the number of parts this complex polygon has. In
list context, return a list of the parts and their sense (positive meaning
"included", negative meaning "excluded").

=cut
sub parts ($) {
    my $self = shift;
    return @{$self->{parts}};
}

=item part INDEX

Return in list context the polygonal part identified by the given INDEX
(starting at zero) and its sense (positive or negative).

=cut
sub part ($$) {
    my ($self, $i) = @_;
    my $ntf = $self->{ntf};
    die "index '$i' out of range for complex polygon #$self->{id}"
        if ($i >= @{$self->{parts}} || $i < 0);
    return $ntf->{complexes}->{$self->{id}}->[$i];
}

package Geo::OSBoundaryLine::CollectionOfFeatures;

=back

=head1 NAME

Geo::OSBoundaryLine::CollectionOfFeatures

=head1 DESCRIPTION

Object representing a collection of other objects in Boundary-Line, with
associated attributes.

=head1 METHODS

=over 4

=cut

use Scalar::Util qw(weaken);
use UNIVERSAL;

use fields qw(ntf id attrid parts);

sub new ($$$$$) {
    my ($class, $ntf, $id, $attrid, $parts) = @_;
    my $self = fields::new($class);
    $self->{ntf} = $ntf;
    weaken($self->{ntf});
    $self->{id} = $id;
    $self->{attrid} = $attrid;
    $self->{parts} = $parts;
    return bless($self, $class);
}

=item id

Return the collection id.

=cut
sub id ($) {
    my $self = shift;
    return $self->{id};
}

=item parts

In scalar context, return the number of parts this collection has. In list
context, return a list of the parts. Note that a part may itself by a
collection.

=cut
sub parts ($) {
    my $self = shift;
    return @{$self->{parts}};
}

=item part INDEX

Return in list context the polygonal part identified by the given INDEX
(starting at zero).

=cut
sub part ($$) {
    my ($self, $i) = @_;
    die "index '$i' out of range for collection #$self->{id}"
        if ($i >= @{$ntf->{collections}->{$self->{id}}} || $i < 0);
    return $ntf->{collections}->{$self->{id}}->[$i];
}

=item flatten [NORECURSE]

Return a flattened representation of the collection; that is, a list of
[polygon, sense] obtained recursively. If NORECURSE is true, then do not
recurse into enclosed collections-of-features.

=cut
sub flatten ($;$$);
sub flatten ($;$$) {
    my ($self, $norecurse, $cofids_seen) = @_;
    my @parts = ( );
    $cofids_seen ||= { };
    $cofids_seen->{$self->{id}} = 1;
    foreach my $p ($self->parts()) {
        if ($p->isa("Geo::OSBoundaryLine::CollectionOfFeatures")) {
            next if ($norecurse);
            die "collection #$self->{id} is part of a referential cycle of collections"
                if (exists($cofids_seen->{$p->{id}}));
            push(@parts, $p->flatten($norecurse, $cofids_seen));
        } elsif ($p->isa("Geo::OSBoundaryLine::ComplexPolygon")) {
            push(@parts, $p->parts());
        } elsif ($p->isa("Geo::OSBoundaryLine::Polygon")) {
            push(@parts, [$p, +1]);
        } else {
            die "bad object of type " . ref($p) . " in collection #$self->{id}";
        }
    }
    return @parts;
}

=item flatten_area [NORECURSE]

Return the surface area in hectares of the polygons in the collection.  If
NORECURSE is true, then do not recurse into enclosed collections-of-features.

=cut
sub flatten_area ($;$$);
sub flatten_area ($;$$) {
    my ($self, $norecurse, $ids_seen) = @_;
    my $hectares = 0.0;
    $ids_seen ||= { };
    $ids_seen->{$self->{id}} = 1;
    foreach my $p ($self->parts()) {
        if ($p->isa("Geo::OSBoundaryLine::CollectionOfFeatures")) {
            next if ($norecurse);
            die "collection #$self->{id} is part of a referential cycle of collections"
                if (exists($ids_seen->{$p->{id}}));
            #warn "recursive flatten";
            $hectares += $p->flatten_area($norecurse, $ids_seen);
        } elsif ($p->isa("Geo::OSBoundaryLine::ComplexPolygon")) {
            #warn "adding complex poly " .  $self->{ntf}->{attributes}->{$p->{attrid}}->hectares();
            $hectares += $self->{ntf}->{attributes}->{$p->{attrid}}->hectares();
        } elsif ($p->isa("Geo::OSBoundaryLine::Polygon")) {
            #warn "adding simple poly " .  $self->{ntf}->{attributes}->{$p->{attrid}}->hectares();
            $hectares += $self->{ntf}->{attributes}->{$p->{attrid}}->hectares();
        } else {
            die "bad object of type " . ref($p) . " in collection #$self->{id}";
        }
        $ids_seen->{$p->{id}} = 1;
    }
    #warn "returning, got $hectares";
    return $hectares;
}


=item attributes

Return this collection's attributes.

=cut
sub attributes ($) {
    my $self = shift;
    return $self->{ntf}->{attributes}->{$self->{attrid}};
}

package Geo::OSBoundaryLine::NTFFile;

use strict;

use Error qw(:try);
use IO::File;
use IO::Handle;
use Fcntl;
use Data::Dumper;

use fields qw(attributes geometries chains polygons complexes collections);

=back

=head1 NAME

Geo::OSBoundaryLine::NTFFile

=head1 DESCRIPTION

Object representing the data in a single NTF file from Boundary-Line.

=head1 METHODS

=over 4

=item new FILENAME

=item new HANDLE

=item new LINES

=item new CLOSURE

Parse NTF data and construct an object representing it. Supply either FILENAME,
the name of a Boundary-Line NTF file; HANDLE, a filehandle open on such a file;
LINES, a reference to a list of lines from the file; or CLOSURE, a code ref
which should be called to obtain each new line and which should return undef at
end-of-file.

Throws an exception of type Geo::OSBoundaryLine::Error on failure.

=cut
sub new ($$) {
    my ($class, $x) = @_;
    my $get;    # closure used to read lines from file or whatever
 
    my $closeafter = 0;
    if (ref($x) eq '') {
        $x = new IO::File($x, O_RDONLY)
            or throw Geo::OSBoundaryLine::Error("$x: $!");
        $closeafter = 1;
    }

    if (ref($x) eq 'CODE') {
        $get = $x;
    } elsif (ref($x) eq 'ARRAY') {
        my $i = 0;
        $get = sub () { return $x->[$i++]; };
    } elsif (ref($x) eq 'GLOB' || UNIVERSAL::isa($x, 'IO::Handle')) {
        $get = sub () { my $l = $x->getline(); throw Geo::OSBoundaryLine::Error($!) if (!defined($l) && $x->error()); return $l; };
    }

    my $i = 1;
    # represent object as a pseudohash
    my $self = fields::new($class);
    my $linenum = 1;

    # Types of records, and the subroutines we use to parse them. We only parse
    # those records which describe geometry -- everything else in BL is
    # basically fixed.
    my %recordtypes = (
            '01' => ['Volume Header'],
            '02' => ['Database Header'],
            '05' => ['Feature Classification'],
            '07' => ['Section Header'],
            '14' => ['Attribute', \&parse_14],
            '21' => ['Two-dimensional Geometry', \&parse_21],
            '23' => ['Line'],
            '24' => ['Chain', \&parse_24],
            '31' => ['Polygon', \&parse_31],
            '33' => ['Complex Polygon', \&parse_33],
            '34' => ['Collection of Features', \&parse_34],
            '40' => ['Attribute Description'],
            '42' => ['Code List'],
            '99' => ['Volume Termination']
        );

    while (defined(my $record = &$get())) {
        ++$linenum;
        $record =~ s#\r?\n##;
        while ($record =~ m#1%$#) {
            $record =~ s#1%$##;
            my $x = &$get();
            $x =~ s#\r?\n$##;
            throw Geo::OSBoundaryLine::Error("line $linenum: continuation line does not begin \"00\"")
                unless ($x =~ m#^00#);
            $record .= substr($x, 2);
        }

        throw Geo::OSBoundaryLine::Error("line $linenum: bad record format")
            unless ($record =~ m#^(\d{2})#);

        my $code = substr($record, 0, 2);

        throw Geo::OSBoundaryLine::Error("line $linenum: bad record type \"$code\"")
            unless (exists($recordtypes{$code}));

        # XXX check that volume begins with an 01 volume header record?

        &{$recordtypes{$code}->[1]}($self, substr($record, 2)) if ($recordtypes{$code}->[1]);

        undef $record;
    }

    # XXX check that volume ends with a 99 volume termination record?

    $x->close() if ($closeafter);

    return bless($self, $class);
}

# parse_14 OBJECT RECORD
# Parse Attribute Record. These tell us the various ID numbers, types and name
# of other objects.
sub parse_14 ($$) {
    my ($obj, $rec) = @_;

    # There are various sorts of attribute records. We only care about the ones
    # which apply to "collections" or "polygons".

    # Parse attributes for polygons
    if ($rec =~ /^\d{6}PI/) {
        die "bad PI attributes record \"$rec\"" unless $rec =~ m/^(\d{6})PI(\d{6})HA(\d{12})0%$/;
        $obj->{attributes}->{int($1)} =
            new Geo::OSBoundaryLine::PolyAttribute(
                    id => int($1),
                    hectares => int($3) / 1000.0,  
                );
        return;
    }

    # Return if we don't have a collection
    if ($rec !~ /^\d{6}AI/) {
        $debug && print "Attribute Record ignored for non-collection, non-polygon object\n";
        return;
    }

    # Parse attributes for collections
    die "Bad Attribute Record \"$rec\""
        unless ($rec =~ m/^(\d{6})      # attribute ID
                            AI
                            (\d{6})     # admin area ID
                            NA
                            (\d{12})    # non-inland area
                            OP
                            (.{7})      # census code
                            TY
                            (..)        # type: AA, administrative; VA, voting;
                                        # FA, non-area; TA, sea
                            AC
                            (...)       # area type, i.e. DIS, CTY etc.
                            NM
                            ([^\\]*)    # name
                            \\
                            (
                                (?:
                                NB
                                ...     # optional non-type-codes
                                )*
                            )?
                            0%$/x);

    my $non_type_codes = undef;
    if ($8) {
        $non_type_codes = [grep(/.../, split(/NB/, $8))];
    }

    $obj->{attributes}->{int($1)} =
        new Geo::OSBoundaryLine::Attribute(
                id => int($1),
                admin_area_id => $2,
                non_inland_area => int($3) / 1000.0,  
                ons_code => ($4 eq '999999 ' ? undef : $4),
                type => $5,
                area_type => $6,
                name => $7,
                non_type_codes => $non_type_codes
            );
    
    $debug && print <<EOF;
Collection of Features Attribute record:
    Attribute ID: $1
    Admin Area ID: $2
    ONS code: $4
    Type: $5
    Area Type: $6
    Name: "$7"
EOF
    if ($debug && $8) {
        print "    Non-Type-Code: ", join(", ", @$non_type_codes), "\n";
    }
}

# parse_21 OBJECT RECORD
# Parse Two-dimensional Geometry Record. These are lists of points which are
# later assembled into polygons.
sub parse_21 ($$) {
    my ($obj, $rec) = @_;

    my $num = substr($rec, 7, 4);    

    die "bad Two-dimensional Geometry Record \"$rec\""
        unless ($rec =~ m/^
                            \d{6}       # geometry ID
                            2
                            \d{4}       # number of coordinates
                        /x
                && $rec =~ m/
                            [ ]         # last coordinate separator
                            
                            (|\d{6})    # optional attribute ID
                
                            0%$/x
                # don't match the coordinates with a regex, as there may be
                # zillions of them.
                && (length($rec) == 11 + 17 * $num + 2
                    || length($rec) == 11 + 17 * $num + 8));

    my $geomid = int(substr($rec, 0, 6));
    my $attrid = defined($3) ? int($3) : undef;

    $obj->{geometries}->{$geomid} = [ ];
    for (my $i = 0; $i < $num; ++$i) {
        my $x = 0.1 * substr($rec, 11 + 17 * $i, 8);
        my $y = 0.1 * substr($rec, 19 + 17 * $i, 8);
        push(@{$obj->{geometries}->{$geomid}}, [$x, $y]);
    }
    
    $debug && print <<EOF;
Two-dimensional Geometry:
    Geometry ID: $geomid
    Number of points: $num
    Attribute ID: $attrid
EOF
}

# parse_24 OBJECT RECORD
# Parse Chain Record. Chains link together sets of geometries to form the
# outlines of polygons.
sub parse_24 ($$) {
    my ($obj, $rec) = @_;

    my $num = substr($rec, 6, 4);
    die "bad Chain Record \"$rec\"" unless ($rec =~ m/^(\d{6}) $num ((?:\d{6}[12]){$num}) 0%$/x);

    my $chainid = int($1);
    # Each part specifies a geometry record, and whether it is to be used
    # start-to-end (1) or end-to-start (2).
    my @parts = grep { $_ ne '' } split(/(\d{6})([12])/, $2);

    die "Chain Record has odd number (" . scalar(@parts) . ") of parts" if (@parts & 1);
    die "Chain Record has wrong number of parts (" . scalar(@parts) . " vs. " . 2 * $num . ")" if (@parts != 2 * $num);

    die "Chain Record refers to non-existent polygon" unless (exists($obj->{polygons}->{$chainid}));

    $debug && print <<EOF;
Chain:
    Chain ID: $chainid
    Number of parts: $num
EOF

    $obj->{chains}->{$chainid} = [ ];
    for (my $i = 0; $i < @parts; $i += 2) {
        push(@{$obj->{chains}->{$chainid}}, [int($parts[$i]), $parts[$i + 1]]);
    }
}

# parse_31 OBJECT RECORD
# Parse Polygon Record. Each polygon identifies a chain which makes up its
# parts. Conveniently, the polygon ID and chain ID are always equal.
sub parse_31 ($$) {
    my ($obj, $rec) = @_;

    die "bad Polygon Record \"$rec\"" unless ($rec =~ m/^(\d{6}) \1 0{6} 01 (\d{6}) 0%$/x
                                              or $rec =~ m/^(\d{6}) \1 0%$/x);

    my $polyid = int($1);
    my $attrid = defined($2) ? int($2) : undef;

    $obj->{polygons}->{$polyid} = new Geo::OSBoundaryLine::Polygon($obj, $polyid, $attrid);

    $debug && print <<EOF;
Polygon:
    Polygon ID: $polyid
EOF
}

# parse_33 OBJECT RECORD
# Parse Complex Polygon Record. Each complex polygon refers to a list of
# polygons, each being associated with a sense (+ or -).
sub parse_33 ($$) {
    my ($obj, $rec) = @_;

    my $num = substr($rec, 6, 4);

    die "bad Complex Polygon Record \"$rec\"" unless ($rec =~ m/(\d{6}) $num ((?:\d{6}[+-]){$num}) 0{6} 01 (\d{6}) 0%$/x);

    my $complexid = int($1);
    my @parts = grep { $_ ne '' } split(/(\d{6})([+-])/, $2);
    my $attrid = int($3);

    die "Complex Polygon Record has odd number (" . scalar(@parts) . ") of parts" if (@parts & 1);
    die "Complex Polygon Record has wrong number of parts (" . scalar(@parts) . " vs. " . 2 * $num . ")" if (@parts != 2 * $num);

    $debug && print <<EOF;
Complex Polygon:
    Complex Polygon ID: $complexid
    Number of parts: $num
EOF

    my @pp = ( );
    for (my $i = 0; $i < @parts; $i += 2) {
        die "complex polygon #$complexid references non-existent polygon #", int($parts[$i]), " (sense $parts[$i + 1])"
            unless (exists($obj->{polygons}->{int($parts[$i])}));
        push(@pp, [$obj->{polygons}->{int($parts[$i])}, $parts[$i + 1] eq '+' ? +1 : -1]);
    }
    $obj->{complexes}->{$complexid} = new Geo::OSBoundaryLine::ComplexPolygon($obj, $complexid, \@pp, $attrid);
}

# parse_34 OBJECT RECORD
# Parse Collection of Features Record. Collections-of-features consist of a
# list of polygons, complex polygons, and other collections of features which
# make them up. These are the top-level objects which are used to represent
# individual voting or administrative areas.
sub parse_34 ($$) {
    my ($obj, $rec) = @_;

    my $num = substr($rec, 6, 4);

    die "bad Collection of Features Record \"$rec\"" unless ($rec =~ m/(\d{6}) $num ((?:3[134]\d{6}){$num}) 01 (\d{6}) 0%$/x);

    my $collectid = int($1);
    my @parts = grep { $_ ne '' } split(/(3[134])(\d{6})/, $2);
    my $attrid = int($3);

    die "Collection of Features Record has odd number (" . scalar(@parts) . ") of parts" if (@parts & 1);
    die "Collection of Features Record has wrong number of parts (" . scalar(@parts) . " vs. " . 2 * $num . ")" if (@parts != 2 * $num);

    $debug && print <<EOF;
Collection of Features Record:
    Collection of Features ID: $collectid
    Attribute ID: $attrid
    Number of parts: $num
EOF

    $debug && print "    Parts:";

    my @pp = ( );
    my %tymap = qw( 31 polygons 33 complexes 34 collections );
    for (my $i = 0; $i < @parts; $i += 2) {
        my ($ty, $id) = ($parts[$i], int($parts[$i + 1]));
        die "Collection of Features Record refers to non-existent object #$id"
            unless (exists($obj->{$tymap{$ty}}->{$id}));
        push(@pp, $obj->{$tymap{$ty}}->{$id});
        $debug && print " $tymap{$ty} #$id";
    }
    $debug && print "\n";
    $obj->{collections}->{$collectid} = new Geo::OSBoundaryLine::CollectionOfFeatures($obj, $collectid, $attrid, \@pp);
}

1;
