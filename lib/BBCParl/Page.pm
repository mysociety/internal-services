#!/usr/bin/perl
#
# Page.pm:
# Various HTML stuff for the BCI site.
#
# Copyright (c) 2006 UK Citizens Online Democracy. All rights reserved.
# Email: matthew@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: Page.pm,v 1.2 2008-02-02 18:26:06 matthew Exp $
#

package BBCParl::Page;

use strict;
use Carp;
use CGI::Fast qw(-no_xhtml);
use Error qw(:try);
use File::Slurp;
use LWP::Simple;
use POSIX qw(strftime);
use mySociety::Config;
use mySociety::DBHandle qw/select_all/;
use mySociety::EvEl;
use mySociety::WatchUpdate;
use mySociety::Web qw(ent NewURL);
BEGIN {
    mySociety::Config::set_file("$FindBin::Bin/../conf/general");
}

# FastCGI signal handling
my $exit_requested = 0;
my $handling_request = 0;
$SIG{TERM} = $SIG{USR1} = sub {
    $exit_requested = 1;
    # exit(0) unless $handling_request;
};

sub do_fastcgi {
    my $func = shift;

    try {
        my $W = new mySociety::WatchUpdate();
        while (my $q = new CGI::Fast()) {
            $handling_request = 1;
            &$func($q);
            $W->exit_if_changed();
            $handling_request = 0;
            last if $exit_requested;
        }
    } catch Error::Simple with {
        my $E = shift;
        my $msg = sprintf('%s:%d: %s', $E->file(), $E->line(), $E->text());
        warn "caught fatal exception: $msg";
        warn "aborting";
        ent($msg);
        print "Status: 500\nContent-Type: text/html; charset=iso-8859-1\n\n",
                q(<html><head><title>Sorry! Something's gone wrong.</title></head></html>),
                q(<body>),
                q(<h1>Sorry! Something's gone wrong.</h1>),
                q(<p>Please try again later, or <a href="mailto:team@theyworkforyou.com">email us</a> to let us know.</p>),
                q(<hr>),
                q(<p>The text of the error was:</p>),
                qq(<blockquote class="errortext">$msg</blockquote>),
                q(</body></html);
    };
}

1;
