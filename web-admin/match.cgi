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
# $Id: match.cgi,v 1.3 2005-01-26 19:48:52 francis Exp $
#

my $rcsid = ''; $rcsid .= '$Id: match.cgi,v 1.3 2005-01-26 19:48:52 francis Exp $';

use strict;

use CGI::Fast qw(-no_xhtml);
#use CGI::Pretty;
#$CGI::Pretty::AutoloadClass = 'CGI::Fast';
#@CGI::Pretty::ISA = qw( CGI::Fast );

use CGI::Carp;
use HTML::Entities;
use Error qw(:try);
use Data::Dumper;

use Common;
my $m_dbh = connect_to_mapit_database();
my $d_dbh = connect_to_dadem_database();
my ($area_id, $name_data, $area_data, $status_data);

use mySociety::CouncilMatch;
use mySociety::WatchUpdate;
use mySociety::VotingArea;
my $W = new mySociety::WatchUpdate();

sub html_head($$) {
    my ($q, $title) = @_;
    my $ret = $q->header(type=>'text/html', charset=>'iso-8859-1');
    $ret .= <<END;
<html>
<head>
<title>$title - Council Matcher</title>
</head>
<body>
END
   $ret .= $q->p("Menu:", $q->a( {href=>$q->url()}, "Status Summary")); 

   return $ret;
}

sub html_tail($) {
    my ($q) = @_;
    return <<END;
</body>
</html>
END
}

