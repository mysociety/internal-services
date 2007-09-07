#!/usr/bin/perl -w

use strict;

# Horrible boilerplate to set up appropriate library paths.
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../perllib";

use Getopt::Long;
use CGI;
use BBCParl::Web;

use BBCParl::Page;
use mySociety::Config;
use mySociety::DBHandle qw (dbh);
use mySociety::Util qw(print_log);

BEGIN {
    mySociety::Config::set_file("$FindBin::Bin/../conf/general");

      mySociety::DBHandle::configure(
				     Name => mySociety::Config::get('BBC_DB_NAME'),
				     User => mySociety::Config::get('BBC_DB_USER'),
				     Password => mySociety::Config::get('BBC_DB_PASS'),
				     Host => mySociety::Config::get('BBC_DB_HOST', undef),
				     Port => mySociety::Config::get('BBC_DB_PORT', undef)
				     );
  }

sub main {
    my ($q) = @_;
    my $object = BBCParl::Web->new($q);
    $object->{'debug'} = undef;
    $object->{'disable-cache'} = undef;
    $object->process_request();
}

# Start FastCGI
BBCParl::Page::do_fastcgi(\&main);

exit(0);
