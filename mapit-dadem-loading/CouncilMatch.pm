#!/usr/bin/perl
#
# CouncilMatch.pm:
# 
# Code related to matching/fixing OS and GE data for councils.
#
# Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: francis@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: CouncilMatch.pm,v 1.7 2006-02-08 10:15:01 francis Exp $
#

package CouncilMatch;

use Data::Dumper;
use LWP::Simple;
use HTML::TokeParser;
use Text::CSV;
use URI;
use File::Slurp;

use mySociety::StringUtils qw(trim merge_spaces);

our ($d_dbh, $m_dbh);
# set_db_handles MAPID_DB DADEM_DB
# Call first with DB handles to use for other functions.
sub set_db_handles($$) {
    $m_dbh = shift;
    $d_dbh = shift;
}

# process_ge_data COUNCIL_ID VERBOSITY 
# Performs next step(s) in processing on GE data.  Returns
# hashref containing 'details' and 'error' should you need it,
# but that is also saved in raw_process_status.
sub process_ge_data ($$) {
    my ($area_id, $verbosity) = @_;
    my ($status, $error, $details);
    $details = "";

    # Check for CONFLICT markers
    my $ret = find_conflicts($area_id, $verbosity);
    $status = $ret->{error} ? 'conflicts-found' : 'conflicts-none';
    $error .= $ret->{error} ? $ret->{error} : "";
    $details = $ret->{details} . "\n" . $details;

    # Match up wards
    if ($status eq "conflicts-none") {
        my $ret = match_council_wards($area_id, $verbosity);
        $status = $ret->{error} ? 'wards-mismatch' : 'wards-match';
        $error .= $ret->{error} ? $ret->{error} : "";
        $details .= $ret->{details} . "\n" . $details;
    }

    # Get any extra data
    my $extra_data = get_extradata($area_id);

    # Disable attempt at matching against council website for now
=comment
    # See if we have URL
    if ($status eq "wards-match") {
        my $found = ($extra_data and $extra_data->{councillors_url} ne "");
        $status = $found ? "url-found" : "url-missing";

        # Check against council website
        if ($status eq 'url-found') {
            my $ret = check_councillors_against_website($area_id, $verbosity);
            $status = $ret->{error} ? 'councillors-mismatch' : 'councillors-match';
            $error .= $ret->{error} ? $ret->{error} : "";
            $details = $ret->{details} . "\n" . $details;
        }
    }
=cut

    # Make live
    if ($status eq "wards-match" and $extra_data and $extra_data->{make_live}) {
        my $ret = refresh_live_data($area_id, $verbosity);
        $status = $ret->{error} ? 'failed-live' : 'made-live';
        $error .= $ret->{error} ? $ret->{error} : "";
        $details = $ret->{details} . "\n" . $details;
    } 

    # Save status
    set_process_status($area_id, $status, $error ? $error : undef, $details);
    $d_dbh->commit();

    return { 'details' => $details, 
             'error' => $error };
}

