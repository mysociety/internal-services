#!/usr/bin/perl -w
#
# Process.t:
# Tests for BBCParl::Process functions
#
#  Copyright (c) 2009 UK Citizens Online Democracy. All rights reserved.
# Email: louise@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: Process.t,v 1.1 2009-05-26 16:01:57 louise Exp $
#

use strict;
use warnings;

use Test::More tests => 8;

# Horrible boilerplate to set up appropriate library paths.
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../../../perllib";

BEGIN { use_ok('BBCParl::Process'); }

our $process = BBCParl::Process->new();
$process->{'constants'}{'flv-api-url'} = 'http://test.host/';

sub test_get_xml_url{
    
    my $content = q{ flashvars="file=http://test.host/programme/5338218718784707759/pp/flvxml&autostart=true&overstretch=true"};
    my $xml_url = $process->get_xml_url($content);
    my $expected_url = 'http://test.host/programme/5338218718784707759/pp/flvxml';
    ok($xml_url eq $expected_url, 'get_xml_url can correctly extract an xml url from an example');
    
    return 1;
}

sub test_get_flv_url{
    my $content = q{
    <location>/programme/5339962045171534876/download/2006-1243349876-5312514104cf649bd69dd816315c2615/flash.flv</location>
    };
    my $flv_url = $process->get_flv_url($content);
    my $expected_url = 'http://test.host/programme/5339962045171534876/download/2006-1243349876-5312514104cf649bd69dd816315c2615/flash.flv';
    ok($flv_url eq $expected_url, 'get_flv_url can correctly extract an flv url from an example');
    
    return 1;
}

sub test_get_broadcast_date_and_time{

    my $process = BBCParl::Process->new();
    my ($broadcast_date, $broadcast_time) = $process->get_broadcast_date_and_time('2009-05-21 11:15:00');
    ok($broadcast_date eq '2009-05-21', 'get_broadcast_date_and_time gets date correctly from example');
    ok($broadcast_time eq '11-15-00', 'get_broadcast_date_and_time gets time correctly from example');
    
    return 1;
}

ok(test_get_xml_url() == 1, 'Ran all tests for test_get_xml_url');
ok(test_get_flv_url() == 1, 'Ran all tests for test_get_flv_url');
ok(test_get_broadcast_date_and_time() == 1, 'Ran all tests for get_broadcast_date_and_time');
 