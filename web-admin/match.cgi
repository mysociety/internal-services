#!/usr/bin/perl -w -I../../perllib -I../mapit-dadem-loading -I ../MaPit
#
# match.cgi
# 
# Interface for providing human input for loading councillor data
# from GovEval.
#
# Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: francis@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: match.cgi,v 1.14 2005-02-02 16:04:13 francis Exp $
#

my $rcsid = ''; $rcsid .= '$Id: match.cgi,v 1.14 2005-02-02 16:04:13 francis Exp $';

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
use mySociety::CouncilMatch;
use mySociety::WatchUpdate;
use mySociety::VotingArea;
use MaPit;
my $W = new mySociety::WatchUpdate();

my $m_dbh = connect_to_mapit_database();
my $d_dbh = connect_to_dadem_database();
mySociety::CouncilMatch::set_db_handles($m_dbh, $d_dbh);
my ($area_id, $name_data, $area_data, $status_data);

sub html_head($$) {
    my ($q, $title) = @_;
    # XXX don't send this here; also, charset should be utf-8
    my $ret = $q->header(-type => 'text/html', -charset => 'iso-8859-1');
    $ret .= <<END;
<html>
<head>
<title>$title - Council Matcher</title>
<style type="text/css"><!--
input { font-size: 9pt; margin: 0px; padding: 0px  }
table { margin: 0px; padding: 0px }
tr { margin: 0px; padding: 0px }
td { margin: 0px; padding: 0px; padding-right: 2pt; }
//--></style>
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
    'url-found' => 'Councillors URL OK',
    'url-missing' => 'Councillors URL needed',
    'councillors-mismatch' => 'Councillors matching failed',
    'councillors-match' => 'Councillors match OK'
};
my $status_titles_order =  
    ['wards-mismatch', 'wards-match', 
    'url-missing', 'url-found',
    'councillors-mismatch', 'councillors-match'];

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
            q#select council_id, status, error from raw_process_status#);
    do { $_->[2] = defined($_->[2]) ? ($_->[2] =~ tr/\n/\n/) : 0 } for @$status_data;
    @$status_data = sort 
        { 
        $a->[2] <=> $b->[2] ||
        $area_id_data->{$a->[0]}->{name} cmp $area_id_data->{$b->[0]}->{name} 
        } 
        @$status_data;
    my $status_data_subset;
    do {
        my $status = $_;
        my @subset = grep { $_->[1] eq $status} @$status_data;
        $status_data_subset->{$status} = \@subset;
    } for @$status_titles_order;

    # Headings linking in
    print $q->table(map { $q->Tr({}, $q->td([
            scalar(@{$status_data_subset->{$_}}),
            $q->a( { href => "#$_" }, $status_titles->{$_} ) ])) }
            grep { @{$status_data_subset->{$_}} } 
            @$status_titles_order);

    # Table of editors
    print $q->h2("Diligency prize league table");
    my $edit_activity = $d_dbh->selectall_arrayref("select count(*) as c, editor from raw_input_data_edited group by editor order by c desc");
    print $q->p(join($q->br(), 
        map { $_->[0] . " edits by " . $_->[1] } @$edit_activity 
    ));

    # For each status type...
    foreach my $status (@$status_titles_order)  {
        # ... find everything of that type
        my @subset = @{$status_data_subset->{$status}};
        next if scalar(@subset) == 0;
        # ... draw a heading
        print $q->h2(
            $q->a({ name => "$status" }, 
            $status_titles->{$status} . " &mdash; " . scalar(@subset) . " total"));

        # ... display everything in it
        print join($q->br(), map { 
                        ($_->[2] > 0 ? $_->[2] . " errors " : "") . 
                        $q->a({   
                                  href => build_url($q, $q->url('relative'=>1), 
                                  {'area_id' => $_->[0], 'page' => 'councilinfo'}) 
                              }, encode_entities($area_id_data->{$_->[0]}->{name}))
                        .  " " . $_->[0] . " " . $_->[1] 
                    } @subset);
    }

    print html_tail($q);
}

