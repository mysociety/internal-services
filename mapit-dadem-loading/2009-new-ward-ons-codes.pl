#!/usr/bin/perl -w -I../perllib -I ../../perllib
#
# 2009-new-ward-ons-codes.pl:
# Input the new ONS codes that we're missing.
#
# Copyright (c) 2009 UK Citizens Online Democracy. All rights reserved.
# Email: matthew@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: 2009-new-ward-ons-codes.pl,v 1.1 2009-12-14 17:02:28 matthew Exp $
#

use strict;
use DBI;
use DBD::Pg;
use Common;

my $dbh = Common::connect_to_mapit_database();

my $db_fetch = $dbh->prepare("select id from area, area_name where id=area_id and name_type='F' and parent_area_id=? and name=? and generation_high>=11");
my $db_parent = $dbh->prepare('select id from area where ons_code=? and generation_high>=11');
my $db_update = $dbh->prepare('update area set ons_code=? where id=?');
my %parents;

open(FP, '2009-new-ward-ons-codes.csv') or die $!;
while (<FP>) {
    chomp;
    my ($code, $name) = split ',', $_, 2;
    my $parent = substr($code, 0, 4);
    unless ($parents{$parent}) {
        $db_parent->execute($parent);
        my $id = $db_parent->fetchrow_array();
        $parents{$parent} = $id;
    }
    $db_fetch->execute($parents{$parent}, $name);
    my $id = $db_fetch->fetchrow_array();
    die "ERROR matching: $code $name $parents{$parent}" unless $id;
    $db_update->execute($code, $id);
}

$dbh->commit();

