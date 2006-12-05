#!/usr/bin/perl -I../perllib
#
# NeWs.t:
# Tests for the Newspaper Whereabouts Service
#
#  Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: louise.crow@gmail.com; WWW: http://www.mysociety.org/
#
# $Id: NeWs.t,v 1.3 2006-12-05 12:53:54 louise Exp $
#

use strict;
use warnings; 

# Horrible boilerplate to set up appropriate library paths.
use FindBin;
use lib "$FindBin::Bin/../perllib";
use lib "$FindBin::Bin/../../../perllib";

use Test::More tests=>20;

# Do this first of all, because NeWs.pm needs to see the config file.
BEGIN {
    use mySociety::Config;
    mySociety::Config::set_file('../../conf/general');
}


our %fields = ('name'=>'Test Newspaper',
               'editor'=>'Test Editor',
               'address'=>'Test Address',
               'postcode'=>'Test Postcode',
               'website'=>'Test Website',
               'isweekly'=>1,
               'isevening'=>1,
               'free'=>1,
               'email'=>'Test Email',
               'fax'=>'Test Fax',
               'telephone'=>'Test Telephone',
	       'isdeleted'=>'f',
       	       'nsid'=>'50000') ;

#---------------------------------

sub test_new(){

    #confirm no record exists
    my $news_hash_ref = NeWs::get_newspapers_by_name($fields{'name'});
    my %news_hash = %$news_hash_ref;
    ok(keys %news_hash == 0);

 
    #publish a new record
    my $news = NeWs::Paper->new(\%fields);
    my $update_coverage = 1;
    my $source = '';
    $news->publish($source, $update_coverage);
    
    #retrieve the record
    $news_hash_ref = NeWs::get_newspapers_by_name($fields{'name'});
    %news_hash = %$news_hash_ref;
    ok(keys %news_hash == 1);    

    return 1;


}

#---------------------------------

sub test_update_name(){
    
    my $updated_name = 'New Test Title';
    my $news = NeWs::Paper->new(\%fields);
    $news->name($updated_name);
    my $update_coverage = 0;
    my $source = '';
    $news->publish($source, $update_coverage);

    #get the record back from the db - shouldn't be accessible under the old name
    my $news_hash_ref = NeWs::get_newspapers_by_name($fields{'name'});
    my %news_hash = %$news_hash_ref;
    ok(keys %news_hash == 0);

    #but should be there under the new one
    $news_hash_ref = NeWs::get_newspapers_by_name($updated_name);
    %news_hash = %$news_hash_ref;
    ok(keys %news_hash == 1);

    return 1;

}

#---------------------------------

sub test_delete(){
    
    my $updated_name = 'New Test Title';
    my $news = NeWs::Paper->new(\%fields);
    my $update_coverage = 0;
    my $source = '';
    $news->isdeleted('t');
    $news->publish($source, $update_coverage);
    
    #no longer there under updated name
    my $news_hash_ref = NeWs::get_newspapers_by_name($updated_name);
    my %news_hash = %$news_hash_ref;
    ok(keys %news_hash == 0);

    #no longer there under original name
    $news_hash_ref = NeWs::get_newspapers_by_name($fields{'name'});
    %news_hash = %$news_hash_ref;
    ok(keys %news_hash == 0);


    return 1;
}

#---------------------------------

sub test_get_newspapers_by_name(){
    
    #should be more than one with news in the title
    my $news_hash_ref = NeWs::get_newspapers_by_name('News');
    my %news_hash = %$news_hash_ref;
    ok(keys %news_hash > 1);
 
    #Test on a name that should be unique
    $news_hash_ref = NeWs::get_newspapers_by_name('Alfreton Chad'); 
    %news_hash = %$news_hash_ref;
    ok(keys %news_hash == 1);
    return 1;    

}

#---------------------------------

sub test_get_coverage(){
    
    #first get a newspaper
    my $news_hash_ref = NeWs::get_newspapers_by_name('Plymouth Sunday Independent');
    my %news_hash = %$news_hash_ref;
    
    #should be one result
    ok (keys %news_hash == 1);
    my @newspaper_id = keys %news_hash;

    my $coverage_array_ref = NeWs::get_coverage( $newspaper_id[0] );
    my @coverage_array = @$coverage_array_ref;

    ok(@coverage_array > 1);
    
    return 1;
}

#----------------------------------

sub test_get_locations(){

    my $locations_array_ref = NeWs::get_locations(51.5012, -0.091322, 2.72);
    my @locations_array = @$locations_array_ref;
    ok(@locations_array > 1);
    return 1;
}


#----------------------------------

sub test_get_newspapers_by_location(){
    my $newspapers_array_ref = NeWs::get_newspapers_by_location(51.5012, -0.091322, 2.72);
    my @newspapers_array = @$newspapers_array_ref;
    ok(@newspapers_array > 1);
    return 1;

}

#----------------------------------

use_ok('NeWs');
ok(test_new() == 1);
ok(test_update_name() == 1);
ok(test_delete() == 1);
ok(test_get_newspapers_by_name() == 1);
ok(test_get_coverage() == 1);
ok(test_get_locations() == 1);
ok(test_get_newspapers_by_location() == 1);