# do_council_info CGI 
# Display page with information about just one council.
sub do_council_info ($) {
    my ($q) = @_;

    # Altered URL
    if ($q->param('posted_councillors_url') and $q->param) {
        $d_dbh->do(q#delete
            from raw_council_extradata where council_id = ?#, {}, $area_id);
        $d_dbh->do(q#insert
            into raw_council_extradata (council_id, councillors_url) values (?,?)#, 
            {}, $area_id, $q->param('councillors_url'));
        $d_dbh->commit();
        my $result = mySociety::CouncilMatch::process_ge_data($area_id, 0);
        print $q->redirect($q->param('r'));
        return;
    }
 
    my $name = $name_data->{'name'} .  " " .
        $mySociety::VotingArea::type_name{$area_data->{'type'}};

    print html_head($q, $name . " - Status");
    print $q->h1($name . " " . $area_id . " &mdash; Status");
    print $q->p($status_titles->{$status_data->{status}});

    #print MaPit::get_example_postcode($area_id);

    if ($status_data->{'error'}) {
        print $q->h2("Errors");
        print $q->pre(encode_entities($status_data->{'error'}));
    }

    print $q->h2("Councillor (GE Data)");

    # Google links
    print $q->p(
        $q->a({href => build_url($q, $q->url('relative'=>1), 
              {'area_id' => $area_id, 'page' => 'counciledit', 'r' => $q->self_url()}) }, 
              "Edit this data"),
        " |",
        map { ( $q->a({href => build_url($q, "http://www.google.com/search", 
                    {'q' => "$_"}, 1)},
                  "Google" . ($_ eq "" ? " alone" : " '$_'")),
            " (",
            $q->a({href => build_url($q, "http://www.google.com/search", 
                    {'q' => "$_",'btnI' => "I'm Feeling Lucky"}, 1)},
                  "IFL"),
            ")" ) } ("$name", "$name councillors ward", $name_data->{'name'} . " councillors")
    );

    # Edit box for URL for list of councillors on council website
    my $ret = $d_dbh->selectrow_arrayref(q#select council_id, councillors_url from 
        raw_council_extradata where council_id = ?#, {}, $area_id);
    $q->param('councillors_url', $ret->[1]) if defined ($ret);
    $q->param('r', $q->self_url());
    print $q->start_form(-method => 'POST');
    print $q->p(
            $q->a({href=>$q->param('councillors_url')}, "Councillors page:"),
            $q->textfield(-name => "councillors_url", -size => 100),
            $q->hidden('page', 'councilinfo'),
            $q->hidden('area_id'),
            $q->hidden('r'),
            $q->hidden('posted_councillors_url', 'true'),
            $q->submit('Save')
            );
    print $q->end_form();

    # Show GE list of councillors
    my @reps = mySociety::CouncilMatch::get_raw_data($area_id);
    @reps = sort { $a->{ward_name} cmp $b->{ward_name}  } @reps;
    my $prevward = "";
    my $wards_counter; do { $wards_counter->{$_->{ward_name}} =1 } for @reps;
    my $wards_count = scalar(keys %$wards_counter);
    my $column = 1;
    my $w = 0;
    print $q->start_table(), $q->start_Tr(), $q->start_td();
    foreach my $rep (@reps) {
        if ($rep->{ward_name} ne $prevward) {
            $w++;
            if (($column == 1 && $w > ($wards_count / 3))
            || ($column == 2 && $w > (2 * $wards_count / 3))) {
                print $q->end_td(), $q->start_td();
                $column ++;
            }
            $prevward = $rep->{ward_name};
            print $q->b($rep->{ward_name}), $q->br();
        }
        print $rep->{rep_first} . " " . $rep->{rep_last}, $q->br();
    }
    print $q->end_td(), $q->end_Tr(), $q->end_table();
 
    # Details about matches made
    print $q->h2("Match Details");
    print $q->pre(encode_entities($status_data->{'details'}));

    print html_tail($q);
}

# do_council_edit CGI 
# Form for editing all councillors in a council.
sub do_council_edit ($) {
    my ($q) = @_;
    my $newreptext = "Edit this for new rep";

    if ($q->param('posted')) {
        if ($q->param('Cancel')) {
            print $q->redirect($q->param('r'));
            return;
        }
        
        # Construct complete dataset of council
        my @newdata;
        my $c = 1;
        while ($q->param("key$c")) {
            if ($q->param("ward_name$c")) {
                my $rep;
                foreach my $fieldname qw(key ward_name rep_first rep_last rep_party rep_email rep_fax) {
                    $rep->{$fieldname}= $q->param($fieldname . $c);
                }
                push @newdata, $rep;
            } else { print "MOOOO"; }
            $c++;
        }
        # ... add new ward
        if ($q->param("ward_namenew") ne $newreptext) {
            my $rep;
            foreach my $fieldname qw(key ward_name rep_first rep_last rep_party rep_email rep_fax) {
                $rep->{$fieldname}= $q->param($fieldname . "new");
            }
            push @newdata, $rep;
        }
    
        # Make alteration
        mySociety::CouncilMatch::edit_raw_data($area_id, 
                $name_data->{'name'}, $area_data->{'type'}, $area_data->{'ons_code'},
                \@newdata, $q->remote_user() || "*unknown*");

        # Regenerate stuff
        my $result = mySociety::CouncilMatch::process_ge_data($area_id, 0);

        # Redirect if it's Save and Done
        if ($q->param('Save and Done')) {
            print $q->redirect($q->param('r'));
            return;
        }
    } 
    
    # Fetch data from database
    my @reps = mySociety::CouncilMatch::get_raw_data($area_id);
    my $sort_by = $q->param("sort_by") || "ward_name";
    @reps = sort { $a->{$sort_by} cmp $b->{$sort_by}  } @reps;
    my $c = 1;
    foreach my $rep (@reps) {
        foreach my $fieldname qw(key ward_name rep_first rep_last rep_party rep_email rep_fax) {
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
    print $q->Tr({}, $q->th({}, [map 
        { $_->[1] eq $sort_by ? $_->[0] :
                    $q->a({href=>build_url($q, $q->url('relative'=>1), 
                      {'area_id' => $area_id, 'page' => 'counciledit',
                      'r' => $q->param('r'), 'sort_by' => $_->[1]})}, $_->[0]) 
        } 
        (['Ward (erase to del rep)', 'ward_name'],
        ['First', 'rep_first'],
        ['Last', 'rep_last'],
        ['Party', 'rep_party'],
        ['Email', 'rep_email'],
        ['Fax', 'rep_fax'])
    ]));

    my $printrow = sub {
        my $c = shift;
        print $q->hidden(-name => "key$c", -size => 30);
        print $q->Tr({}, $q->td([ 
            $q->textfield(-name => "ward_name$c", -size => 30),
            $q->textfield(-name => "rep_first$c", -size => 15),
            $q->textfield(-name => "rep_last$c", -size => 15),
            $q->textfield(-name => "rep_party$c", -size => 10),
            $q->textfield(-name => "rep_email$c", -size => 20),
            $q->textfield(-name => "rep_fax$c", -size => 15)
        ]));
    };

    $q->param("ward_namenew", $newreptext);
    &$printrow("new");
    $c = 1;
    while ($q->param("key$c")) {
        &$printrow($c);
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
        $page = "" if !$page;

        $area_id = $q->param('area_id');
        if ($area_id) {
            $name_data = $m_dbh->selectrow_hashref(
                    q#select name from area_name where 
                        area_id = ? and name_type = 'F'#, {}, $area_id);
            $area_data = $m_dbh->selectrow_hashref(
                    q#select * from area where id = ?#, {}, $area_id);
            $status_data = $d_dbh->selectrow_hashref(
                    q#select council_id, status, error, details from raw_process_status
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

