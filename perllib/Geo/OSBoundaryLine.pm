#!/usr/bin/perl
#
# OSBoundaryLine.pm:
# Parse Ordnance Survey Boundary-Line data from its original NTF format.
#
# Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: OSBoundaryLine.pm,v 1.2 2005-06-09 15:33:20 chris Exp $
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

use fields qw(id admin_area_id ons_code area_type name non_type_codes);

my %checks = (
        id => qr/^[1-9]\d*$/,
        admin_area_id => qr/^[1-9]\d*$/,
        ons_code => sub { return !defined($_[0]) || $_[0] =~ /^[1-9]\d*$/ },
        area_type => sub { return defined($_[0]) && exists($area_types{$_[0]}) },
        name => qr/./,
        non_type_codes => sub { return !defined($_[0]) || (ref($_[0]) eq 'ARRAY' && 0 == grep { !exists($area_types{$_}) } @{$_[0]}); }
    );

sub new ($%) {
    my ($class, %a) = @_;
    my $self = fields::new($class);
    foreach (keys %a) {
        if (!exists($checks{$_})) {
            die "unknown field '$_' in constructor for Geo::OSBoundaryLine::Attribute";
        } elsif (ref($checks{$_}) eq 'Regexp' && $a{$_} !~ $checks{$_}
                 || !&{$checks{$_}}($a{$_})) {
            throw Geo::OSBoundaryLine::Error("Bad value '$a{$_}' for field '$_' in constructore for Geo::OSBoundaryLine::Attribute";
        } else {
            $self->{$_} = $a{$_};
        }
    }
    return $self;
}

# accessor methods
foreach (keys %checks) {
    eval 'sub ' . $_ . ' ($) { my $self = shift; return $self->{' . $_ . '}';
}

package Geo::OSBoundaryLine::Polygon;

use fields qw(ntf id);

sub new ($$$) {
    my ($class, $ntf, $id) = @_;
    my $self = fields::new($class);
    die "no polygon with id '$id' in NTF file"
        unless (exists($ntf->{chains}->{$id}));
    $self->{ntf} = $ntf;
    $self->{id} = $id;
    return $self;
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
    return wantarray() ? $n : @verts;
}

package Geo::OSBoundaryLine::ComplexPolygon;

use fields qw(ntf id);

sub new ($$$) {
    my ($class, $ntf, $id) = @_;
    my $self = fields::new($class);
    die "no complex polygon with id '$id' in NTF file"
        unless (exists($ntf->{complexes}->{$id}));
    $self->{ntf} = $ntf;
    $self->{id} = $id;
    return $self;
}

=item parts

In scalar context, return the number of parts this complex polygon has. In
list context, return a list of the parts and their sense (positive meaning
"included", negative meaning "excluded").

=cut
sub parts ($) {
    my $self = shift;
    my $ntf = $self->{ntf};
    if (wantarray()) {
        return map { [new Geo::OSBoundaryLine::Polygon($ntf, $_->[0]), $_->[1] eq '+' ? +1 : -1] } @{$self->{ntf}->{complexes}->{$self->{id}}};
    } else {
        return @{$ntf->{complexes}->{$self->{id}}};
    }
}

=item part INDEX

Return in list context the polygonal part identified by the given INDEX
(starting at zero) and its sense (positive or negative).

=cut
sub part ($$) {
    my ($self, $i) = @_;
    my $ntf = $self->{ntf};
    if ($i >= @{$self->{ntf}->{complexes}->{$self->{id}}}) {
        die "index '$i' out of range for complex polygon id '$self->{id}'";
    }
    return (new Geo::OSBoundaryLine::Polygon($ntf, $ntf->{complexes}->{$self->{id}}->[$i]->[0]), $ntf->{complexes}->{$self->{id}}->[$i]->[0]);
}

package Geo::OSBoundaryLine::NTFFile;

use strict;

use Error qw(:try);
use IO::Handle;

use fields qw(attributes geometries chains polygons complexes collections);

=head1 Name

Geo::OSBoundaryLine::File

=head1 Description

Object representing the data in a single NTF file from Boundary-Line.

=head1 Functions

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
        $get = sub () { my $l = $x->getline(); throw Geo::OSBoundaryLine::Error($!) if (!defined($l) && $x->error()); };
    }

    my $i = 1;
    # represent object as a pseudohash
    my $self = fields::new($class);
    my $linenum = 1;

    # Types of records, and the subroutines we use to parse them. We only parse
    # those records which describe geometry -- everything else in BL is
    # basically fixed.
    my %recordtypes = (
            '01' => ['Volume Header']
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
        chomp($record);
        while ($record =~ m#1%$#) {
            $record =~ s#1%$##;
            my $x = &$get();
            throw Geo::OSBoundaryLine::Error("line $linenum: continuation line does not begin \"00\"")
                unless ($x =~ m#^00#);
            $x =~ s#^00##;
            $record .= $x;
        }

        throw Geo::OSBoundaryLine::Error("line $linenum: bad record format")
            unless ($record =~ m#^(\d{2})(.+)#);

        my $code = $1;
        $record = $2;

        throw Geo::OSBoundaryLine::Error("line $linenum: bad record type \"$code\"")
            unless (exists($recordtypes{$code}));

        # XXX check that volume begins with an 01 volume header record?

        &{$recordtypes{$code}->[1]}($self, $record) if ($recordtypes{$code}->[1]);
    }

    # XXX check that volume ends with a 99 volume termination record?

    $x->close() if ($closeafter);

    return $self;
}

# parse_14 OBJECT RECORD
# Parse Attribute Record. These tell us the various ID numbers, types and name
# of other objects.
sub parse_14 ($$) {
    my ($obj, $rec) = @_;

    # There are various sorts of attribute records. We only care about the ones
    # which apply to "collections".
    if ($rec !~ /^\d{6}AI/) {
        $debug && print "Attribute Record ignored for non-collection object\n";
        return;
    }

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
                            (...)       # type, i.e. DIS, CTY etc.
                            NM
                            ([^\\]*)    # name
                            \\
                            (
                                (?:
                                NB
                                ...     # optional non-type-codes
                                )*
                            )?
                            0$/x);

    my $non_type_codes = undef;
    if ($8) {
        $non_type_codes = [grep(/.../, split(/NB/, $8))];
    }

    $obj->{attributes}->{$1} =
        new Geo::OSBoundaryLine::Attribute(
                id => $1,
                admin_area_id => $2,
                ons_code => ($3 eq '999999' ? undef : $3),
                type => $5,
                area_type => $6,
                name => $7
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
        print "    Non-Type-Code: ", join(", ", @types), "\n";
    }
}

