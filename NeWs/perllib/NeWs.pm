#!/usr/bin/perl -I../../../perllib
#
# NeWs.pm:
# Infrastructure for the Newspaper Whereabouts Service.
#
# Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: NeWs.pm,v 1.9 2007-03-08 21:46:23 matthew Exp $
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


=head1 FUNCTIONS

=over 4

=item get_newspaper ID

Given a newspaper ID, returns information about that newspaper

=cut

sub get_newspaper($){
    
    my ($id) = @_;
    my (@q) = dbh()->selectrow_array("select name, editor, address, postcode, 
                                      website, isweekly, isevening, free, email,
                                      fax, telephone, nsid
                                      from newspaper 
                                      where id = ? and isdeleted = false", {}, $id);
    return {'name'=>$q[0], 
	    'editor'=>$q[1], 
	    'address'=>$q[2], 
	    'postcode'=>$q[3],
	    'website'=>$q[4],
	    'isweekly'=>$q[5],
            'isevening'=>$q[6], 
	    'free'=>$q[7],
            'email'=>$q[8],
            'fax'=>$q[9],
            'telephone'=>$q[10],
            'nsid'=>$q[11]} ;
}

=item get_newspapers

Get a list of all the newspapers in the DB

=cut

sub get_newspapers(){
    my ($q) = dbh()->selectall_arrayref("select id, name 
                                         from newspaper
                                         where isdeleted = false 
                                         order by name asc");
    return $q ;
}

=item get_newspapers_by_name

Get a reference to an array of hashes of  newspapers in the DB matching a partial name string
=cut 

sub get_newspapers_by_name($){
    my ($partial_name) = @_;
    $partial_name = lc $partial_name;
    my @ret;


    my $rows = dbh()->selectall_arrayref("select distinct id, name
                                       from newspaper 
                                       where isdeleted = false
                                       and lower(name) like ?
                                       order by name asc", {}, '%' . $partial_name . '%');
      
    foreach (@$rows){

        my ($id, $name) = @$_;
	push( @ret, {'id' => $id,
                     'name' => $name });
    }

    return \@ret;
}

=item publish_newspaper_update ID EDITOR HASH

Update the newspaper with the ID using the attribute values in the hash and assigning the update
to the username EDITOR.

=cut

sub publish_newspaper_update($$$){

    my ($id, $editor, $fields) = @_;
    
    #create a newspaper object
    my $news = NeWs::Paper->new($fields);
    my $update_coverage = 0;
    $news->publish($editor, $update_coverage);
    
}

=item get_newspaper_history ID

Given a newspaper ID, returns the history of edits to that newspaper's record in the database 

=cut

sub get_newspaper_history($){
    
    my ($id) = @_;
    my @ret;

    my $rows = dbh()->selectall_arrayref("select id, lastchange, source, data, isdeleted
                                                  from newspaper_edit_history
                                                  where newspaper_id = ?
                                                  order by lastchange desc", {}, $id);
    

    foreach (@$rows){
	my ($change_id, $lastchange, $source, $data, $isdel) = @$_;
      
       
	my $data = RABX::wire_rd(new IO::String($data)); 
	push( @ret, {'lastchange' => $lastchange, 
                     'source' => $source,
		     'isdel' => $isdel,
                     'data' =>  $data});
    }
    return \@ret;
}

=item get_newspaper_coverage ID

Given a newspaper ID, returns a reference to an array of hashes containing the coverage information related to that newspaper

=cut

sub get_newspaper_coverage($){
    
    my ($id) = @_;
    my @ret;
   
    my $rows = dbh()->selectall_arrayref("select  name, lon, lat, population, coverage 
                                          from coverage, location
                                          where newspaper_id = ?
                                          and coverage.location_id = location.id          
                                          order by name asc", {}, $id);


    foreach (@$rows){
        my ($name, $lon, $lat, $population, $coverage) = @$_;

        push( @ret, {'name' => $name,
                     'lon' => $lon,
                     'lat' => $lat,
                     'population' =>  $population, 
		     'coverage' => $coverage });
    }
    return \@ret;

}

=item get_newspaper_journalists ID

Given a newspaper ID, returns a reference to an array of hashes containing the journalist information associated with that newspaper

=cut

sub get_newspaper_journalists($){
    my ($id) = @_;
    my @ret;

    my $rows = dbh()->selectall_arrayref("select id, name, interests, email, telephone, fax
                                          from journalist
                                          where newspaper_id = ?
                                          and isdeleted = false
                                          order by name asc", {}, $id);


    foreach (@$rows){
        my ($id, $name, $interests, $email, $telephone, $fax) = @$_;

        push( @ret, {'id' => $id,
	             'name' => $name,
                     'interests' => $interests,
		     'email' => $email,
		     'telephone' => $telephone, 
		     'fax' => $fax});
    }
    return \@ret;


}

=item get_locations_by_location LON LAT RADIUS

Given a longitude, latitude and radius, returns a reference to an array of hashes containing information on locations within that 
radius from the point defined by the latitude and longitude

=cut

sub get_locations_by_location($$$){
    my ($lat, $lon, $radius) = @_;
    my @ret;

   
    my $rows =  dbh()->selectall_arrayref("SELECT location.name, location.lon, location.lat, distance
                                           FROM location_find_nearby(?, ?, ?) AS nearby
                                           LEFT JOIN location on nearby.location_id = location.id
                                           ORDER BY distance", {}, $lat, $lon, $radius);
    
    foreach (@$rows){
	
	my ($name, $lon, $lat, $distance) = @$_;

	push( @ret, {'name' => $name,
                     'lon' => $lon,
                     'lat' => $lat,
                     'distance' =>  $distance });

    }
    return \@ret;
}

=item get_newspapers_by_location LON LAT RADIUS

Given a longitude, latitude and radius, returns a reference to an array of hashes containing information on newspapers that have 
coverage of locations within that radius from the point defined by the latitude and longitude

=cut

sub get_newspapers_by_location($$$){

    my ($lat, $lon, $radius) = @_;
    my @ret;

    my $rows =  dbh()->selectall_arrayref("SELECT newspaper_id, newspaper.name, sum(coverage)
                                           FROM location_find_nearby(?,?,?) AS nearby
                                           LEFT JOIN coverage on nearby.location_id = coverage.location_id
                                           LEFT JOIN newspaper on coverage.newspaper_id = newspaper.id
                                           GROUP BY newspaper_id, newspaper.name ORDER BY sum(coverage) desc;", {}, $lat, $lon, $radius);

    foreach (@$rows){

        my ($id, $name, $coverage) = @$_;

        push( @ret, {'id' => $id, 
	             'name' => $name,
                     'coverage' =>  $coverage });

    }
    return \@ret;

}

=item get_journalist ID

Given a journalist ID, return a hash of information about that journalist

=cut 

sub get_journalist($){

    my ($id) = @_;
    my (@q) = dbh()->selectrow_array("select id, newspaper_id, name, interests, email, telephone, fax 
                                      from journalist
                                      where id = ? and isdeleted = false", {}, $id);
    return {'id'=>$q[0],
            'newspaper_id'=>$q[1],
            'name'=>$q[2],
            'interests'=>$q[3],
            'email'=>$q[4],
            'telephone'=>$q[5],
            'fax'=>$q[6]};
           
}

=item publish_journalist_update EDITOR HASH

Publish a journalist record created from the attributes in the HASH to the newspaper indicated by ID 
This can either be a new record or an edit to an existing record. The edit is attributed to EDITOR
=cut

sub publish_journalist_update($$){
   
    my ($editor, $fields) = @_;

    my $journalist = NeWs::Journalist->new($fields);
    # records are not deleted using this API function
    $journalist->{'isdeleted'} = 'f';
    my $journalist_id = $journalist->publish($editor);
    return $journalist->id(); 
}

=item get_journalist_history ID

Given a journalist ID, returns the history of edits to that journalist's record in the database

=cut

sub get_journalist_history($){

    my ($id) = @_;
    my @ret;

    my $rows = dbh()->selectall_arrayref("select id, lastchange, source, data, isdeleted
                                                  from journalist_edit_history
                                                  where journalist_id = ?
                                                  order by lastchange desc", {}, $id);

    foreach (@$rows){
        my ($change_id, $lastchange, $source, $data, $isdel) = @$_;

        my $data = RABX::wire_rd(new IO::String($data));
        push( @ret, {'lastchange' => $lastchange,
                     'source' => $source,
                     'isdel' => $isdel,
                     'data' =>  $data});
    }
    return \@ret;
}


#=============================================

package NeWs::Paper;

# Object representing an individual newspaper.

use strict;
use fields qw(nsid name editor address postcode website isweekly isevening free email fax telephone lat lon circulation coverage isdeleted);

use IO::String;
use RABX;
use Data::Dumper;

use mySociety::MaPit;
use mySociety::Util;

mySociety::Util::create_accessor_methods();

#---------------------------------------------
# new FIELD VALUE ...
# Constructor.
sub new ($$) {
    my ($class, $f) = @_;
    my $self = fields::new($class);

    foreach(keys %$f){
	$self->{$_} = $f->{$_};
    }

    my @coverage_objs;
    foreach (@{$self->{coverage}}){
        my %coverage = ('name'=>$_->[0], 'population'=>$_->[1], 'coverage'=>$_->[2], 'lat'=>$_->[3], 'lon'=>$_->[4]);
	my $coverage_obj = NeWs::Paper::Coverage->new(%coverage);
	push(@coverage_objs, $coverage_obj);
    }
 
    @{$self->{coverage}} = @coverage_objs;
    return bless($self, $class);
}

#----------------------------------------------
# publish
# Publish the record to the database as the current record for this newspaper.
sub publish ($$$){

    my ($self, $editor, $update_coverage) = @_;
  
    #find out the id of the record in the newspaper table if one exists
    # by matching on nsid
    my $newspaper_id = scalar(NeWs::dbh()->selectrow_array('
                                        select id from newspaper
                                        where nsid = ?', {}, $self->nsid()));

    if (defined($newspaper_id)){
        
        #delete any existing coverage records if they are going to be replaced
	if ($update_coverage){

	    NeWs::dbh()->do('delete from coverage where newspaper_id = ?', {}, $newspaper_id);
	}
           
	my @update_list;
	foreach ( sort grep { $_ ne 'coverage'} keys %$self ){
	    unshift(@update_list, $_ . " = " . NeWs::dbh()->quote($self->{$_}));
	}
	my $stmt = "update newspaper set " . join(", ", @update_list) . " where id = " . $newspaper_id;

	NeWs::dbh()->do($stmt);
	
    }else{
	
	#this is a new record
	my $stmt = "insert into newspaper ("
	    . join(", ", sort grep { $_ ne 'coverage'} keys %$self)
                    . ") values ("
                    . join(", ", map { NeWs::dbh()->quote($self->{$_}) } sort grep { $_ ne 'coverage' } keys %$self)
                    . ")";
	NeWs::dbh()->do($stmt);
	$newspaper_id = scalar(NeWs::dbh()->selectrow_array("select currval('newspaper_id_seq')"));

    }
  
    #save a copy of the record in the newspaper_edit_history table
    $self->save_db( $newspaper_id, $editor );
   
    if ($update_coverage){
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

	    #insert the coverage record with a ref to the relevant location record
            NeWs::dbh()->do('
                    insert into coverage (
                        newspaper_id, location_id, coverage
                    ) values (?, ?, ?)',
                    {},
                    $newspaper_id, $location_id, $_->coverage());
       }
    }
    
    NeWs::dbh()->commit();
}

#------------------------------------------
# save_db NEWSPAPER_ID EDITOR
# Save a copy of the record in the database edit history, as from EDITOR; if
# EDITOR is undef, this means "changes from the scraper".
sub save_db ($$$) {
    my ($self, $newspaper_id, $editor) = @_;

    my $h = new IO::String();    
    my $storage;

    foreach( grep { $_ ne 'coverage'} keys %$self){
        $storage->{$_} = $self->{$_};
    }

    RABX::wire_wr( $storage, $h);
    
    my $s = NeWs::dbh()->prepare('insert into newspaper_edit_history (newspaper_id, source, data, isdeleted) values (?, ?, ?, ?)');
    $s->bind_param(1, $newspaper_id);
    $s->bind_param(2, $editor);
    $s->bind_param(3, ${$h->string_ref()}, { pg_type => DBD::Pg::PG_BYTEA });
    $s->bind_param(4, $self->isdeleted() ? 't' : 'f');
    $s->execute();
}

#------------------------------------------
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

#------------------------------------------
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

#===========================================

package NeWs::Paper::Coverage;

# Object representing the circulation of an individual newspaper in an
# individual location.

use strict;
use Data::Dumper;

use fields qw( name population lat lon coverage );


mySociety::Util::create_accessor_methods();

#-------------------------------------------
# Constructor.
sub new ($%) {
    
    my ($class, %f) = @_;
    my $self = fields::new($class);
    %$self= %f;
    return bless($self, $class);
}

#===========================================

package NeWs::Journalist;

# Object representing a journalist attached to a newspaper. 

use strict;
use Data::Dumper;

use fields qw( id name interests email telephone fax newspaper_id isdeleted );


mySociety::Util::create_accessor_methods();

#-------------------------------------------
# Constructor.
sub new ($$) {

    my ($class, $f) = @_;
    my $self = fields::new($class);
    foreach(keys %$f){
        $self->{$_} = $f->{$_};
    }
    return bless($self, $class);
}

#----------------------------------------------
# publish
# Publish the record to the database as the current record for this journalist.
sub publish ($$){

    my ($self, $editor) = @_;
      
    if (defined($self->id())){

	# existing record
	my @update_list;
	foreach ( sort grep { $_ ne 'id'} keys %$self ){
	    unshift(@update_list, $_ . " = " . NeWs::dbh()->quote($self->{$_}));
	}
	my $stmt = "update journalist set " . join(", ", @update_list) . " where id = " . $self->id();
	NeWs::dbh()->do($stmt);

    }else{

	# new record
	NeWs::dbh()->do('insert into journalist( newspaper_id, name, interests, telephone, fax, email) values (?, ?, ?, ?, ?, ?)',
		      {}, $self->newspaper_id(), $self->name(), $self->interests(), $self->telephone(), $self->fax(), $self->email());

	NeWs::dbh()->commit();
	$self->{'id'} = scalar(NeWs::dbh()->selectrow_array("select currval('journalist_id_seq')"));

    }
   
    #save a copy of the record in the journalist_edit_history table
    $self->save_db( $editor );

    NeWs::dbh()->commit();
}

#------------------------------------------
# save_db EDITOR
# Save a copy of the record in the database edit history, as from EDITOR
sub save_db ($$) {
    my ($self, $editor) = @_;

    my $h = new IO::String();
    my $storage;

    foreach(keys %$self){
        $storage->{$_} = $self->{$_};
    }

    RABX::wire_wr( $storage, $h);

    my $s = NeWs::dbh()->prepare('insert into journalist_edit_history (journalist_id, source, data, isdeleted) values (?, ?, ?, ?)');
    $s->bind_param(1, $self->id());
    $s->bind_param(2, $editor);
    $s->bind_param(3, ${$h->string_ref()}, { pg_type => DBD::Pg::PG_BYTEA });
    $s->bind_param(4, $self->isdeleted() ? 't' : 'f');
    $s->execute();
}


1;
