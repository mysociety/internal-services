#!/usr/bin/perl -w -I../perllib -I../../../perllib
#
# gaze.cgi:
# RABX server.
#
# To run it you need these lines in an Apache config:
#     Options +ExecCGI
#     SetHandler fastcgi-script
#
# Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#

my $rcsid = ''; $rcsid .= '$Id: gaze.cgi,v 1.13 2008-02-02 19:45:54 matthew Exp $';

use strict;

require 5.8.0;

# Do this first of all, because Gaze.pm needs to see the config file.
BEGIN {
    use mySociety::Config;
    mySociety::Config::set_file('../conf/general');
}

use FCGI;
use RABX;

use mySociety::WatchUpdate;

use Gaze;

my $req = FCGI::Request();
my $W = new mySociety::WatchUpdate();

# FastCGI signal handling
my $exit_requested = 0;
my $handling_request = 0;
#$SIG{TERM} = $SIG{USR1} = sub {
#    $exit_requested = 1;
#    # exit(0) unless $handling_request;
#};

use constant cache_age => 86400;

while ($handling_request = ($req->Accept() >= 0)) {
    RABX::Server::CGI::dispatch(
            'Gaze.find_places' => [
                sub { Gaze::find_places($_[0], $_[1], $_[2], $_[3], $_[4]); },
                cache_age
            ],
            'Gaze.get_country_from_ip' => [
                sub { Gaze::get_country_from_ip($_[0]); },
                cache_age
            ],
            'Gaze.get_coords_from_ip' => [
                sub { Gaze::get_coords_from_ip($_[0]); },
                cache_age
            ],
            'Gaze.get_find_places_countries' => [
                sub { Gaze::get_find_places_countries(); },
                cache_age
            ],
            'Gaze.get_country_bounding_coords' => [
                sub { Gaze::get_country_bounding_coords($_[0]); },
                cache_age
            ],
            'Gaze.get_population_density' => [
                sub { Gaze::get_population_density($_[0], $_[1]); },
                cache_age
            ],
            'Gaze.get_radius_containing_population' => [
                sub { Gaze::get_radius_containing_population($_[0], $_[1], $_[2], $_[3]); },
                cache_age
            ],
            'Gaze.get_places_near' => [
                sub { Gaze::get_places_near($_[0], $_[1], $_[2]); },
                cache_age
            ]
        );
    $W->exit_if_changed();
    $handling_request = 0;
    last if $exit_requested;
}