# refresh_live_data COUNCIL_ID VERBOSITY 
# Attempts to match up the wards from the raw_input_data table to the Ordnance
# Survey names. Returns hash ref containing 'details' and 'error'.
sub refresh_live_data($$) {
    my ($area_id, $verbose) = @_;
    print "refresh_live_data council " . $area_id . "\n" if $verbose;
    my $details = "";
    my $error = "";

    # Get updated data from raw table
    my @raw = CouncilMatch::get_raw_data($area_id);
    my $update_keys;
    my $ward_ids;
    # ... name match to fill in ward id, and contact type
    foreach $row (@raw) {
        # ... get ward id
        my $name_matches = $m_dbh->selectall_arrayref(q#select area_id, type 
            from area_name, area where area_name.area_id = area.id and
            name_type = 'G' and name = ?  and parent_area_id = ?
            and generation_low <= (select id from current_generation) and
                (select id from current_generation) <= generation_high
            #, {}, 
            $row->{ward_name}, $area_id);
        if (scalar(@$name_matches) != 1) {
            # This should never happen, as we have matched ward names before running this
            throw Error::Simple("refresh_live_data: Didn't get right number of name matches, got "
                . scalar(@$name_matches) . " for '" . $row->{ward_name} . "'");
        }
        $row->{ward_id} = $name_matches->[0]->[0];
        $row->{ward_type} = $name_matches->[0]->[1];
        $ward_ids->{$row->{ward_id}} = 1;

        # ... calculate method
        my $method = 'via';
        if ($row->{rep_fax} and $row->{rep_email}) {
            $method = 'either';
        } elsif ($row->{rep_fax}) {
            $method = 'fax';
        } elsif ($row->{rep_email}) {
            $method = 'email';
        }
        $row->{method} = $method;

        # ... store keys in hash
        $update_keys->{$row->{key}} = $row;
    }

    # Get any existing data from representatives table
    my $ward_list = join(",", map { '?' } keys %$ward_ids);
    my $current_by_id = $d_dbh->selectall_hashref(q#select * from representative
        where area_id in (# . $ward_list .  q#)#, 'id',
        {}, keys %$ward_ids);
    my $current_keys;
    foreach $curr (values %$current_by_id) {
        throw Error::Simple("refresh_live_data: Existing data does not have import key for rep id " . $curr->{id}) if (!defined($curr->{import_key}));
        throw Error::Simple("refresh_live_data: Existing data has duplicate key $curr->{import_key}") if exists($current_keys->{$curr->{import_key}});
        $current_keys->{$curr->{import_key}} = $curr;
    }

    # Go through all updated data, and either insert or replace
    foreach $update_key (keys %$update_keys) {
        my $row = $update_keys->{$update_key};
        if (exists($current_keys->{$update_key})) {
            # update
            my $rows_affected = $d_dbh->do(q#update representative set
                area_id = ?, area_type = ?,
                name = ?, party = ?, method = ?, email = ?, fax = ?
                where import_key = ? and area_id in (# . $ward_list . q#)#, {}, 
                $row->{ward_id}, $row->{ward_type},
                $row->{rep_first} . " " . $row->{rep_last},
                $row->{rep_party}, $row->{method}, 
                $row->{rep_email}, $row->{rep_fax},
                $update_key, keys %$ward_ids);
            throw Error::Simple("refresh_live_data: update of $update_key, $row->{ward_id} affected $rows_affected rows, not one") if $rows_affected != 1;
            $details .= "Making live: Updated $update_key to " . $row->{ward_id} . " "
                .$row->{rep_first}." ".$row->{rep_last}
                . " (" . $row->{rep_party} . ")"
                . " method: " . $row->{method}
                . " fax: " . $row->{rep_fax} . " email: " . $row->{rep_email} 
                . "\n";
        } else {
            # insert into
            $d_dbh->do(q#insert into representative 
                (area_id, area_type, name, party, method, email, fax, import_key, whencreated) 
                values (?, ?, ?, ?, ?, ?, ?, ?, ?)#, {}, 
                $row->{ward_id}, $row->{ward_type},
                $row->{rep_first} . " " . $row->{rep_last},
                $row->{rep_party}, $row->{method}, 
                $row->{rep_email}, $row->{rep_fax},
                $update_key, time());
            $details .= "Making live: Inserted $update_key ".$row->{rep_first}." ".$row->{rep_last}
                . " (" . $row->{rep_party} . ")"
                . " method: " . $row->{method}
                . " fax: " . $row->{rep_fax} . " email: " . $row->{rep_email} 
                . "\n";

        }
    }

    # Delete any representative data which is no longer present
    foreach $current_key (keys %$current_keys) {
        my $current_row = $current_keys->{$current_key};
        # Data is in representative table, but not in new data, so delete
        if (!exists($update_keys->{$current_key})) {
            my $rows_affected = $d_dbh->do(q#delete from representative where import_key = ?
                and area_id in (# . $ward_list . q#)#, {}, 
                $current_key, keys %$ward_ids
                );
            throw Error::Simple("refresh_live_data: delete affected $rows_affected rows, not one for key $current_key") if $rows_affected != 1;
            $details .= "Making live: Deleted $current_key ".$current_row->{name}."\n";
        }
    }

    return { 'details' => $details, 'error' => $error };
}

# find_conflicts COUNCIL_ID VERBOSITY 
# Looks for CONFLICT in any field, which indicates that a field had conflict during merge.
sub find_conflicts($$) {
    my ($area_id, $verbose) = @_;
    print "checking for conflicts council " . $area_id . "\n" if $verbose;
    my $details = "";
    my $error = "";

    # Get updated data from raw table
    my @raw = CouncilMatch::get_raw_data($area_id);
    # ... find any CONFLICT
    foreach my $row (@raw) {
        foreach my $field (keys %$row) {
            my $value = $row->{$field};
            if ($value && $value =~ m/CONFLICT/) {
                $error .= "Found conflict in field $field: $value\n";
            }
        }
    }
    return { 'details' => $details, 'error' => $error };
}
 
# get_process_status COUNCIL_ID
# Returns the text string saying what state of GE data processing
# the council is in.
sub get_process_status ($) {
    my ($area_id) = @_;
    my $ret = $d_dbh->selectrow_arrayref(q#select status from raw_process_status 
        where council_id = ?#, {}, $area_id);
    if (!defined($ret)) {
        return "";
    }
    return $ret->[0];
}

# set_process_status COUNCIL_ID STATUS ERROR DETAILS
# Alter processing status for a council.
sub set_process_status ($$$$) {
    my ($area_id, $status, $error, $details) = @_;

    $d_dbh->do(q#delete from raw_process_status where council_id=?#, {}, $area_id);
    $d_dbh->do(q#insert into raw_process_status (council_id, status, error, details)
        values (?,?,?,?)#, {}, $area_id, $status, $error, $details);
}

# move_compass_to_start STRING
# Move compass directions (North, South, East, West, Central) to start of string
# and to have that order.  Requires a lowercase string, and ignores
# spaces.
sub move_compass_to_start {
    my ($match) = @_;

    # Move compass points to start
    my $compass = "";
    foreach my $dir ("north", "south", "east", "west", "central") {
        while ($match =~ m/($dir)/) {
            $match =~ s/^(.*)($dir)(.*)$/$1$3/;
            $compass .= "$dir";
        }
    }
    return $compass . $match;
}

# canonicalise_constituency_name NAME
# Convert the NAME of a constituency (all voting areas except councils,
# basically) into a "canonical" version of the name. That is, one with all the
# parts which often vary between spellings reduced to the simplest form. This
# simple form can then be used with exact matching.
sub canonicalise_constituency_name ($) {
    $_ = shift;

    # Europe regions
    s#^Greater ##i;
    s# Euro Region$##;
    s#N\. Ireland#Northern Ireland#;

    # Westminster constituencies
    s# Burgh Const$##;
    s# Co Const$##;
    s# Boro Const$##;
    s# The$##;
    s#^The##;
    s# City of$##;
    s#^City of##;
    s#ô#o#g;

    # Scottish constituencies/electoral regions
    s#Orkney Islands#Orkney#;
    s#Shetland Islands#Shetland#;
    s# P Const$##;
    s# PER$##;
    s# Region$##;
    s# P$##;    # ?
    s#N\. #North #;
    s#E\. #East #;
    s#S\. #South #;
    s#W\. #West #;

    # Welsh Assembly 
    s# Assembly ER$##;
    s# Assembly Const$##;
    s#^Brecon & Radnor$#Brecon & Radnorshire#;

    # London Assembly
    s# London$##;
    s# GL$##;

    # General
    $_ = lc;
    s#&# and #g;
    s#/# and #g;
    s#-# #g;
    s#'##g;
    s#,##g;
    s#\.##g;
    s#\s+##g; # Squash all spaces
    $_ = move_compass_to_start($_);

    return $_;
}


# canonicalise_council_name NAME
# Convert the NAME of a council into a "canonical" version of the name.
# That is, one with all the parts which often vary between spellings
# reduced to the simplest form.  e.g. Removing the word "Council" and
# punctuation.
sub canonicalise_council_name ($) {
    $_ = shift;

    if (m/^Durham /) {
        # Durham County and Durham District both have same name (Durham)
        # so we leave in the type (County/District) as a special case
        s# City Council# District#;
        s# County Council# County#;
    } else {
        s#\s*\(([A-Z]{2})\)##; # Pendle (BC) => Pendle
        s#(.+) - (.+)#$2#;     # Sir y Fflint - Flintshire => Flintshire

        s#^City and County of ##;         # City and County of the City of London => the City of London
        s#^The ##i;
        s# City Council$##;    # OS say "District", GovEval say "City Council", we drop both to match
        s# County Council$##;  # OS say "District", GovEval say "City Council", we drop both to match
        s# Borough Council$##; # Stafford Borough Council => Stafford
        s# Council$##;         # Medway Council => Medway
        s# City$##;            # Liverpool City => Liverpool
        s#^City of ##;         # City of Glasgow => Glasgow
        s#^County of ##;
        s#^Corp of ##;         # Corp of London => London
        s# District$##;
        s# County$##;
        s# City$##;
        s# London Boro$##;

        s#sh'r$#shire#;       # Renfrewsh'r => Renfrewshire
        s#W\. Isles#Na H-Eileanan an Iar#;    # Scots Gaelic(?) name for Western Isles
        s#^Blackburn$#Blackburn with Darwen#;

        s#\bN\.\s#North #g;    # N. Warwickshire => North Warwickshire
        s#\bS\.\s#South #g;    # S. Oxfordshire => South Oxfordshire
        s#\bE\.\s#East #g;     # North E. Derbyshire => North East Derbyshire
        s#\bW\.\s#West #g;     # W. Sussex => West Sussex
        s#\bGt\.\s#Great #g;   # Gt. Yarmouth => Great Yarmouth

        s#[&/-]# #g;
        s#\band\b# #g;
        s#[[:punct:]]##g;

        $_ = merge_spaces($_);
        $_ = trim($_);
    }
   
    $_ = lc;
    return $_;
}

my $nickmap;

# match_modulo_nickname NAMEA NAMEB NICKNAMEFILE
# Sees if two names match, allowing for nickname.  Each name must be in form
# "firstname initials othernames", all lowercase.  e.g. "timmy tailor" would
# match "timothy tailor".  Returns 1 if match, 0 otherwise.  NAMEA can
# have extra stuff at the end (i.e. we look for NAMEB inside NAMEA).
# NICKNAMEFILE points to mapit-dadem-loading/nicknames/nicknames.csv
sub match_modulo_nickname($$$) {
    my ($a, $b, $nicknamefile) = @_;

    if (!defined($nickmap)) {
        # Load in nickname data
        my $csv_parser = new Text::CSV;
        open NICKNAMES, "<$nicknamefile" or die "couldn't find nicknames.csv file";
        <NICKNAMES>; # heading
        while (my $line = <NICKNAMES>) {
            chomp($line);
            $csv_parser->parse($line);
            my ($nick, $canon) = map { trim($_) } $csv_parser->fields();
            push @{$nickmap->{lc($nick)}}, lc($canon);
        }
    }

    my (@a, @b);
    my ($afirst, $arest) = ($a =~ m/^([^ ]*) (.*)$/);
    my ($bfirst, $brest) = ($b =~ m/^([^ ]*) (.*)$/);
    return 0 if (!defined($arest) || !defined($brest) || !defined($afirst) || !defined($bfirst));
    return 0 if ($arest !~ m/\b$brest\b/);
    return 1 if ($afirst eq $bfirst);
    my %anames = ($afirst => 1);
    my %bnames = ($bfirst => 1);
    do { $anames{$_} = 1 } for @{$nickmap->{$afirst}};
    do { $bnames{$_} = 1 } for @{$nickmap->{$bfirst}};
    #print "$afirst-$arest, $bfirst-$brest\n";
    #print Dumper(\%anames);
    #print Dumper(\%bnames);
    foreach $_ (keys %anames) {
        return 1 if (exists($bnames{$_}));
    }
    return 0;
}

# canonicalise_person_name NAME
# Convert name from various formats "Fred Smith", "Smith, Fred",
# "Fred R Smith", "Smith, Fred RK" to uniform one "fred smith".  Removes
# initials except first one if there is no first name, puts surname last,
# lowercases.
sub canonicalise_person_name ($) {
    ($_) = @_;

    # Remove fancy words
    my $titles = "Cllr|Councillor|Dr|Hon|hon|rah|rh|Mrs|Ms|Mr|Miss|Rt Hon|Reverend|The Rev|The Reverend|Sir|Dame|Rev|Prof";
    my $honourifics = "MP|CBE|OBE|MBE|QC|BEM|rh|RH|Esq|QPM|JP|FSA|Bt|BEd|Hons|TD|MA|QHP|DL|CMG|BB|AKC|Bsc|Econ|LLB|GBE|QSO|BA|FRSA|FCA|DD|KBE|PhD";
    while (s#(\b(?:$titles)\b)##) {};
    while (s#(\b(?:$honourifics)\b)##) {};

    # Sometimes usefully match names in emails, so strip all
    s#\@.*$##; 

    # Swap Lastname, Firstname
    s/^([^,]+),([^,]+)$/$2 $1/;  

    # Clear up spaces and punctuation
    s#[[:punct:]]# #g;
    $_ = trim($_);
    $_ = merge_spaces($_);

    # Split up initials unspaced 
    s/\b([[:upper:]])([[:upper:]])\b/$1 $2/g;
    # Remove initials apart from first name/initial
    s/\b(\S+ )((?:[[:upper:]] )+)/$1/;

    # Remove case
    $_ = lc($_);

    return $_;
}

# canonicalise_ward_name WARD
# Returns Ward name with extra suffixes (e.g. Ward) removed, and in lowercase.
sub canonicalise_ward_name ($) {
    ($_) = @_;
    s# ED\b.*$##;
    s# Ward\b.*$##;
    return CouncilMatch::canonicalise_council_name($_);
}

# Internal use
# get_extradata COUNCIL_ID 
# Checks we have the councillor names webpage URL, and any other needed data.
sub get_extradata ($) {
    my ($area_id) = @_;
    my $ret = $d_dbh->selectrow_hashref(q#select council_id, councillors_url, make_live from 
        raw_council_extradata where council_id = ?#, {}, $area_id);
    return $ret;
}
 
# Internal use
# match_council_wards COUNCIL_ID VERBOSITY 
# Attempts to match up the wards from the raw_input_data table to the Ordnance
# Survey names. Returns hash ref containing 'details' and 'error'.
sub match_council_wards ($$) {
    my ($area_id, $verbosity) = @_;
    print "Area: $area_id\n" if $verbosity > 0;
    my $error = "";

    # Set of wards GovEval have
    my @raw_data = get_raw_data($area_id);
    # ... find unique set
    my %wards_hash;
    do { $wards_hash{$_->{'ward_name'}} = 1 } for @raw_data;
    my @wards_array = keys(%wards_hash);
    # ... store in special format
    my $wards_goveval = [];
    do { push @{$wards_goveval}, { name => $_} } for @wards_array;

    # Set of wards already in database (from Ordnance Survey / ONS / mySociety / legislation)
    my $rows = $m_dbh->selectall_arrayref(q#
        select distinct on (area_id) area_id, name,
        case when name_type = 'M' then 0 else 1 end as o
        from area_name, area where
        area_name.area_id = area.id and parent_area_id = ? and 
        (name_type = 'O' or name_type = 'S' or name_type = 'M' or name_type = 'L') and
        (# . join(' or ', map { "type = '$_'" } @$mySociety::VotingArea::council_child_types) . q#) 
        and generation_low <= (select id from current_generation) and
            (select id from current_generation) <= generation_high
        order by area_id, o
        #, {}, $area_id);
    my $wards_database = [];
    foreach my $row (@$rows) { 
        my ($area_id, $name) = @$row;
        push @{$wards_database}, { name => $name, id => $area_id };
    }
    
    @$wards_database = sort { $a->{name} cmp $b->{name} } @$wards_database;
    @$wards_goveval = sort { $a->{name} cmp $b->{name} } @$wards_goveval;

    my $dump_wards = sub {
        $ret = "";
        $ret .= sprintf "%38s => %-38s\n", 'Ward Matches Made: GovEval', 'OS/ONS/mySociety Name (mySociety ID)';
        $ret .= sprintf "-" x 38 . ' '. "-" x 38 . "\n";

        foreach my $g (@$wards_goveval) {
            if (exists($g->{matches})) {
                $first = 1;
                foreach my $d (@{$g->{matches}}) {
                    $ret .= sprintf "%38s => %-38s\n", $first ? $g->{name} : "", $d->{name} . " (" . $d->{id}.")";
                    $first = 0;
                    $d->{referred} = 1;
                }
            }
        }

        $first = 1;
        foreach my $d (@$wards_database) {
            if (!exists($d->{referred})) {
                if ($first) {
                    $ret .= sprintf "\n%38s\n", "Other Database wards:";
                    $ret .= sprintf "-" x 80 . "\n";
                    $first = 0;
                }
                $ret .= sprintf "%38s\n", $d->{id} . " " . $d->{name};
            }
        }
        $first = 1;
        foreach my $g (@$wards_goveval) {
            if (!exists($g->{matches})) {
                if ($first) {
                    $ret .= sprintf "\n%38s\n", "Other GovEval wards:";
                    $ret .= sprintf "-" x 80 . "\n";
                    $first = 0;
                }
                $ret .= sprintf "%38s\n", $g->{name};
            }
        }
        $ret .= "\n";
        return $ret;
    };

    if (@$wards_goveval != @$wards_database) {
        # Different numbers of wards by textual name.
        # This will happen due to different spellings, the
        # below fixes it up if it can.
    }
 
    # Work out area_id for each GovEval ward
    foreach my $g (@$wards_goveval) {
        # Find the entry in database which best matches each GovEval
        # name, store multiple same-length ties.
        my $longest_len = -1;
        my $longest_matches = undef;
        foreach my $d (@$wards_database) {
            my $match1 = $g->{name};
            my $match2 = $d->{name};
            my $common_len = Common::placename_match_metric($match1, $match2);
          
            # If more common characters, store it
            if ($common_len > $longest_len) {
                $longest_len = $common_len;
                $longest_matches = undef;
                push @{$longest_matches}, $d;
            } elsif ($common_len == $longest_len) {
                push @{$longest_matches}, $d;
            }
        }

        # Longest len
        if ($longest_len < 3) {
            $error .= "${area_id}: Couldn't find match in database for GovEval ward " .  $g->{name} . " (longest common substring < 3)\n";
        } else {
            # Record the best ones
            $g->{matches} = $longest_matches;
            #print Dumper($longest_matches);
            # If exactly one match, use it for definite
            if ($#$longest_matches == 0) {
                push @{$longest_matches->[0]->{used}}, $g;
                $g->{id} = $longest_matches->[0]->{id};
                print "Best is: " . $g->{name} . " is " .  $longest_matches->[0]->{name} . " " .  $longest_matches->[0]->{id} . "\n" if $verbosity > 1;
            } else {
                foreach my $longest_match (@{$longest_matches}) {
                    print "Ambiguous are: " . $g->{name} . " is " .  $longest_match->{name} . " " .  $longest_match->{id} .  "\n" if $verbosity > 1;
                }

            }
        }
    }

    # Second pass to clear up those with two matches 
    # e.g. suppose there are both "Kilbowie West Ward", "Kilbowie Ward"
    # The match of "Kilbowie Ward" against "Kilbowie West" and "Kilbowie"
    # will find Kilbowie as shortest substring, and have two matches.
    # We want to pick "Kilbowie" not "Kilbowie West", but can only do so
    # after "Kilbowie West" has been allocated to "Kilbowie West Ward".
    # Hence this second pass.

    # ... except now we do it several times
    my $more = 1;
    while ($more) {
        $more = 0;
        foreach my $g (@$wards_goveval) {
            next if (exists($g->{id}));
            next if (!exists($g->{matches}));

            # Find matches which haven't been used elsewhere
            my @left = grep { !exists($_->{used}) } @{$g->{matches}};
            my $count = scalar(@left);
           
            # Match is now unambiguous...
            if ($count == 1) {
                my $longest_match = $left[0];
                push @{$longest_match->{used}}, $g;
                $g->{id} = $longest_match->{id};
                $g->{matches} = \@left;
                print "Resolved is: " . $g->{name} . " is " .  $longest_match->{name} . " " .  $longest_match->{id} . "\n" if $verbosity > 1;
                $more = 1;
            }
        }
    }
    # Store any errors for amibguous entries which are left
    foreach my $g (@$wards_goveval) {
        next if (exists($g->{id}));
        next if (!exists($g->{matches}));

        # Find matches which haven't been used elsewhere
        my @left = grep { !exists($_->{used}) } @{$g->{matches}};
        my $count = scalar(@left);
       
        if ($count == 0) {
            # If there are none, that's no good
            $error .= "${area_id}: Couldn't find match in database for GovEval ward " . $g->{name} . " (had ambiguous matches, but all been taken by others)\n";
        } elsif ($count > 1) {
            # If there is more than one
            $error .= "${area_id}: Only ambiguous matches found for GovEval ward " .  $g->{name} .  ", matches are " . join(", ", map { $_->{name} } @left) . "\n";
        }
    }
     
    # Check we used every single ward (rather than used same twice)
    foreach my $d (@$wards_database) {
        if (!exists($d->{used})) {
            $error .= "${area_id}: Ward in database, not in GovEval data: " . $d->{name} . " id " . $d->{id} . "\n";
        } else {
            delete $d->{used};
        }
    }
    
    # Store textual version of what we did
    $matchesdump = &$dump_wards();

    # Make it an error when a ward has two 'G' spellings, as it happens rarely
    if (!$error) {
        my $wardnames;
        foreach my $g (@$wards_goveval) {
            die if (!exists($g->{matches}));
            die if (scalar(@{$g->{matches}}) != 1);
            my $dd = @{$g->{matches}}[0];
            if (exists($wardnames->{$dd->{id}})) {
                if ($wardnames->{$dd->{id}} ne $g->{name}) {
                    $error .= "${area_id}: Ward has multiple GovEval spellings '" . $g->{name} . "', '" . $wardnames->{$dd->{id}} ."'\n";
                }
            }
            $wardnames->{$dd->{id}} = $g->{name};
        }
    }

    # Delete any old aliases
    foreach my $d (@$wards_database) {
        $m_dbh->do(q#delete from area_name where area_id = ? and name_type = 'G'#, {}, $d->{id});
    }

    # Store name aliases in DB
    if (!$error) {
        foreach my $g (@$wards_goveval) {
            die if (!exists($g->{matches}));
            die if (scalar(@{$g->{matches}}) != 1);
            my $dd = @{$g->{matches}}[0];
            $m_dbh->do(q#insert into area_name (area_id, name_type, name)
                values (?,?,?)#, {}, $dd->{id}, 'G', $g->{name});
        }
        $m_dbh->commit();
    }
 
    # Clean up looped references
    foreach my $d (@$wards_database) {
        delete $d->{used};
    }
    foreach my $g (@$wards_goveval) {
        delete $g->{matches};
    }

    # Return data
    return { 'details' => $matchesdump, 
             'error' => $error };
}

# get_raw_data COUNCIL_ID [LAST_MERGE]
# Return raw input data, with any admin modifications, for a given council.
# In the form of an array of references to hashes.  Each hash contains the
# ward_name, rep_first, rep_last, rep_party, rep_email, rep_fax.  If
# LAST_MERGE is set returns data at last merge or input from GovEval.
sub get_raw_data($;$) {
    my ($area_id, $last_merge) = @_;

    # Hash from representative key (either ge_id or newrow_id, with appropriate
    # prefix to distinguish them) to data about the representative.
    my $council;
    
    # Real data case
    my $sth = $d_dbh->prepare(
            q#select * from raw_input_data where
            council_id = ?#, {});
    $sth->execute($area_id);
    while (my $rep = $sth->fetchrow_hashref) {
        my $key = 'ge_id' . $rep->{ge_id};
        $council->{$key} = $rep;
        $council->{$key}->{key} = $key;
    }

    # Override with other data
    if ($last_merge) {
        # Get data up to last merge or import
        $sth = $d_dbh->prepare(
                q#select * from raw_input_data_edited where
                council_id = ? and order_id <= 
                    coalesce((select max(order_id) from raw_input_data_edited 
                                where council_id = ? and (editor = 'import'))
                            , 0)
                order by order_id#, {});
        $sth->execute($area_id, $area_id);
    } else {
        # Get all data
        $sth = $d_dbh->prepare(
                q#select * from raw_input_data_edited where
                council_id = ? order by order_id#, {});
        $sth->execute($area_id);
    }
    # Apply each transaction in order
    while (my $edit = $sth->fetchrow_hashref) {
        my $key = $edit->{ge_id} ? 'ge_id'.$edit->{ge_id} : 'newrow_id'.$edit->{newrow_id};
        if ($edit->{alteration} eq 'delete') {
            die "get_raw_data: delete row that doesn't exist" if (!exists($council->{$key}));
            delete $council->{$key};
        } elsif ($edit->{alteration} eq 'modify') {
            $council->{$key} = $edit;
            $council->{$key}->{key} = $key;
        } else {
            die "Uknown alteration type";
        }
    }

    return values(%$council);
}

# edit_raw_data COUNCIL_ID COUNCIL_NAME COUNCIL_TYPE ONS_CODE DATA ADMIN_USER
# Alter raw input data as a transaction log (keeping history).
# DATA is in the form of a reference to an array of references to hashes.  Each
# hash contains the ward_name, rep_first, rep_last, rep_party, rep_email, rep_fax, key
# (from get_raw_data above).  Include all the councils, as deletions are
# applied.  ADMIN_USER is name of person who made this edit.
# COUNCIL_NAME and COUNCIL_TYPE are stored in the edit for reference later if
# for some reason ids get broken, really only COUNCIL_ID matters.  Doesn't
# commit transaction, calling code needs to do that.
sub edit_raw_data($$$$$$) {
    my ($area_id, $area_name, $area_type, $area_ons_code, $newref, $user) = @_;
    my @new = @$newref;

    my @old = get_raw_data($area_id);

    my %old; do { $old{$_->{key}} = $_ } for @old;
    my %new; do { $new{$_->{key}} = $_ } for @new;

    # Delete entries which are in old but not in new
    foreach my $key (keys %old) {
        if (!exists($new{$key})) {
            my ($newrow_id) = ($key =~ m/^newrow_id([0-9]+)$/);
            my ($ge_id) = ($key =~ m/^ge_id([0-9]+)$/);
            my $sth = $d_dbh->prepare(q#insert into raw_input_data_edited
                (ge_id, newrow_id, alteration, council_id, council_name, council_type, council_ons_code,
                ward_name, rep_first, rep_last, 
                rep_party, rep_email, rep_fax, 
                editor, whenedited, note)
                values (?, ?, ?, ?, ?, ?, ?,
                        ?, ?, ?, ?, ?, ?, 
                        ?, ?, ?) #);
            $sth->execute($ge_id, $newrow_id, 'delete', $area_id, $area_name, $area_type, $area_ons_code,
                $old{$key}->{ward_name}, $old{$key}->{rep_first}, $old{$key}->{rep_last}, 
                $old{$key}->{rep_party}, $old{$key}->{rep_email}, $old{$key}->{rep_fax},
                $user, time(), "");
        }
    }

    # Go through everything in new, and modify if different from old
    foreach my $rep (@new) {
        my $key = $rep->{key};

        if ($key && exists($old{$key})) {
            my $changed = 0;
            foreach my $fieldname qw(ward_name rep_first rep_last rep_party rep_email rep_fax) {
                if ($old{$key}->{$fieldname} ne $rep->{$fieldname}) {
                    $changed = 1;
                }
            }
            next if (!$changed);
        }
        
        # Find row identifiers
        my ($newrow_id) = ($key =~ m/^newrow_id([0-9]+)$/);
        my ($ge_id) = ($key =~ m/^ge_id([0-9]+)$/);
        if (!$newrow_id && !$ge_id) {
            my @row = $d_dbh->selectrow_array(q#select nextval('raw_input_data_edited_newrow_seq')#);
            $newrow_id = $row[0];
        }

        # Insert alteration
        my $sth = $d_dbh->prepare(q#insert into raw_input_data_edited
            (ge_id, newrow_id, alteration, council_id, council_name, council_type, council_ons_code,
            ward_name, rep_first, rep_last, rep_party, 
            rep_email, rep_fax, 
            editor, whenedited, note)
            values (?, ?, ?, ?, ?, ?, ?,
                    ?, ?, ?, ?,
                    ?, ?,
                    ?, ?, ?) #);
        $sth->execute($ge_id, $newrow_id, 'modify', $area_id, $area_name, $area_type, $area_ons_code,
            $rep->{'ward_name'}, $rep->{'rep_first'}, $rep->{'rep_last'}, $rep->{'rep_party'},
                $rep->{'rep_email'}, $rep->{'rep_fax'},
            $user, time(), "");

    }
}

# get_url_via_cache URL
# Gets contents of given URL, throws exception if there is an error.
# If file is already in the cache, gets it again.
sub get_url_via_cache($) {
    my ($url) = @_;
    my $file = $url;
    $file =~ s#/#_#g;
    $file = mySociety::Config::get('COUNCILMATCH_PAGECACHE') . $file;
    if (! -e $file) {
        my $ret = LWP::Simple::getstore($url, $file);
        if (LWP::Simple::is_error($ret)) {
            throw Error::Simple("Failed to get URL $url HTTP status $ret to $file");
        }
    }
    my $content = File::Slurp::read_file($file);
}

# check_councillors_against_website COUNCIL_ID VERBOSITY 
# Attempts to match up the wards from the raw_input_data table to the Ordnance
# Survey names. Returns hash ref containing 'details' and 'error'.
sub check_councillors_against_website($$) {
    my ($area_id, $verbose) = @_;
    print "Council " . $area_id . "\n" if $verbose;

    # Get URL from database
    my $extradata = $d_dbh->selectrow_hashref(q#select council_id, councillors_url from 
        raw_council_extradata where council_id = ?#, {}, $area_id);

    # Get known data from database
    my @raw = CouncilMatch::get_raw_data($area_id);
    my $wardnames = $m_dbh->selectall_hashref(
            q#select * from area_name, area where area_name.area_id = area.id and
            parent_area_id = ?
            and generation_low <= (select id from current_generation) and
                (select id from current_generation) <= generation_high
            #, 'name', {}, $area_id);
    my $wardnamescanon;
    do { $wardnamescanon->{canonicalise_ward_name($_)} = $wardnames->{$_}; print "canonward: " . canonicalise_ward_name($_) . "\n" if $verbose; } for keys %$wardnames;
    # Various lookup tables
    my $wardsbyid;
    do { $wardsbyid->{$wardnames->{$_}->{id}} = $wardnames->{$_}->{name} } for keys %$wardnames;
    my $cllrsbykey;
    do { $cllrsbykey->{$_->{key}} = $_ } for @raw;
    my $cllrsbywardid;
    do { push @{$cllrsbywardid->{$wardnames->{$_->{ward_name}}->{id}}}, $_ if (defined($wardnames->{$_->{ward_name}})) } for @raw;

    # Break parts of array separated by various sorts of punctuation
    sub split_lumps_further($) {
        my ($lumps) = @_;
        my @lumps = map { split / - | \(| \)|:|;/, $_ } @$lumps;
        return @lumps;
    }

    # Get all HTML from councillor list web page, and tidy
    print "Getting main page... $extradata->{councillors_url} " if $verbose;
    my $mainpage = get_url_via_cache($extradata->{councillors_url});
    print "...got\n" if $verbose;
    my @lumps = mySociety::StringUtils::break_into_lumps($mainpage);
    @lumps = split_lumps_further(\@lumps);
    my $content = $mainpage;

    # Get out next layer of URLs
    my @urls;
    my $p = HTML::TokeParser->new(\$mainpage);
    # include only clickable maps "area"
    while (my $token = $p->get_tag("area")) {
        my $url = $token->[1]{href};
        next if !$url;
        next if $url =~ m/^\#/;
        next if $url =~ m/\.pdf$/;
        if (!URI->new($url)->scheme()) { # only relative ones
            my $uri = URI->new_abs($url, $extradata->{councillors_url});
            $url = $uri->as_string();
            push @urls, $url;
        }
    }

    # scan_with_pattern PATTERN
    # Scan lumps to find wards and councillors in given pattern
    my $scan_with_pattern = sub {
        my ($pattern) = @_;
        die "scan_with_pattern: invalid pattern $pattern" if ($pattern ne "WCWCCC" && $pattern ne "CWCWCW");
        my $error = "";

        my $warddone;
        do { $warddone->{$wardnames->{$_}->{id}} = [] if $wardnames->{$_}->{id}} for keys %$wardnames;
        my $repdone;
        do { $repdone->{$_->{key}} = [] } for @raw;
    
        # Scan for stuff
        my $lastwardid = undef;
        my $lastcllrkey = undef;
        foreach my $lump (@lumps) {
            my $canon_person_lump = canonicalise_person_name($lump);
            print "person lump: $canon_person_lump\n" if $verbose > 1;

            my $matches = 0;
            foreach my $rep (@raw) {
                my $first = $rep->{rep_first};
                my $last = $rep->{rep_last};
                # Match representative names various ways
                my $canon_name = canonicalise_person_name("$first $last");
                print "name: $canon_name\n" if $verbose > 1;
                # If lump begins with an initial, initialise first word of name
                # In that case, don't bother with nicknames
                my $match = 0;
                if ($canon_person_lump =~ m/^[[:alpha:]] /) {
                    $canon_name =~ s/^([[:alpha:]])([[:alpha:]]+) /$1 /;
                    $match = ($canon_person_lump =~ m/\b$canon_name\b/);
                } else {
                    # Apply nicknames
                    $match = match_modulo_nickname($canon_person_lump, $canon_name, "../mapit-dadem-loading/nicknames/nicknames.csv"); 
                }
                if ($match) {
                    if (($pattern eq "CWCWCW") and defined($lastcllrkey)) {
                        $error .= $area_id . ": councillor " . $cllrsbykey->{$lastcllrkey}->{rep_first} . " " .
                            $cllrsbykey->{$lastcllrkey}->{rep_last} . " has no ward\n";
                    }
                    print "councillor matched '$canon_person_lump' == '$canon_name'\n" if $verbose;
                    $lastcllrkey = $rep->{key};
                    push @{$repdone->{$lastcllrkey}}, $lump;
                    $matches ++;
                    if ($pattern eq "WCWCCC") {
                        # check ward right
                        if (!(defined $lastwardid)) {
                            $error .= $area_id . ": councillor $first $last in wrong ward, ge " . $rep->{ward_name} . " none on website\n";
                        } elsif (!(defined $wardnames->{$rep->{ward_name}})) {
                            $error .= $area_id . ": councillor $first $last has unknown ward " . $rep->{ward_name} . "\n";
                        } elsif ($wardnames->{$rep->{ward_name}}->{id} != $lastwardid) {
                            $error .= $area_id . ": councillor $first $last in wrong ward, ge " . $rep->{ward_name} . " website " . $wardsbyid->{$lastwardid} . "\n";
                        }
                    }
                }
            }
            if ($matches > 1) {
                $error .= $area_id . ": $lump matched multiple councillors\n";
            }

            my $canon_ward_lump = canonicalise_ward_name($lump);
            print "ward lump: $canon_ward_lump\n" if $verbose > 1;
            my $found = 0;
            do { $found = $wardnamescanon->{$_}->{id} if ($canon_ward_lump =~ m/\b$_\b/) } for (keys %$wardnamescanon);
#            $found = 0 if ($lump !~ m/(^\d+\.)/);
            if ($found) {
                print "ward matched '$canon_ward_lump'\n" if $verbose;
                $lastwardid = $found;
                push @{$warddone->{$lastwardid}}, $lump;
                if ($pattern eq "CWCWCW") {
                    # check councillor right
                    if (!$lastcllrkey) {
                        # do nothing, as we have no councillor to check on
                    } elsif (!grep { $_->{key} eq $lastcllrkey } @{$cllrsbywardid->{$lastwardid}}) {
                        #print Dumper(@{$cllrsbywardid->{$lastwardid}});
                        #print "lastcllrkey $lastcllrkey\n";
                        $error .= $area_id . ": councillor " . $cllrsbykey->{$lastcllrkey}->{rep_first} . " " .
                            $cllrsbykey->{$lastcllrkey}->{rep_last} . " appears in wrong ward, ge " . 
                            $cllrsbykey->{$lastcllrkey}->{ward_name} . " website $lump\n";
                    } else {
                        $lastcllrkey = undef;
                    }
                }
            }
        }
        if (($pattern eq "CWCWCW") and defined($lastcllrkey)) {
            $error .= $area_id . ": councillor " . $cllrsbykey->{$lastcllrkey}->{rep_first} . " " .
                $cllrsbykey->{$lastcllrkey}->{rep_last} . " has no ward\n";
        }

        # Check all got
        foreach my $ward (keys %$warddone) {
            if (!scalar(@{$warddone->{$ward}})) {
                $error = $area_id . ": ward not matched " . $wardsbyid->{$ward} . " $ward\n" . $error;
            }
        }
        foreach my $rep (keys %$repdone) {
            if (!scalar(@{$repdone->{$rep}})) {
                my $name = $cllrsbykey->{$rep}->{rep_first} . " " . $cllrsbykey->{$rep}->{rep_last};
                # Find best matches by common substring to give as examples
                my $canon_name = canonicalise_person_name($name);
                my ($best_len, $best_match);
                $best_match = "<none>";
                foreach my $lump (@lumps) {
                    my $canon_person_lump = canonicalise_person_name($lump);
                    my $common_len = Common::placename_match_metric($canon_person_lump, $canon_name);
                    if (!defined($best_len) or $best_len < $common_len) {
                        $best_match = $lump;
                        $best_len = $common_len;
                    }
                }
                $error = $area_id . ": councillor not matched ge " . $name . " best match on council website: $best_match\n" . $error;
            }
        }

        # Dump matches we have made
        my $details = "";
        $details .= sprintf "%38s => %-38s\n", 'Councillor Matches Made: GovEval', 'Council Website';
        $details .= sprintf "-" x 38 . ' '. "-" x 38 . "\n";
        foreach my $repkey (keys %$repdone) {
            my $gename = $cllrsbykey->{$repkey}->{rep_first} . " " . $cllrsbykey->{$repkey}->{rep_last};
            $first = 1;
            foreach my $match (@{$repdone->{$repkey}}) {
                $details .= sprintf "%38s => %-38s\n", $first ? $gename : "", $match;
                $first = 0;
            }
        }
        $details .= sprintf "\n%38s => %-38s\n", 'Ward Matches Made: GovEval', 'Council Website';
        $details .= sprintf "-" x 38 . ' '. "-" x 38 . "\n";
        foreach my $ward (keys %$warddone) {
            my $gename = $wardsbyid->{$ward};
            $first = 1;
            foreach my $match (@{$warddone->{$ward}}) {
                $details .= sprintf "%38s => %-38s\n", $first ? $gename : "", $match;
                $first = 0;
            }
        }

        return ($error, $details);
    };

    my ($error1, $details1) = &$scan_with_pattern("WCWCCC");
    my ($error2, $details2) = &$scan_with_pattern("CWCWCW");
    my $ecount1 = ($error1 =~ tr/\n/\n/);
    my $ecount2 = ($error2 =~ tr/\n/\n/);
    if ($ecount1 > 20 and $ecount2 > 20) {
        # Nothing much good, so try recursive get
        foreach my $url (@urls) {
            print "Getting... $url " if $verbose;
            my $subpage = get_url_via_cache($url);
            print "...got\n" if $verbose;
            my @newlumps = mySociety::StringUtils::break_into_lumps($subpage);
            @newlumps = split_lumps_further(\@newlumps);
            push @lumps, @newlumps;
        }
        ($error1, $details1) = &$scan_with_pattern("WCWCCC");
        ($error2, $details2) = &$scan_with_pattern("CWCWCW");
        $ecount1 = ($error1 =~ tr/\n/\n/);
        $ecount2 = ($error2 =~ tr/\n/\n/);
    }

    my ($details, $error);
    if (!$error1) {
        print "WCWCCC worked\n" if $verbose;
        $details = $details1;
    }
    if (!$error2) {
        print "CWCWCW worked\n" if $verbose;
        $details = $details2;
    }
    if ($error1 && $error2) {
        if ($ecount1 < $ecount2) {
            print "least-errorful is WCWCCC\n" if $verbose;
            $error .= $error1;
            $details = $details1;
        } else {
            print "least-errorful is CWCWCW\n" if $verbose;
            $error .= $error2;
            $details = $details2;
        }
    }

    # Return data
    return { 'details' => $details, 
             'error' => $error };
}


1;
