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
# $Id: match.cgi,v 1.34 2006-11-09 10:58:39 matthew Exp $
#

my $rcsid = ''; $rcsid .= '$Id: match.cgi,v 1.34 2006-11-09 10:58:39 matthew Exp $';

use strict;

use CGI::Fast qw(-no_xhtml);
#use CGI::Pretty;
#$CGI::Pretty::AutoloadClass = 'CGI::Fast';
#@CGI::Pretty::ISA = qw( CGI::Fast );

use CGI::Carp;
use HTML::Entities;
use Error qw(:try);
use Data::Dumper;
use POSIX;

use Common;
use CouncilMatch;
use mySociety::WatchUpdate;
use mySociety::VotingArea;
use MaPit;
my $W = new mySociety::WatchUpdate();

my $m_dbh = connect_to_mapit_database();
my $d_dbh = connect_to_dadem_database();
CouncilMatch::set_db_handles($m_dbh, $d_dbh);
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
   $ret .= $q->p("Menu:", $q->a( {href=>$q->url('relative'=>1)}, "Status Summary")); 

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
    'conflicts-none' => 'No conflicts found',
    'conflicts-found' => 'Conflicts found',
    'wards-match' => 'Wards matched OK',
    'wards-mismatch' => 'Ward matching failed',
    'url-found' => 'Councillors URL OK',
    'url-missing' => 'Councillors URL needed',
    'councillors-mismatch' => 'Councillors matching failed',
    'councillors-match' => 'Councillors match OK',
    'failed-live' => 'Failed to make live',
    'made-live' => 'Has refreshed live data',
};
my $status_titles_order =  [
    'conflicts-none', 'conflicts-found',
    'wards-mismatch', 'wards-match', 
    'url-missing', 'url-found',
    'councillors-mismatch', 'councillors-match',
    'failed-live', 'made-live'
];

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
                (# . join(' or ', map { "type = '$_'" } @$mySociety::VotingArea::council_parent_types) . q#)
                and generation_low <= (select id from current_generation) 
                and (select id from current_generation) <= generation_high
                #,
            'id');

    # Get status of every council
    my $status_data = $d_dbh->selectall_arrayref(
            q#select council_id, status, error from raw_process_status#);
    do { $_->[2] = defined($_->[2]) ? ($_->[2] =~ tr/\n/\n/) : 0 } for @$status_data;
    foreach my $a (@$status_data) {
        if (!defined($area_id_data->{$a->[0]})) {
            warn "failed " . $a->[0] . "\n";
        }
    }
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
    if ($q->param('posted_extra_data') and $q->param) {
        $d_dbh->do(q#delete
            from raw_council_extradata where council_id = ?#, {}, $area_id);
        $d_dbh->do(q#insert
            into raw_council_extradata (council_id, councillors_url, make_live) values (?,?,?)#, 
            {}, $area_id, $q->param('councillors_url'), defined($q->param('make_live')) ? 't' : 'f');
        $d_dbh->commit();
        my $result = CouncilMatch::process_ge_data($area_id, 0);
        print $q->redirect($q->param('r'));
        return;
    }
 
    my $name = $name_data->{'name'};
    print html_head($q, $name);
    print $q->h1($name . " " . $area_id);
    print $q->p($status_titles->{$status_data->{status}});

    if ($status_data->{status} eq "made-live") {
        my $example_postcode = MaPit::get_example_postcode($area_id);
        if ($example_postcode) {
            print $q->p("Example postcode to test on WriteToThem.com: ",
                $q->a({href => build_url($q, "http://www.writetothem.com/",
                        { 'pc' => $example_postcode}) }, 
                    $example_postcode));
        }
    }

    if ($status_data->{'error'}) {
        print $q->h2("Errors");
        print $q->pre(encode_entities($status_data->{'error'}));
    }

    print $q->h2("Councillor (GE Data)");

    # Google links
    print $q->p(
        $q->a({href => build_url($q, $q->url('relative'=>1), 
              {'area_id' => $area_id, 'page' => 'counciledit', 'r' => $q->url(-query=>1, -path=>1, -relative=>1)}) }, 
              "Edit councils and wards"),
        " |",
        $q->a({href => build_url($q, $q->url('relative'=>1), 
              {'area_id' => $area_id, 'page' => 'mapitnamesedit', 'r' => $q->url(-query=>1, -path=>1, -relative=>1)}) }, 
              "Edit ward aliases"),
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
    my $ret = $d_dbh->selectrow_arrayref(q#select council_id, councillors_url, make_live from 
        raw_council_extradata where council_id = ?#, {}, $area_id);
    if (defined($ret)) {
        $q->param('councillors_url', $ret->[1]);
        if ($ret->[2]) {
            $q->param('make_live', 'on');
        } else {
            $q->delete('make_live');
        }
    }
    $q->param('r', $q->url(-query=>1, -path=>1, -relative=>1));
    print $q->start_form(-method => 'POST', -action => $q->url('relative'=>1));
    print $q->p(
            $q->b("Make live:"),
            $q->checkbox(-name => 'make_live', -label => ' Copy data to live database when wards match'),
            $q->br(),
            $q->a({href=>$q->param('councillors_url')}, "Councillors page:"),
            $q->textfield(-name => "councillors_url", -size => 100),
            $q->hidden('page', 'councilinfo'),
            $q->hidden('area_id'),
            $q->hidden('r'),
            $q->hidden('posted_extra_data', 'true'),
            $q->br(),
            $q->submit('Save')
            );
    print $q->end_form();

    # Show GE list of councillors
    my @reps = CouncilMatch::get_raw_data($area_id);
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

    # Details about matches made and so on
    print $q->h2("Action Details");
    print $q->pre(encode_entities($status_data->{'details'}));

    # History
    print $q->h2("Change History");
    my @history;
    my @cols = qw#editor key alteration ward_name rep_first rep_last rep_party rep_email rep_fax#;
    my $sth = $d_dbh->prepare(q#select * from raw_input_data where council_id = ?
            order by ward_name#);
    $sth->execute($area_id);
    while (my $row = $sth->fetchrow_hashref()) { 
        $row->{editor} = "imported";
        push @history, $row;
    } 
    $sth = $d_dbh->prepare(q#select * from raw_input_data_edited where council_id = ? 
            order by order_id#);
    $sth->execute($area_id);
    while (my $row = $sth->fetchrow_hashref()) { 
        push @history, $row;
    } 
    print $q->start_table({border=>1});
    print $q->th({}, ["whenedited", @cols]);
    my $prevrow;
    foreach my $row (@history) {
        my $key = $row->{ge_id} ? 'ge_id'.$row->{ge_id} : 'newrow_id'.$row->{newrow_id};
        $row->{key} = $key;
        if ($row->{editor} ne "imported") {
            print $q->start_Tr();
            print $q->td(strftime('%Y-%m-%d %H:%M:%S', localtime($row->{whenedited})));
            foreach my $field (@cols) {
                if ($field ne "editor" and $field ne "alteration" and
                    exists($prevrow->{$key}) and ($prevrow->{$key}->{$field} ne $row->{$field})) 
                {
                    print $q->td( $q->b($row->{$field} || "&nbsp;"), $q->br(), 
                        "(was ".encode_entities($prevrow->{$key}->{$field}).")");
                } elsif ($field eq "alteration" and (!exists($prevrow->{$key})) and $row->{$field} eq 'modify') {
                    # In database, inserts are labelled as "modify", but with new key
                    print $q->td( $q->b("insert") );
                } elsif ($field eq "alteration" and $row->{$field} eq 'delete') {
                    print $q->td( $q->b("delete") );
                } else {
                    print $q->td( encode_entities($row->{$field}) || "&nbsp;");
                }
            }
            print $q->end_Tr();
        }
        if ($row->{alteration} && $row->{alteration} eq "delete") {
            delete $prevrow->{$key};
        } else {
            $prevrow->{$key} = $row;
        }
    }
    print $q->end_table();
 
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
        CouncilMatch::edit_raw_data($area_id, 
                $name_data->{'name'}, $area_data->{'type'}, $area_data->{'ons_code'},
                \@newdata, $q->remote_user() || "*unknown*");
        $d_dbh->commit();

        # Regenerate stuff
        my $result = CouncilMatch::process_ge_data($area_id, 0);

        # Redirect if it's Save and Done
        if ($q->param('Save and Done')) {
            print $q->redirect($q->param('r'));
            return;
        }
    } 
    
    # Fetch data from database
    my @reps = CouncilMatch::get_raw_data($area_id);
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
    my $name = $name_data->{'name'};
    print html_head($q, $name . " - Edit");
    print $q->h1($name . " $area_id &mdash; Edit $reps_count Reps");
    print $q->p($q->b("Note:"), "Data entered here", $q->b("will"), "be
        returned to GovEval (if we ever get round to writing the script).
        Please do not enter information which a councillor wishes to remain
        private.  Leave email and fax blank and the councillor
        will be contacted via Democratic Services.");

    # Large form for editing council details
    print $q->start_form(-method => 'POST', -action => $q->url('relative'=>1));
    print $q->submit('Save and Done'); 
    print $q->submit('Save');
    print "&nbsp;";
    print $q->submit('Cancel');

    print $q->start_table();
    my $r = $q->param('r') || '';
    print $q->Tr({}, $q->th({}, [map 
        { $_->[1] eq $sort_by ? $_->[0] :
                    $q->a({href=>build_url($q, $q->url('relative'=>1), 
                      {'area_id' => $area_id, 'page' => 'counciledit',
                      'r' => $r, 'sort_by' => $_->[1]})}, $_->[0]) 
        } 
        (['Key', 'key'],
        ['Ward (erase to del rep)', 'ward_name'],
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
            $q->param("key$c"),
            $q->textfield(-name => "ward_name$c", -size => 30),
            $q->textfield(-name => "rep_first$c", -size => 15),
            $q->textfield(-name => "rep_last$c", -size => 15),
            $q->textfield(-name => "rep_party$c", -size => 10),
            $q->textfield(-name => "rep_email$c", -size => 20),
            $q->textfield(-name => "rep_fax$c", -size => 15)
        ]));
    };

    $q->param("ward_namenew", $newreptext);
    $q->param("keynew", "");
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

# do_mapit_names_edit CGI 
# Form for editing 'M' (mySociety) aliases for ward names in MaPit.
sub do_mapit_names_edit ($) {
    my ($q) = @_;

    if ($q->param('posted')) {
        if ($q->param('Cancel')) {
            print $q->redirect($q->param('r'));
            return;
        }
        
        my $c = 1;
        while ($q->param("area_id$c")) {
            if ($q->param("m_name$c")) {
                my $affected = $m_dbh->do(q#
                    update area_name set name = ?
                    where area_id = ? and name_type = 'M'#,
                    {}, $q->param("m_name$c"), $q->param("area_id$c"));
                if ($affected == 0) {
                    $m_dbh->do(q#
                        insert into area_name (name, area_id, name_type)
                        values (?, ?, 'M')#,
                        {}, $q->param("m_name$c"), $q->param("area_id$c"));
                }
            } else {
                my $affected = $m_dbh->do(q#
                    delete from area_name 
                    where area_id = ? and name_type = 'M'#,
                    {}, $q->param("area_id$c"));
            }
            $c++;
        }
        $m_dbh->commit();

        # Regenerate stuff
        my $result = CouncilMatch::process_ge_data($area_id, 0);

        # Redirect if it's Save and Done
        if ($q->param('Save and Done')) {
            print $q->redirect($q->param('r'));
            return;
        }
    } 
    
    # Display header
    my $name = $name_data->{'name'};
    print html_head($q, $name . " - Edit");
    print $q->h1($name . " $area_id &mdash; Edit Ward Aliases");
    print $q->p("This edits ward name aliases in MaPit.  Use it for Scottish
        wards which have numbered and normal names. e.g. mapping 'Ward 3' to
        'Port Glasgow South'.");

    # Fetch data from database
    my $os_names = $m_dbh->selectall_hashref(q#
        select area_id, name, name_type from area, area_name where
        area.id = area_name.area_id and parent_area_id = ? and name_type = 'O'
        and generation_low <= (select id from current_generation) and
            (select id from current_generation) <= generation_high
        #, 'area_id', {}, $area_id);
    my $m_names = $m_dbh->selectall_hashref(q#
        select area_id, name, name_type from area, area_name where
        area.id = area_name.area_id and parent_area_id = ? and name_type = 'M'
        and generation_low <= (select id from current_generation) and
            (select id from current_generation) <= generation_high
        #, 'area_id', {}, $area_id);
    
    # Put it in CGI parameters
    my $c = 1;
    foreach my $name (sort { $a->{name} cmp $b->{name} } values %$os_names) {
        $q->param("area_id" . $c, $name->{area_id});
        $q->param("os_name" . $c, $name->{name});
        $q->param("m_name" . $c, $m_names->{$name->{area_id}}->{name});
        $c++;
    }
    my $reps_count = $c-1;

    # Large form for editing ward aliases
    print $q->start_form(-method => 'POST', -action => $q->url('relative'=>1));
    print $q->submit('Save and Done'); 
    print $q->submit('Save');
    print "&nbsp;";
    print $q->submit('Cancel');

    print $q->start_table();
    print $q->Tr({}, $q->th({}, [ 'OS Name', 'mySociety Name' ]));

    my $printrow = sub {
        my $c = shift;
        print $q->hidden(-name => "area_id$c", -size => 30);
        print $q->Tr({}, $q->td([ 
            encode_entities($q->param("os_name$c")),
            $q->textfield(-name => "m_name$c", -size => 40),
        ]));
    };
    $c = 1;
    while ($q->param("area_id$c")) {
        &$printrow($c);
        $c++;
    }
    
    print $q->end_table();
    print $q->hidden('page', 'mapitnamesedit');
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
        } elsif ($page eq "mapitnamesedit") {
            do_mapit_names_edit($q);
        } else {
            do_summary($q);
        }

        $W->exit_if_changed();
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