# parse_21 OBJECT RECORD
# Parse Two-dimensional Geometry Record. These are lists of points which are
# later assembled into polygons.
sub parse_21 ($$) {
    my ($obj, $rec) = @_;

    my $num = substr($rec, 7, 4);    

    die "bad Two-dimensional Geometry Record \"$rec\""
        unless ($rec =~ m/^(\d{6})      # geometry ID
                            2
                            \d{4}       # number of coordinates
                            
                            ((?:\d{8}\d{8}\ )+)
                                         # points

                            (|\d{6})     # attribute ID
                            0$/x);
    my $geomid = $1;
    my $attrid = $3;
    my @coords = grep { $_ ne '' } split(/(\d{8})(\d{8}) /, $2);
    
    die "Two-dimensional Geometry Record has odd number (" . scalar(@coords) . ") of coordinates" if (@coords & 1);
    die "Two-dimensional Geometry Record has wrong number of coordinates (" . scalar(@coords) . " vs. " . 2 * $num . ")" if (@coords != 2 * $num);
    
    $debug && print <<EOF;
Two-dimensional Geometry:
    Geometry ID: $geomid
    Number of points: $num
    Attribute ID: $attrid
EOF
    $obj->{geometries}->{$geomid} = [ ];
    for (my $i = 0; $i < @coords; $i += 2) {
        push(@{$obj->{geometries}->{$geomid}}, [$coords[$i], $coords[$i + 1]]);
    }
}

