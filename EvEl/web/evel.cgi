#!/usr/bin/perl -w -I../perllib -I../../../perllib
#
# evel.cgi:
# RABX server.
#
# To run it you need these lines in an Apache config:
#     Options +ExecCGI
#     SetHandler fastcgi-script
#
# Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#

my $rcsid = ''; $rcsid .= '$Id: evel.cgi,v 1.2 2005-03-30 11:37:16 francis Exp $';

use strict;

require 5.8.0;

use FCGI;
use RABX;

use mySociety::Config;
use mySociety::WatchUpdate;

my $req = FCGI::Request();
my $W = new mySociety::WatchUpdate();

while ($req->Accept() >= 0) {
    RABX::Server::CGI::dispatch(
            'EvEl::send' => sub {
                EvEl::send($_[0], @_[1 .. $#_]);
            },
            'EvEl::is_address_bouncing' => sub {
                return EvEl::is_address_bouncing($_[0]);
            },
            'EvEl::list_create' => sub {
                EvEl::list_create($_[0], $_[1], $_[2], $_[3], $_[4], $_[5]);
            },
            'EvEl::list_destroy' => sub {
                EvEl::list_destroy($_[0], $_[1]);
            },
            'EvEl::list_subscribe' => sub {
                EvEl::list_subscribe($_[0], $_[1], $_[2], $_[3]);
            },
            'EvEl::list_unsubscribe' => sub {
                EvEl::list_unsubscribe($_[0], $_[1], $_[2]);
            },
            'EvEl::list_send' => sub {
                EvEl::list_send($_[0], $_[1], $_[2]);
            }
        );
    last if ($W->changed());
}
