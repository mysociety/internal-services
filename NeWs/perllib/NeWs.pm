#!/usr/bin/perl -I../../../perllib
#
# NeWs.pm:
# Infrastructure for the Newspaper Whereabouts Service.
#
# Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: NeWs.pm,v 1.2 2006-03-23 09:47:27 louise Exp $
#

package NeWs;

use strict;

use DBI;
use DBD::Pg;


use mySociety::Config;
use mySociety::DBHandle qw(dbh);

mySociety::DBHandle::configure(
        Name => mySociety::Config::get('NEWS_DB_NAME'),
        User => mySociety::Config::get('NEWS_DB_USER'),
        Password => mySociety::Config::get('NEWS_DB_PASS'),
        Host => mySociety::Config::get('NEWS_DB_HOST', undef),
        Port => mySociety::Config::get('NEWS_DB_PORT', undef)
			       );

=head1 NAME

NeWs

=head1 DESCRIPTION

Implementation of NeWs

=head1 CONSTANTS

=over 4
=back


=head1 FUNCTIONS

=over 4

=cut


=item get_newspaper nsid

Given a newspaper society ID, returns information about that newspaper

=cut

sub get_newspaper($){
    
    my ($nsid) = @_;
    my ($name, $editor, $address, $postcode) = dbh()->selectrow_array('select name, editor, address, postcode from newspaper where nsid = ?', {}, $nsid);
    return [ $name, $editor, $address, $postcode ] ;
}

#----------------------------------------------

package NeWs::Paper;

# Object representing an individual newspaper.

use strict;
use fields qw(nsid name editor address postcode website isweekly isevening free email fax telephone lat lon circulation coverage deleted);

use IO::String;
use RABX;
use Data::Dumper;

use mySociety::MaPit;
use mySociety::Util;

mySociety::Util::create_accessor_methods();

# new FIELD VALUE ...
# Constructor.
sub new ($%) {
    my ($class, %f) = @_;
    my $self = fields::new($class);
    %$self= %f;
    my @coverage_objs;
    foreach (@{$self->{coverage}}){
        my %coverage = ('name'=>$_->[0], 'population'=>$_->[1], 'coverage'=>$_->[2], 'lat'=>$_->[3], 'lon'=>$_->[4]);
	my $coverage_obj = NeWs::Paper::Coverage->new(%coverage);
	push(@coverage_objs, $coverage_obj);
    }
 
    @{$self->{coverage}} = @coverage_objs;
    return bless($self, $class);
}

# publish
# Publish the record to the database as the current record for this newspaper.
sub publish ($) {
    my $self = shift;
    
    #find out the id of the record in the newspaper table if one exists
    my $newspaper_id = scalar(NeWs::dbh()->selectrow_array('
                                        select id from newspaper
                                        where nsid = ?', {}, $self->nsid()));

    if (defined($newspaper_id)){
        
        #delete any existing coverage records
	NeWs::dbh()->do('delete from coverage where newspaper_id = ?', {}, $newspaper_id);
        NeWs::dbh()->do('delete from newspaper where id = ?', {}, $newspaper_id);
    
    }

    return if ($self->deleted());
    my $stmt = "insert into newspaper ("
                    . join(", ", sort grep { $_ ne 'coverage' && $_ ne 'deleted'} keys %$self)
                    . ") values ("
                    . join(", ", map { NeWs::dbh()->quote($self->{$_}) } sort grep { $_ ne 'coverage' && $_ ne 'deleted' } keys %$self)
                    . ")";

 
    NeWs::dbh()->do($stmt);
    
    $newspaper_id = scalar(NeWs::dbh()->selectrow_array("select currval('newspaper_id_seq')"));
   
    foreach (@{$self->{coverage}}) {
	
	#find the location record if one exists
	
	my $location_id = NeWs::dbh()->selectrow_array('
                                           select id from location 
                                           where name = ?', {}, $_->name);

	#if there is no location record, insert one
	if (!defined($location_id)){

        	
	    NeWs::dbh()->do('
                    insert into location(
                        name, population, lat, lon
                    ) values (?, ?, ?, ?)', 
		    {},
		    $_->name(), $_->population(), $_->lat(), $_->lon());
	    
	    #get the id
            $location_id = scalar(NeWs::dbh()->selectrow_array("select currval('location_id_seq')"));
	    
	}

    
        NeWs::dbh()->do('
                insert into coverage (
                    newspaper_id, location_id, coverage
                ) values (?, ?, ?)',
                {},
                $newspaper_id, $location_id, $_->coverage());
    }
	
    NeWs::dbh()->commit();
}

# save EDITOR
# Save a copy of the record in the database edit history, as from EDITOR; if
# EDITOR is undef, this means "changes from the scraper".
sub save_db ($$) {
    my ($self, $editor) = @_;

    my $buf = '';
    my $h = new IO::String($buf);
    RABX::wire_wr($self, $h);
    
    my $s = NeWs::dbh()->prepare('insert into newspaper_edit_history (nsid, source, data, isdeleted) values (?, ?, ?, ?)');
    $s->bind_param(1, $self->nsid());
    $s->bind_param(2, $editor);
    $s->bind_param(3, $buf, { pg_type => DBD::Pg::PG_BYTEA });
    $s->bind_param(4, $self->deleted() ? 't' : 'f');
    $s->execute();
}

sub diff_one ($$) {
    my ($a, $b) = @_;
    if (defined($a) && !defined($b)) {
        return -1;
    } elsif (!defined($a) && defined($b)) {
        return +1;
    } elsif (!defined($a) && !defined($b)) {
        return undef;   # shouldn't happen
    } elsif ($a ne $b) {
        return 1;
    } else {
        return undef;
    }
}

# diff A B
# Return a reference to a hash indicating differences between papers A and B.
# For each field, and each named circulation entry, the hash value is -1 if it
# is present in A but not in B, +1 vice versa, or 0 if it is present in both
# but different.
sub diff ($$) {
    my ($A, $B) = @_;
    my %r = ( );
    foreach (grep { $_ ne 'circulation' } keys %$A) {
        my $d = diff_one($A->{$_}, $B->{$_});
        $r{$_} = $d if (defined($d));
    }

    $r{coverage} = { };
 
    my %Acirc = map { $_[0] => [@{$_}[1 .. 3]] } @{$A->coverage()};
    my %Bcirc = map { $_[0] => [@{$_}[1 .. 3]] } @{$A->coverage()};

    foreach (keys(%Acirc), keys(%Bcirc)) {
        my $d = diff_one($Acirc{$_}, $Bcirc{$_});
        $r{coverage}->{$_} = $d if (defined($d));
    }
    
    return \%r;
}

#----------------------------------------------

package NeWs::Paper::Coverage;

# Object representing the circulation of an individual newspaper in an
# individual location.

use strict;
use Data::Dumper;

use fields qw( name population lat lon coverage );


mySociety::Util::create_accessor_methods();

# Constructor.
sub new ($%) {
    
    my ($class, %f) = @_;
    my $self = fields::new($class);
    %$self= %f;
    return bless($self, $class);
}


1;