# build_url CGI BASE HASH AMPERSAND
# Makes an escaped URL, whose main part is BASE, and
# whose parameters are the key value pairs in the hash.
# AMPERSAND is optional, set to 1 to use & rather than ;.
sub build_url($$$;$) {
    my ($q, $base, $hash, $ampersand) = @_;
    my $url = $base;
    my $first = 1;
    foreach my $k (keys %$hash) {
        $url .= $first ? '?' : ($ampersand ? '&' : ';');
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

    # Headings linking in
    print join($q->br(), map { 
            $q->a( { href => "#$_" }, $status_titles->{$_} ) }
            keys %$status_titles);

    # For each status type...
    foreach my $status (keys %$status_titles)  {
        # ... find everything of that type
        my @subset = grep { $_->[1] eq $status} @$status_data;
        # ... draw a heading
        print $q->h2(
            $q->a({ name => "$status" }, 
            $status_titles->{$status} . " &mdash; " . scalar(@subset) . " total"));

        # ... display everything in it
        print join($q->br(), map { 
                        $q->a({   
                                  href => build_url($q, $q->url('relative'=>1), 
                                  {'area_id' => $_->[0], 'page' => 'councilinfo'}) 
                              }, encode_entities($area_id_data->{$_->[0]}->{name}))
                        .  " " . $_->[1] 
                    } @subset);
    }

    print html_tail($q);
}

# do_council_info CGI 
# Display page with information about just one council.
sub do_council_info ($) {
    my ($q) = @_;

    my $name = $name_data->{'name'} .  " " .
        $mySociety::VotingArea::type_name{$area_data->{'type'}};

    print html_head($q, $name . " - Status");
    print $q->h1($name . " " . $area_id . " &mdash; Status");
    print $q->p($status_titles->{$status_data->{status}});

    my $iflquery = $name . " councillors ward";
    print $q->p(
        $q->a({href => build_url($q, $q->url('relative'=>1), 
              {'area_id' => $area_id, 'page' => 'counciledit', 'r' => $q->self_url()}) }, 
              "Edit raw input data"),
        " | ",
        $q->a({href => build_url($q, "http://www.google.com/search", 
                {'q' => $iflquery,'NOTbtnI' => "I'm Feeling Lucky"}, 1)},
              "IFL $iflquery")
    );

    print $q->h2("Match Details");
    print $q->pre(encode_entities($status_data->{'details'}));

    print html_tail($q);
}

# do_council_edit CGI 
# Form for editing all councillors in a council.
sub do_council_edit ($) {
    my ($q) = @_;

    if ($q->param('posted')) {
        if ($q->param('Cancel')) {
            print $q->redirect($q->param('r'));
            return;
        }
        
        # Construct complete dataset of council
        my @newdata;
        my $c = 1;
        while ($q->param("key$c")) {
            my $rep;
            foreach my $fieldname qw(key ward_name rep_name rep_party rep_email rep_fax) {
                $rep->{$fieldname}= $q->param($fieldname . $c);
            }
            push @newdata, $rep;
            $c++;
        }
    
        # Make alteration
        mySociety::CouncilMatch::edit_raw_data($area_id, 
                $name_data->{'name'}, $area_data->{'type'},
                $d_dbh, \@newdata, $q->remote_user() || "*unknown*");

        # Regenerate stuff
        my $result = mySociety::CouncilMatch::match_council_wards($area_id, 0, $m_dbh, $d_dbh);

        # Redirect if it's Save and Done
        if ($q->param('Save and Done')) {
            print $q->redirect($q->param('r'));
            return;
        }
    } 
    
    # Fetch data from database
    my @reps = mySociety::CouncilMatch::get_raw_data($area_id, $d_dbh);
    @reps = sort { $a->{ward_name} cmp $b->{ward_name}  } @reps;
    my $c = 1;
    foreach my $rep (@reps) {
        foreach my $fieldname qw(key ward_name rep_name rep_party rep_email rep_fax) {
            $q->param($fieldname . $c, $rep->{$fieldname});
        }
        $c++;
    }
    $q->delete("key$c");
    my $reps_count = $c-1;

    # Display header
    my $name = $name_data->{'name'} .  " " . 
        $mySociety::VotingArea::type_name{$area_data->{'type'}};
    print html_head($q, $name . " - Edit");
    print $q->h1($name . " $area_id &mdash; Edit $reps_count Reps");

    # Large form for editing council details
    print $q->start_form(-method => 'POST');
    print $q->submit('Save and Done'); 
    print $q->submit('Save');
    print "&nbsp;";
    print $q->submit('Cancel');

    print $q->start_table();
    print $q->Tr({}, $q->th({}, [
        'Ward', 'Name', 'Party', 'Email', 'Fax'                
    ]));

    $c = 1;
    while ($q->param("key$c")) {
        print $q->hidden(-name => "key$c", -size => 30);
        print $q->Tr({}, $q->td([ 
            $q->textfield(-name => "ward_name$c", -size => 30),
            $q->textfield(-name => "rep_name$c", -size => 20),
            $q->textfield(-name => "rep_party$c", -size => 10),
            $q->textfield(-name => "rep_email$c", -size => 20),
            $q->textfield(-name => "rep_fax$c", -size => 15)
        ]));
        $c++;
    }
    
    print $q->end_table();
    print $q->hidden('page', 'counciledit');
    print $q->hidden('area_id');
    print $q->hidden('r');
    print $q->hidden('posted', 'true');

    print $q->submit('Save and Done'); 
    print $q->submit('Save');
    print "&nbsp;";
    print $q->submit('Cancel');
    print $q->end_form();

    print html_tail($q);
}

# Main loop, handles FastCGI requests
my $q;
try {
    while ($q = new CGI::Fast()) {
        $W->exit_if_changed();
        #print Dumper($q->Vars);

        my $page = $q->param('page');

        $area_id = $q->param('area_id');
        if ($area_id) {
            $name_data = $m_dbh->selectrow_hashref(
                    q#select name from area_name where 
                        area_id = ? and name_type = 'F'#, {}, $area_id);
            $area_data = $m_dbh->selectrow_hashref(
                    q#select * from area where id = ?#, {}, $area_id);
            $status_data = $d_dbh->selectrow_hashref(
                    q#select council_id, status, details from raw_process_status
                    where council_id = ?#, {},$area_id);
        }

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

