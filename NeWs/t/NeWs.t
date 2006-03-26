#!/usr/bin/perl -I../perllib
#
# NeWs.t:
# Tests for the Newspaper Whereabouts Service
#
#  Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: louise.crow@gmail.com; WWW: http://www.mysociety.org/
#
# $Id: NeWs.t,v 1.1 2006-03-26 13:21:16 louise Exp $
#

use strict;
use warnings; 

# Horrible boilerplate to set up appropriate library paths.
use FindBin;
use lib "$FindBin::Bin/../perllib";
use lib "$FindBin::Bin/../../../perllib";

use Test::More tests=>4;

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

sub test_new(){
 
    my $news = NeWs::Paper->new(%fields);
    my $update_coverage = 1;
    my $source = '';
    $news->publish($source, $update_coverage);
    return 1;

}

sub test_update(){
    my $news = NeWs::Paper->new(%fields);
    $news->name('New Test Title');
    my $update_coverage = 0;
    my $source = '';
    $news->publish($source, $update_coverage);
    return 1;

}

sub test_delete(){
    
    my $news = NeWs::Paper->new(%fields);
    my $update_coverage = 0;
    my $source = '';
    $news->isdeleted('t');
    $news->publish($source, $update_coverage);
    return 1;
}

use_ok('NeWs');
ok(test_new() == 1);
ok(test_update() == 1);
ok(test_delete() == 1);
