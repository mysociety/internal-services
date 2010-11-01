#!/usr/bin/perl
#
# Common.pm:
# Common stuff for data importing.
#
# Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: Common.pm,v 1.26 2010-11-01 17:45:12 matthew Exp $
#

package Common;

use strict;
use CouncilMatch;
use mySociety::Config;
use File::Basename;
my $dirname = dirname(__FILE__);
mySociety::Config::set_file("$dirname/../conf/general");

use DBI;
use IO::File;
use String::Ediff;
use Text::CSV_XS;

@Common::ISA = qw(Exporter);
@Common::EXPORT = qw(
        &connect_to_dadem_database
        &current_generation
        &trim_spaces
        &chomp2
        &read_csv_file
        &move_compass_to_start
        &placename_match_metric
    );

#
# Databasey stuff.
#

# connect_to_dadem_database
# Connect to the DaDem database given in the config file.
sub connect_to_dadem_database () {
    my $host = mySociety::Config::get('DADEM_DB_HOST', undef);
    my $port = mySociety::Config::get('DADEM_DB_PORT', undef);

    my $connstr = 'dbi:Pg:dbname=' . mySociety::Config::get('DADEM_DB_NAME');
    
    $connstr .= ";host=$host" if (defined($host));
    $connstr .= ";port=$port" if (defined($port));
 
    return DBI->connect($connstr,
                        mySociety::Config::get('DADEM_DB_USER'),
                        mySociety::Config::get('DADEM_DB_PASS'),
                        { RaiseError => 1, AutoCommit => 0 });
}


# current_generation DBH
# Return the current generation ID.
sub current_generation ($) {
    my ($dbh) = @_;
    return scalar($dbh->selectrow_array('select id from current_generation'));
}

# read_csv_file FILE [SKIP]
# Return a list (or, in scalar context, a reference to a list) of rows from the
# named CSV FILE. Dies on error. If specified, don't store the first SKIP
# lines.
sub read_csv_file ($;$) {
    my ($f, $skip) = @_;
    $skip ||= 0;
    my $C = new Text::CSV_XS({ binary => 1 });
    my $h;
    if (UNIVERSAL::isa($f, 'IO::Handle')) {
        $h = $f;
        $f = '(handle)';
    } else {
        $h = new IO::File($f, O_RDONLY) or die "$f: $!";
    }
    my @res = ( );
    my $n = 0;
    while (defined($_ = $h->getline())) {
        chomp2($_);
        $C->parse($_) or die "$f: unable to parse '$_'";
        ++$n;
        next if ($n <= $skip);
        push(@res, [ $C->fields() ]);
    }
    die "$f: $!" if ($h->error());
    $h->close();
    if (wantarray()) {
        return @res;
    } else {
        return \@res;
    }
}

#
# String utilities.
#

# chomp2 STRING
# Remove either DOS- or UNIX-style line endings from STRING.
sub chomp2 ($) {
    $_[0] =~ s#\r\n$##s;
    $_[0] =~ s#\n$##s;
    return $_[0];
}

# trim_spaces STRING
# Remove leading and trailing white space from string.
# Can pass by reference or, pass by value and return
sub trim_spaces ($) {
    $_[0] =~ s/\s+$//;
    $_[0] =~ s/^\s+//;
    return $_[0];
}

# placename_match_metric A B
# Return the number of common characters between the strings A and B, once they
# have been stripped of non-alphabetic characters and had any compass
# directions shifted to the beginning of the strings.
sub placename_match_metric ($$) {
    my ($match1, $match2) = @_;

    # First remove non-alphabetic chars
    $match1 =~ s/[^[:alpha:]]//g;
    $match2 =~ s/[^[:alpha:]]//g;
    # Lower case only
    $match1 = lc($match1);
    $match2 = lc($match2);

    # Move compass points to start
    $match1 = CouncilMatch::move_compass_to_start($match1);
    $match2 = CouncilMatch::move_compass_to_start($match2);

    # Then find common substrings
    my $ixes = String::Ediff::ediff($match1, $match2);
    #print " ediff " . $g->{name} . ", " . $d->{name} . "\n";
    #print "  matching $match1, $match2\n";
    my $common_len = 0;
    if ($ixes ne "") {
        my @ix = split(" ", $ixes);
        # Add up length of each common substring
        for (my $i = 0; $i < scalar(@ix); $i+=8) {
            my $common = $ix[$i + 1] - $ix[$i];
            my $common2 = $ix[$i + 5] - $ix[$i + 4];
            die if $common != $common2;

            die if $ix[$i + 2] != 0;
            die if $ix[$i + 3] != 0;

            die if $ix[$i + 6] != 0;
            die if $ix[$i + 7] != 0;

            $common_len += $common;
        }
    }
    # e.g. "Kew" matching "Kew Ward" was too short for ediff
    # to catch, but exact substring matching will find it
    if ($common_len == 0 and index($match1, $match2) >= 0) {
        $common_len = length($match2);
    }
    if ($common_len == 0 and index($match2, $match1) >= 0) {
        $common_len = length($match1);
    }
    return $common_len;
}

1;