# parse_24 OBJECT RECORD
# Parse Chain Record. Chains link together sets of geometries to form the
# outlines of polygons.
sub parse_24 ($$) {
    my ($obj, $rec) = @_;

    my $num = substr($rec, 6, 4);
    die "bad Chain Record \"$rec\"" unless ($rec =~ m/^(\d{6}) $num ((?:\d{6}[12]){$num})  0$/x);

    my $chainid = $1;
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
        push(@{$obj->{chains}->{$chainid}}, [$parts[$i], $parts[$i + 1]]);
    }
}

# parse_31 OBJECT RECORD
# Parse Polygon Record. Each polygon identifies a chain which makes up its
# parts. Conveniently, the polygon ID and chain ID are always equal.
sub parse_31 ($$) {
    my ($obj, $rec) = @_;

    die "bad Polygon Record \"$rec\"" unless ($rec =~ m/^(\d{6}) \1 0{6} 01 (\d{6}) 0$/x
                                              or $rec =~ m/^(\d{6}) \1 0$/x);

    my $polyid = $1;
    my $attrid = $2;

    $obj->{polygons}->{$polyid} = { };

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

    die "bad Complex Polygon Record \"$rec\"" unless ($rec =~ m/(\d{6}) $num ((?:\d{6}[+-]){$num}) 0{6} 01 (\d{6}) 0$/x);

    my $complexid = $1;
    my @parts = grep { $_ ne '' } split(/(\d{6})([+-])/, $2);
    my $attrid = $3;

    die "Complex Polygon Record has odd number (" . scalar(@parts) . ") of parts" if (@parts & 1);
    die "Complex Polygon Record has wrong number of parts (" . scalar(@parts) . " vs. " . 2 * $num . ")" if (@parts != 2 * $num);

    $debug && print <<EOF;
Complex Polygon:
    Complex Polygon ID: $complexid
    Number of parts: $num
EOF

    $obj->{complexes}->{$complexid} = [ ];
    for (my $i = 0; $i < @parts; $i += 2) {
        push(@{$obj->{complexes}->{$complexid}}, [$parts[$i], $parts[$i + 1]]);
    }
}

# parse_34 OBJECT RECORD
# Parse Collection of Features Record. Collections-of-features consist of a
# list of polygons, complex polygons, and other collections of features which
# make them up. These are the top-level objects which are used to represent
# individual voting or administrative areas.
sub parse_34 ($$) {
    my ($obj, $rec) = @_;

    my $num = substr($rec, 6, 4);

    die "bad Collection of Features Record \"$rec\"" unless ($rec =~ m/(\d{6}) $num ((?:3[134]\d{6}){$num}) 01 (\d{6}) 0$/x);

    my $collectid = $1;
    my @parts = grep { $_ ne '' } split(/(3[134])(\d{6})/, $2);
    my $attrid = $3;

    die "Collection of Features Record has odd number (" . scalar(@parts) . ") of parts" if (@parts & 1);
    die "Collection of Features Record has wrong number of parts (" . scalar(@parts) . " vs. " . 2 * $num . ")" if (@parts != 2 * $num);

    $debug && print <<EOF;
Collection of Features Record:
    Collection of Features ID: $collectid
    Attribute ID: $attrid
    Number of parts: $num
EOF

    $obj->{collections}->{$collectid} = [ ];
    my %tymap = qw( 31 polygons 33 complexes 34 collections );
    for (my $i = 0; $i < @parts; $i += 2) {
        my ($ty, $id) = ($parts[$i], $parts[$i + 1]);
        die "Collection of Features Record refers to non-existent object #$id"
            unless (exists($obj->{$tymap{$ty}}->{$id}));
        push(@{$obj->{collections}->{$collectid}}, [$ty, $id]);
    }
}

1;
