#!/usr/bin/perl
# 
# FYRQueue.pm:
# Client interface for management of message queue for FYR.

package FYRQueue;

use strict;
use RABX;
use mySociety::Config;

my $rabx_client = undef;
sub configure (;$) {
    my ($url) = @_;
    $url = mySociety::Config::get('FYR_QUEUE_URL') if !defined($url);
    $rabx_client = new RABX::Client($url) or die qq(Bad RABX proxy URL "$url");
}

sub admin_update_recipient ($$$) {
    configure() if !defined $rabx_client;
    return $rabx_client->call('FYR.Queue.admin_update_recipient', @_);
}

1;
