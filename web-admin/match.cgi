#!/usr/bin/perl -w -I../../perllib -I../mapit-dadem-loading
#
# match.cgi
# 
# Interface for providing human input for loading councillor data
# from GovEval.
#
# Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: francis@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: match.cgi,v 1.1 2005-01-21 19:28:14 francis Exp $
#

my $rcsid = ''; $rcsid .= '$Id: match.cgi,v 1.1 2005-01-21 19:28:14 francis Exp $';

use strict;

use CGI::Fast qw(-no_xhtml);
use CGI::Carp;
use HTML::Entities;
use Error qw(:try);
use Data::Dumper;

use Common;
my $m_dbh = connect_to_mapit_database();
my $d_dbh = connect_to_dadem_database();

use mySociety::CouncilMatch;
use mySociety::WatchUpdate;
use mySociety::VotingArea;
my $W = new mySociety::WatchUpdate();

sub html_head($$) {
    my ($q, $title) = @_;
    my $ret = <<END;
Content-Type: text/html; charset=iso-8859-1

<html>
<head>
<title>$title - Council Matcher</title>
</head>
<body>
END
   return $ret . $q->p("Menu:", $q->a( {href=>$q->url()}, "Status Summary")); 
}

sub html_tail($) {
    my ($q) = @_;
    return <<END;
</body>
</html>
END
}

# build_url CGI BASE HASH
# Makes an escaped URL, whose main part is BASE, and
# whose parameters are the key value pairs in the hash.
sub build_url($$$) {
    my ($q, $base, $hash) = @_;
    my $url = $base;
    my $first = 1;
    foreach my $k (keys %$hash) {
        $url .= $first ? '?' : ';';
        $url .= $q->escape($k);
        $url .= "=";
        $url .= $q->escape($hash->{$k});
        $first = 0;
    }
    return $url;
}

my $status_titles = {
    'wards-match' => 'Wards matched OK',
    'wards-mismatch' => 'Ward matching failed',
};


# do_summary CGI
# Displays page with summary of matching status of all councils.
sub do_summary ($) {
    my ($q) = @_;

    print html_head($q, "Status Summary");
    print $q->h1("Status Summary");

    # Cache of area_id->type etc.
    my $area_id_data = $m_dbh->selectall_hashref(
            q#select area_name.name, area.id from area, area_name
                where area_name.area_id = area.id and
                area_name.name_type = 'F' and
                (# . join(' or ', map { "type = '$_'" } @$mySociety::CouncilMatch::parent_types) . q#)#,
            'id');

    # Get status of every council
    my $status_data = $d_dbh->selectall_arrayref(
            q#select council_id, status from raw_process_status#);
    @$status_data = sort 
        { $area_id_data->{$a->[0]}->{name} cmp $area_id_data->{$b->[0]}->{name} } 
        @$status_data;

    foreach my $status (keys %$status_titles)  {
        my @subset = grep { $_->[1] eq $status} @$status_data;
        print $q->h2($status_titles->{$status} . " &mdash; " . scalar(@subset) . " total");
        print join($q->br(), map { 
            $q->a({href=> build_url($q, $q->url('relative'=>1), 
                    {'area_id' => $_->[0], 'page' => 'councilinfo'}) }, 
            $area_id_data->{$_->[0]}->{name}) .
             " " . $_->[1] } @subset);
    }

    print html_tail($q);
}

# do_council_info CGI 
# Display page with information about just one council.
sub do_council_info ($) {
    my ($q) = @_;
    my $area_id = $q->param('area_id');

    my $name_data = $m_dbh->selectrow_hashref(
            q#select name from area_name where 
                area_id = ? and name_type = 'F'#, {}, $area_id);
    my $area_data = $m_dbh->selectrow_hashref(
            q#select * from area where id = ?#, {}, $area_id);
    my $status_data = $d_dbh->selectrow_hashref(
            q#select council_id, status, details from raw_process_status
            where council_id = ?#, {},$area_id);

    my $name = $name_data->{'name'} .  " " . 
        $mySociety::VotingArea::type_name{$area_data->{'type'}};

    print html_head($q, $name . " - Status");
    print $q->h1($name . " &mdash; Status");
    print $q->p($status_titles->{$status_data->{status}});
    print $q->p($q->a({href=> build_url($q, $q->url('relative'=>1), 
                    {'area_id' => $area_id, 'page' => 'counciledit'}) }, 
            "Edit raw input data"));

    print $q->h2("Match Details");
    print $q->pre(encode_entities($status_data->{'details'}));

    print html_tail($q);
}

# do_council_edit CGI 
# Form for editing all councillors in a council.
sub do_council_edit ($) {
    my ($q) = @_;
    my $area_id = $q->param('area_id');

    my $name_data = $m_dbh->selectrow_hashref(
            q#select name from area_name where 
                area_id = ? and name_type = 'F'#, {}, $area_id);
    my $area_data = $m_dbh->selectrow_hashref(
            q#select * from area where id = ?#, {}, $area_id);

    my $name = $name_data->{'name'} .  " " . 
        $mySociety::VotingArea::type_name{$area_data->{'type'}};

    print html_head($q, $name . " - Edit");
    print $q->h1($name . " &mdash; Edit");
    print $q->p($q->a({href=> build_url($q, $q->url('relative'=>1), 
                    {'area_id' => $area_id, 'page' => 'councilinfo'}) }, 
            "View data"));


    my $raw_input_data = $d_dbh->selectall_hashref(
            q#select * from raw_input_data where
            council_id = ?#, 'raw_id', {}, $area_id);
    for my $raw_id (keys %$raw_input_data) {
        my $rep = $raw_input_data->{$raw_id};
        print $q->br();
        #print Dumper($rep);
    }

#    raw_id serial not null primary key,
#    ge_id int not null,
#
#    council_id integer not null,
#    council_name text not null, -- in canonical 'C' form
#    council_type char(3) not null, 
#
#    ward_name text,
#
#    rep_name text,
#    rep_party text,
#    rep_email text,
#    rep_fax text


    print html_tail($q);
}


# Main loop, handles FastCGI requests
my $q;
try {
    while ($q = new CGI::Fast()) {
        $W->exit_if_changed();

        my $page = $q->param('page');

        if ($page eq "councilinfo") {
            do_council_info($q);
        } elsif ($page eq "counciledit") {
            do_council_edit($q);
        } else {
            do_summary($q);
        }
    }
} catch Error::Simple with {
    my $E = shift;
    my $msg = sprintf('%s:%d: %s', $E->file(), $E->line(), $E->text());
    warn "caught fatal exception: $msg";
    warn "aborting";
    encode_entities($msg);
    print "Status: 500\nContent-Type: text/html; charset=iso-8859-1\n\n",
            html_head($q, 'Error'),
            q(<p>Unfortunately, something went wrong. The text of the error
                    was:</p>),
            qq(<blockquote class="errortext">$msg</blockquote>),
            q(<p>Please try again later.),
            html_tail($q);
};

#$dbh->disconnect();

