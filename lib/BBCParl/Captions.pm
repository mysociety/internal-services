package BBCParl::Captions;

use strict;

use HTML::TreeBuilder;
use HTML::Entities;
use POSIX qw ( strftime );
use LWP::UserAgent;
use Date::Manip;
use XML::Simple;
use WebService::TWFY::API;
use DateTime;
#use DateTime::TimeZone;

use Data::Dumper;

# TODO - write out $filename.processed when they've been done
# TODO - replace #warn "FOO" with a proper logging system
# TODO - note start time, and write out run-time to updates
# TODO - return zero from sync_captions on exit, or error code

sub debug {
    my ($self, $message) = @_;
    if ($self->{'debug'}) {
	warn "DEBUG: $message";
    }
    return undef;
}

sub new {
    my ($class, %args) = @_;

    my $self = {};

    bless $self,$class;
    foreach my $key (keys %args) {
	$self->{'args'}{$key} = $args{$key};
    }

    if ($self->{'args'} && $self->{'args'}{'debug'}) {
	$self->{'debug'} = 'true';
    }

#    $self->{'constants'}{'captions-location'} = 'http://www.leitchy.com/parliament-logs/';
    $self->{'constants'}{'captions-directory-url'} = 'http://www.bbc.co.uk/test/parliament/';
    $self->{'constants'}{'twfy-api-location'} = 'http://www.theyworkforyou.com/api/';

    $self->{'path'}{'home-dir'} = (getpwuid($<))[7];
    $self->{'constants'}{'captions-directory-local'} = $self->{'path'}{'home-dir'} . "/downloads/parliament-logs";
    $self->{'constants'}{'hansard-updates-directory'} = $self->{'path'}{'home-dir'} . "/hansard-updates";

    $self->{'constants'}{'gid-window-size'} = 15;

    $self->{'timezones'}{'commons'} = 'Europe/London';
#    $self->{'timezones'}{'lords'} = 'Europe/London';
#    $self->{'timezones'}{'westminsterhall'} = 'Europe/London';

    $self->{'timezones'}{'default'} = 'Europe/London';

    return $self;

}

sub run {
    my ($self) = @_;

    unless ($self->set_processing_dates()) {
	warn "ERROR: Did not set captions processing dates, exiting now.";
	return undef;
    }

    if ($self->{'args'}{'nomirror'}) {
	$self->debug("skipping mirror operation on caption files");
    } else {
	unless ($self->mirror_log_files()) {
	    warn "ERROR: Mirror did not work okay (try --nomirror for offline use).";
	    return undef;
	}
    }

    unless ($self->load_log_files()) {
	warn "ERROR: Could not load data from log files, exiting now.";
	return undef;
    }
    
    unless ($self->{'args'}{'nohansard'}) {
	$self->get_hansard_data();
	$self->merge_captions_with_hansard();
    }

    unless ($self->{'arg'}{'no-output-write'} || $self->{'args'}{'nohansard'}) {
	unless ($self->write_update_files()) {
	    return undef;
	}
    }

    if ($self->{'stats'}{'print-stats'}) {
	$self->print_stats();
    }

    return 1;

}

sub print_stats {
    my ($self) = @_;

    #warn "STATS: Attempted to merge captions and hansard data from the following dates:";

    foreach my $date (sort keys %{$self->{'dates-to-process'}}) {
	#warn "STATS: $date";
    }

    foreach my $stat (sort keys %{$self->{'stats'}}) {
	if (defined($self->{'stats'}{$stat})) {
	    #warn "STATS: $stat = " . $self->{'stats'}{$stat};
	} else {
	    #warn "STATS: $stat = undefined";
	}
    }

}


sub modify_date {
    my ($date, $delta) = @_;
    unless (defined ($delta)) {
	$delta = '+1 days';
    }
    if (check_date($date)) {
#	warn "INFO: modifying $date by $delta";
	$date = DateCalc ( ParseDate($date) , ParseDateDelta($delta) );
	$date =~ /^(\d{4})(\d{2})(\d{2})/;
	return "$1-$2-$3";
    } else {
	return undef;
    }
}

sub check_date {
    my ($date) = @_;
    if ($date =~ /^\d{4}-\d{2}-\d{2}$/) {
	return $date;
    } else {
	warn "ERROR: $date is not of the form yyyy-mm-dd";
	return undef;
    }
}

sub set_processing_dates {
    my ($self) = @_;

    my $start_date = $self->{'args'}{'start-date'};
    my $end_date  = $self->{'args'}{'end-date'};
    my $single_date = $self->{'args'}{'date'};

    # if there's a --date param, ignore --start-date and --end-date

    if ($single_date) {
	$start_date = $single_date;
	$end_date = $single_date;
    }

    # default is to process just the previous day's captions data

    unless ($start_date) {
	# use yesterday's date in yyyy-mm-dd format
	my $date_time_format = '%F';
	$start_date = strftime($date_time_format,gmtime());
	$start_date = modify_date($start_date, '-1 days');
    }

    unless ($end_date) {
	$end_date = $start_date;
    }

    map {
	unless (check_date($_)) {
	    warn "FATAL: date parameter is not valid: $_";
	    die;
	}
    } ($start_date, $end_date);

    unless ($start_date le $end_date) {
	warn "ERROR: start_date ($start_date) is after end_date ($end_date)";
	return undef;
    }

    $self->{'dates-to-process'}{$start_date} = 1;

    my $next_date = $start_date;
    while ($next_date lt $end_date) {
	$next_date = modify_date ($next_date, "+1 days");
	$self->{'dates-to-process'}{$next_date} = 1;
	$self->debug("processing captions from $next_date");
    }

    return 1;

}

sub mirror_log_files {
    my ($self) = @_;

    # for each date in the dates-to-process range, fetch four files
    # from www.bbc.co.uk/test/parliament/ of the form
    # {commons,bigted1,bigted2,westminster}.yyyymmdd.log (text format)

    my $dir_url = $self->{'constants'}{'captions-directory-url'};
    my $dir_local = $self->{'constants'}{'captions-directory-local'};
    my @file_prefixes = ('commons','bigted1','bigted2','westminster');

    my $ua;
    unless ($ua = LWP::UserAgent->new()) {
	warn "ERROR: Cannot create new LWP::UserAgent object; error was $!";
	return undef;
    }

    foreach my $date (sort keys %{$self->{'dates-to-process'}}) {
	# convert the date from yyyy-mm-dd to yyyymmdd format
	$date =~ s/-//g;
	map {
	    my $url = "$dir_url/$_.$date.log";
	    my $filename = "$dir_local/$_.$date.log";
	    my $response = $ua->mirror($url, $filename);
	    unless ($response->is_success()) {
		if ($response->status_line() =~ /304/) {
		    $self->debug("Could not fetch $url (error was " . $response->status_line() . ").");
		} else {
		    warn "ERROR: Could not fetch $url (error was " . $response->status_line() . ").";
		}
	    }
	} @file_prefixes;
    }

    return 1;

}

sub load_log_files {
    my ($self) = @_;

    # for the specified date range, open logfiles and copy relevant
    # data into an in-memory data structure that can be merged with
    # the hansard output later on (in a different function)

    foreach my $date (sort keys %{$self->{'dates-to-process'}}) {
	# convert the date from yyyy-mm-dd to yyyymmdd format
	my $filename_date = $date;
	$filename_date =~ s/-//g;
	my $filename_pattern = $self->{'constants'}{'captions-directory-local'} . "/*.$filename_date.*";

	foreach my $filename (glob($filename_pattern)) {
	    if ($filename =~ /done$/) {
		$self->debug("Skipping $filename");
		next;
	    }

	    my $location = 'unknown';

	    # TODO - add support for non-commons logfiles
	    if ($filename =~ /commons/) {
		$location = 'commons';
	    } else {
		next;
		# TODO - rename file to $filename.done
	    }
    
	    unless (open(CAPTIONS, $filename)) {
		warn "ERROR: Cannot open file $filename; error was $!";
		next;
	    }
	    
	    my $raw_captions_data;
	    while (<CAPTIONS>) {
		$raw_captions_data .= $_;
	    }
	    close CAPTIONS;
	    unless ($raw_captions_data) {
		warn "ERROR: No data found in file $filename";
		next;
	    }
	    
	    # store data in $self->{'captions'}{$date}{$location}{$caption_id}
	    my $caption_id = 0;
	    my $datetime = 'unknown';
	    my $current_name = '';
	    my $current_position = '';
	    my $previous_name = '';
	    my $previous_position = '';

	    # update datetime every time we see a TIMESTAMP line

	    foreach my $line (split("\n",$raw_captions_data)) {
		if ($line =~ /TIMESTAMP: (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)/i) {
		    $datetime = $1;
		}
		if ($line =~ /STRAPS INFO\s*:\s*House of Lords/i) {
		    $location = 'lords';
		}
		if ($line =~ /STRAPS INFO\s*:\s*House of Commons/i) {
		    $location = 'commons';
		}
		if ($line =~ /STRAPS NAME\s*:\s*(.+)\\(.+)$/) {
		    $current_name = $1;
		    $current_position = $2;
		    if ($current_name eq $previous_name) {
			$self->{'stats'}{'duplicated'} += 1;
			next;
		    }
		    $self->{'captions'}{$date}{$location}{$caption_id}{'name'} = $current_name;
		    $self->{'captions'}{$date}{$location}{$caption_id}{'position'} = $current_position;
		    $self->{'captions'}{$date}{$location}{$caption_id}{'timestamp'} = $datetime;
		    $previous_name = $current_name;
		    $caption_id += 1;
		    $self->{'stats'}{'captions-total'} += 1;
		}
	    }

	    # TODO - rename the file to $filename.done

	}

    }
    
    return 1;

}

sub process_captions_files {
    my ($self) = @_;

    # there is an upstream bug (in the script that generates the
    # captions-logfile inside the BBC) - the datestamps in filenames
    # are often incorrect (the month value is incorrectly
    # incremented). instead of trying to cope with this, we will just
    # mirror all files from their website, and then process all new
    # files regardless of the datestamp in their filenames.

    my $filename_pattern = "parliament-*.xml.*";
    my $dir_filename_pattern = $self->{'path'}{'captions-files-dir'} . "/$filename_pattern";

    foreach my $filename (glob($dir_filename_pattern)) {

	if ($filename =~ /processed$/) {
	    next;
	}

	# TODO - right now, we only consider HoC captions.  we should
	# probably alter this behaviour to also cover HOL, WH,
	# committees, etc.  foreach filename, we should process the
	# captions before proceeding to foreach date, and determine
	# which caption events refer to each house.  then, we can have
	# a different set of arrays containing events from each house,
	# and process them within foreach @dates.

	# if file doesn't start parliament-commons or
	# parliament-westminster, ignore it (for now)

	unless ($filename =~ /commons/) { ## || $filename =~ /westminster/) {
	    $self->debug("Skipping $filename (not commons)");
	    next;
	}

	if (-e "$filename.processed") {
	    $self->debug("$filename has already been processed");
	    $self->debug("skipping $filename (to process this file, please delete $filename.processed)");
	    next;
	}
	    
	unless (-e $filename) {
	    warn "ERROR: Cannot find file $filename; error was $!";
	    next;
	}
	
#	warn "INFO: Attempting to parse $filename";

	unless (open(CAPTIONS, $filename)) {
	    warn "ERROR: Cannot open file $filename; error was $!";
	    next;
	}
	
	my $raw_captions_data;
	
	while (<CAPTIONS>) {
	    $raw_captions_data .= $_;
	}
	close CAPTIONS;
	
	# read in the file to memory; if it doesn't start/end with
	# <logs>/</logs> then top/tail it.

	unless ($raw_captions_data) {
	    warn "ERROR: No data found in file $filename";
	    next;
	}

	unless ($raw_captions_data =~ /^<logs>/) {
	    $raw_captions_data = "<logs>\n$raw_captions_data";
	}
	
	unless ($raw_captions_data =~ /<\/logs>$/) {
	    $raw_captions_data = "$raw_captions_data\n</logs>";
	}
	
	my $captions_ref = XMLin($raw_captions_data);

	# process the captions file, adding captions information for
	# dates in our processing range to the 

	$self->{'stats'}{'captions-duplicated'} = 0;
	$self->{'stats'}{'captions-skipped'} = 0;

	my $caption_id = 0;
	
	foreach my $date (sort keys %{$self->{'dates-to-process'}}) {

	    my $date_pattern = 'xx/xx/xxxx';
	    if ($date =~ /(\d{4})-(\d{2})-(\d{2})/) {
		$date_pattern = "$3/$2/$1";
	    } else {
		warn "ERROR: $date is not of the format yyyy-mm-dd - skipping $filename";
		next;
	    }

	    $self->debug("Looking for $date in data from $filename");

	    # TODO - we need to have more than one type of location
	    # covered, but for now it's just commons

	    my $last_non_speech_event = undef;
	    my $location = 'commons';
	    my $previous_name = '';

	    foreach my $event_ref (@{$captions_ref->{'log'}}) {

		# TODO - have code here that checks the content of
		# captions to determine whether we're in the commons,
		# lords, etc

		unless ($$event_ref{'timestamp'} =~ /^$date_pattern/) {
		    next;
		}

		if (defined($$event_ref{'name'})) {

		    my $caption_name = $$event_ref{'name'};
		    my $caption_position = $$event_ref{'position'};

		    #warn "$caption_id $caption_name = $caption_position";
		    #warn Dumper $caption_position;

		    # check value of 'name' - if it has two lines,
		    # split value of 'name' by "\n" and assign second
		    # line to 'position'

		    if (ref($caption_position) eq 'HASH') {
			if ($caption_name =~ /^(.+)\n(.+)$/) {
			    $caption_name = $1;
			    $caption_position = $2;
			    $$event_ref{'name'} = $caption_name;
			    $$event_ref{'position'} = $caption_position;
			}
		    }

		    #warn Dumper $event_ref;

		    # it's a speech caption
		    if ($caption_name eq $previous_name) {
			# skip this caption if current.name eq last.name
			$self->{'stats'}{'captions-duplicated'} += 1;
			next;
		    }

		    if ($location eq 'commons') {
			#warn "adding caption event ($date, $location, $caption_id)";
			$self->{'captions'}{$date}{$location}{$caption_id} = $event_ref;
		    } else {
			warn "ERROR: Invalid location ($location)";
			# we should never be here!
			# but it might happen if I insert a bug by mistake
		    }

#		    if ($caption_name && is_mp($caption_name)) {
#			warn "DEBUG: $caption_name changed location ($location -> lords)";
#			$location = 'lords';
#		    } elsif ($caption_name && is_lord($caption_name)) {
#			warn "DEBUG: $caption_name changed location ($location -> lords)";
#			$location = 'lords';
#		    }

		    $previous_name = $$event_ref{'name'};

		    #warn "$caption_id $previous_name";

		    $caption_id++;
#		    warn $caption_id;
#		    $self->{'stats'}{'captions-total'} += 1;

		} else {

		    # it's a non-speech caption

		    my $raw = $$event_ref{'raw'};

		    $last_non_speech_event = $event_ref;

		}
	    }

	}

    }

#    warn Dumper $self->{'captions'};
    
}

sub sort_gids {
    #warn Dumper @_;
    return map  { $_->[0] }
    sort {
	$a->[1] <=> $b->[1] ||
	    $a->[2] <=> $b->[2]
        } map { [ $_, (/^\d{4}-\d{2}-\d{2}.+?(\d+).(\d+)$/) ] } @_;
}

sub merge_captions_with_hansard {
    my ($self) = @_;

    my $caption_id = 0;
    my $last_name = '';
    my $time = '';

    #warn Dumper $self->{'captions'};

    foreach my $date (sort keys %{$self->{'hansard'}}) {

	# reset $time or it carries over from the previous evening!
	$time = '';
	#warn $date;

	foreach my $location (sort keys %{$self->{'hansard'}{$date}}) {

	    #warn $location;

	    # TODO - for major gids that have one or more
	    # children, there is no speaker information. however,
	    # we will have to update the htime of the major gid
	    # with the new htime of its first speech gid (child).

	    # if speech.speaker eq captions.next.speaker: then
	    # $start_time = captions.next.start_time (adjusted to
	    # local time from GMT); discard captions.next; set
	    # $confident = true

	    my @gids = sort_gids (keys %{$self->{'hansard'}{$date}{$location}});
	    my $num_gids = @gids;
	    my $gid_index = 0;

	    #warn "processing $num_gids gids";

	    $self->{'stats'}{'hansard-total-gids'} += $num_gids;

	    my @caption_ids = (sort {$a <=> $b} keys %{$self->{'captions'}{$date}{$location}});
	    #warn Dumper @caption_ids;

	    foreach my $caption_id (@caption_ids) {

		# cycle through each caption in turn; foreach caption,
		# compare name with the next gid.name; if it matches,
		# set time and move on to the next caption

		my $skip_caption = 0;
		my $match_found = 0;
		my $gid_offset = 0;
		my $num_speech_gids = 0;
		my $window_size = $self->{'constants'}{'gid-window-size'};

		if ($gid_index >= $num_gids) {
		    #warn "DEBUG: No more gids left!";
		    $skip_caption = 1;
		}

		my $caption_name = $self->{'captions'}{$date}{$location}{$caption_id}{'name'};
		my $caption_timestamp = $self->{'captions'}{$date}{$location}{$caption_id}{'timestamp'};
		#warn "DEBUG: processing caption $caption_id $caption_name";

		while (($num_speech_gids < $window_size) && (($gid_index + $gid_offset) < $num_gids)) {
		    
		    #warn "gid index: $gid_index; gid offset: $gid_offset";

		    if (($gid_index + $gid_offset) >= $num_gids) {
			#warn "DEBUG: No more gids left!";
			$skip_caption = 1;
			last;
		    }

		    my $gid = $gids[$gid_index + $gid_offset];

		    #warn "DEBUG: gid = $gid";

		    if (defined($self->{'hansard'}{$date}{$location}{$gid}{'name'})) {
			#warn "DEBUG: $gid is a speech";
			$num_speech_gids += 1;

			my $hansard_name = $self->{'hansard'}{$date}{$location}{$gid}{'name'};
			
			#warn "DEBUG: comparing $caption_id: $caption_timestamp $caption_name <-> $hansard_name $gid";
			my $cmp_result = compare_names($caption_name, $hansard_name);
			
			if (defined($cmp_result) && $cmp_result == 1) {
			    #warn "DEBUG: match found ($caption_name, $hansard_name)";
			    $self->{'stats'}{'hansard-captions-matched'} += 1;
			    $match_found = 1;
			    #if ($caption_timestamp =~ /(\d{2}\/\d{2}\/\d{4}) (\d{2}:\d{2}:\d{2})/) 
			    if ($caption_timestamp =~ /(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})Z/) {
				$time = $2;
			    } else {
				warn "ERROR: Caption timestamp not valid ($caption_timestamp)";
			    }
			} else {
			    #warn "DEBUG: failed to match $caption_name with $hansard_name - skipping $hansard_name";
			    $match_found = 0;
			}

		    } else {
			#warn "DEBUG: $gid is a heading";
		    }

		    if ($time) {
			# convert $time from GMT into BST if necessary

			my $tz = '';
			if (defined($self->{'timezones'}{$location})) {
			    $tz = $self->{'timezones'}{$location};
			} elsif (defined($self->{'timezones'}{'default'})) {
			    warn "ERROR: No timezone specified for location $location";
			    warn "ERROR: Using default timezone: " . $self->{'timezones'}{'default'};
			    $tz = $self->{'timezones'}{'default'};
			} else {
			    warn "ERROR: No timezone specified for location $location";
			    warn "ERROR: No default timezone available. Ignoring timezones.";
			}
		
			my @time = ();
			if ($time =~ /(\d{2}):(\d{2}):(\d{2})/) {
			    @time = ('hour',$1,'minute',$2,'second',$3);
			}
			my @date = ();
			if ($date =~ /(\d{4})-(\d{2})-(\d{2})/) {
			    @date = ('year',$1,'month',$2,'day',$3);
			}
			#warn Dumper (@date, @time);
			my $dt = DateTime->new(@date,@time,'time_zone','UTC');
			if ($tz) {
			    $dt->set_time_zone($tz);
			}
			
			#warn "DEBUG: $time UTC is " . $dt->hms(':') . " local time";

			# only update htime if $time is actually later
			# than the current htime value
			
			#warn Dumper $self->{'hansard'}{$date}{$location}{$gid}{'htime'};
			if ($self->{'hansard'}{$date}{$location}{$gid}{'htime'} lt $dt->hms(':')) {
			    #warn "DEBUG: Updating htime for $gid - now " . $dt->hms(':');
			    $self->{'updates'}{$date}{$location}{$gid}{'htime'} = $dt->hms(':');
			    #$self->{'stats'}{'hansard-gids-updated'} += 1;
			}

		    } else {
			$self->{'stats'}{'hansard-not-processed'} += 1;
		    }

		    if ($match_found) {
			#warn "DEBUG: Done with gids (offset is $gid_offset)";
			$gid_index += $gid_offset + 1;
			last;
		    } else {
			$gid_offset += 1;
			#warn "DEBUG: Incrementing offset ($gid_offset)";
		    }

		}

		if ($skip_caption == 1 || $match_found == 0) {
		    #warn "DEBUG: skipping caption $caption_id ($caption_name, $time)";
		    $skip_caption = 0;
		    $self->{'stats'}{'captions-skipped'} += 1;
		}

		$self->{'stats'}{'captions-processed'} += 1;

		#warn "finished with caption $caption_id $caption_name";

	    }

	    $self->{'stats'}{'hansard-not-processed'} = $num_gids - $gid_index;

	}

    }

}

sub compare_names {
    my ($caption_current, $hansard_current) = @_;

    unless (defined($caption_current) && defined ($hansard_current)) {
	return undef;
    }

    map {
	$_ = clean_name($_);
	$_ = normalise_name($_);
    } ($caption_current, $hansard_current);

    if (lc($caption_current) eq lc($hansard_current)) {
	return 1;
    } else {
	return undef;
    }

}

sub clean_name {
    my ($name) = @_;
    $name = lc($name);

    unless (defined($name)) {
	return undef;
    }

    # various transforms to remove titles, honorifics, etc:

    $name =~ s/^sir\s//i;
    $name =~ s/^lady\s+//i;
    $name =~ s/^rt hon.*\s*//i;
    $name =~ s/^right hon.*\s*//i;
#    $name =~ s/^baroness\s+//i;
#    $name =~ s/^lord\s+//i;
#    $name =~ s/^archbishop\s+//i;
#    $name =~ s/^bishop\s+//i;
    $name =~ s/^rev.*\s*//i;
    $name =~ s/^rt rev\s+//i;
    $name =~ s/^very rev.*\s*//i;
    $name =~ s/^gen.*\s*//i;

    $name =~ s/MP\s*$//i;

    $name =~ s/^\s*//i;
    $name =~ s/\s*$//i;

    return $name;
}

sub normalise_name {
    my ($name) = @_;
    $name = lc($name);
    
    # some common first name matches e.g. Mike -> Michael

    my %first_names = (
		       'andy' => 'andrew',
		       'bill' => 'william',
		       'bob' => 'robert',
		       'ed' => 'edward',
		       'geoff' => 'geoffrey',
		       'mike' => 'michael',
		       'nick' => 'nicholas',
		       'philip' => 'phil',
		       'phillip' => 'phil',
		       'rob' => 'robert',
		       'tony' => 'anthony',
		       'sue' => 'susan',
		       'jim' => 'james',
		       'will' => 'william'
    );

    # only apply one transform to the first name

    foreach my $from (sort keys %first_names) {
	if ($name =~ /^$from\s+/i) {
	    $name =~ s/^$from\s+/$first_names{$from} /i;
	    #warn "DEBUG: transformed $name: $from -> " . $first_names{$from};
	    last;
	}
    }

    # remove accents

    my @accents = (
		   'acute',
		   'grave',
		   'circ',
		   'uml',
		   'tilde',
		   'ring',
		   'Elig',
		   'cedil',
		   'th', # eth - icelandic e
		   'slash',
		   'horn', # thorn - icelandic th
		   'zlig' # beta symbol in German, convert to s
		   );

    foreach my $accent_code (sort @accents) {
	while ($name =~ /&.$accent_code;/) {
	    $name =~ s/&(.)$accent_code;/$1/i;
	}
    }

    return $name;
}

sub get_hansard_data {
    my ($self) = @_;

    foreach my $date (sort keys %{$self->{'dates-to-process'}}) {
    
	# TODO - search for lords and westminster hall as well!
	#my @locations = qw (commons lords westminsterhall);

	my @locations = qw (commons);
	foreach my $location (@locations) {
	    
	    my $api = WebService::TWFY::API->new();
	    
	    # now get the data from TWFY API
	    
	    # first, get the debate ids
	    
	    my $response = $api->query( 'getDebates',
					{ 'type' => $location,
					  'date' => $date,
					  'output' => 'xml'
					  } );
	    
	    unless ($response->is_success()) {
		warn "ERROR: Could not fetch data from TWFY API; error was " . $response->status_line();
		warn "ERROR: Skipping captions processing for $location on $date";
		next;
	    }
	    
	    my $results = $response->{results};

	    # get the response into some usable form

	    my $results_ref = XMLin($results,
				    'ForceArray' => ['match']);

#		warn Dumper $results_ref;

	    # the date=xxx response contains an ordered list of
	    # "match" elements, each of which has one "entry"
	    # element and one "subs" element. subs contains zero
	    # or more "match" elements. cycle through and get all
	    # gids.

	    # maintain a hash of gid types: "entry" is a level-one
	    # heading; each of the "subs"->"match" elements are
	    # level-two headings; there are also speeches, but
	    # these aren't returned in the date=xxx output. values
	    # are 1 (level-one), 2 (level-two), 3 (speech)

	    my %gid_type = ();
	    
	    # maintain a hash that notes how children per gid
	    
	    my %num_children = ();
	    
	    # maintain a hash that links gids to their
	    # parent gids (or gid 0 if they have no parent).
	    
	    my %parents = ();
	    
	    # maintain a hash that contains the hansard-given
	    # meta-date (e.g. htime) for each gid
	    
	    my %hansard_data = ();
	    
	    # foreach gid, fetch details on level-one gids
	    # without children, and then on level-two gids
	    
	    my @gids = ();
	    
	    foreach my $match_ref (@{$results_ref->{'match'}}) {
		
		my $gid = $$match_ref{'entry'}{'gid'};
		push @gids, $gid;
		$gid_type{$gid} = '1';
		$parents{$gid} = 0;
		$hansard_data{$gid}{'htime'} = $$match_ref{'entry'}{'htime'};
		my $children = 0;
		
		if (defined($$match_ref{'subs'}{'match'})) {
		    foreach my $subs_match_ref (@{$$match_ref{'subs'}{'match'}}) {
			
			$children++;
			my $child_gid = $$subs_match_ref{'gid'};
			push @gids, $child_gid;
			$gid_type{$child_gid} = '2';
			$parents{$child_gid} = $gid;
			$hansard_data{$child_gid}{'htime'} = $$subs_match_ref{'htime'};
			$num_children{$child_gid} = $$subs_match_ref{'contentcount'};
			
		    }
		}
		
		$num_children{$gid} = $children;
		
	    }
	    
#		warn Dumper @gids;
#		warn Dumper %gid_type;
#		warn Dumper %num_children;
#		warn Dumper %parents;

	    # foreach debate id, get speaker ids and other data
	    
	    foreach my $gid (@gids) {
		
		if ($num_children{$gid} > 0 && $gid_type{$gid} == 1) {
		    
		    # skip level-one gids that have children
		    # (i.e. headings without a speaker id)
		    
#		    warn "INFO: skipping gid $gid";
		    
#		    next;
		}
		
		#warn "INFO: getting $gid";

		my $speech_response = $api->query( 'getDebates',
						   { 'type' => $location,
						     'gid' => $gid,
						     'output' => 'xml'
						     } );
		
		unless ($speech_response->is_success()) {
		    warn "ERROR: Could not fetch data from TWFY API; error was " . $speech_response->status_line();
		    warn "ERROR: Skipping captions processing for $location on $date";
		    next;
		}
		
		my $speech_results = $speech_response->{results};
		
		unless ($speech_results) {
		    #warn "INFO: No result was returned from TWFY API for gif $gid";
		    $self->{'stats'}{'hansard-empty-gid'} += 1;
		    next;
		}

		my $speech_results_ref = XMLin($speech_results,
					       'ForceArray' => ['match']);
		
#		warn ref($speech_results_ref);
		
		foreach my $match_ref (@{$speech_results_ref->{'match'}}) {

#		    warn Dumper $match_ref;
		    
		    my $this_gid = $$match_ref{'gid'};

		    if (defined($gid_type{$this_gid}) && ($gid_type{$this_gid} == 1 || $gid_type{$this_gid} == 2)) {
			# we've already seen this $gid, so it's a heading
			next;
		    }

		    $gid_type{$this_gid} = 3;
		    $parents{$this_gid} = $gid;
		    $num_children{$this_gid} = 0;

		    unless (defined($$match_ref{'speaker'}) &&
			    defined($$match_ref{'speaker'}{'last_name'})) {
			next;
		    }

		    # warn Dumper $match_ref;

		    $hansard_data{$this_gid}{'name'} = $$match_ref{'speaker'}{'first_name'} . ' ' . $$match_ref{'speaker'}{'last_name'};
		    $hansard_data{$this_gid}{'member_id'} = $$match_ref{'speaker_id'};
		    $hansard_data{$this_gid}{'party'} = $$match_ref{'speaker'}{'party'};
		    $hansard_data{$this_gid}{'constituency'} = $$match_ref{'speaker'}{'constituency'};
		    $hansard_data{$this_gid}{'house'} = $$match_ref{'speaker'}{'house'};
		    $hansard_data{$this_gid}{'htime'} = $$match_ref{'htime'};
		    
		}
		
	    }
	    
	    # TODO - when all speaker entries have been processed,
	    # if last entry type eq speaker, $last_time = TBD; if
	    # last entry type ne speaker fetch the hansard data
	    # for $location that day using the TWFY API, and put
	    # it into a local memory structure (first debates,
	    # whch gives us @gids, and then data on each speech
	    # (foreach $gid)

	    foreach my $gid (keys %hansard_data) {
		$self->{'hansard'}{$date}{$location}{$gid} = $hansard_data{$gid};
	    }
   
	}
	
    }

}

sub write_update_files {
    my ($self) = @_;

    unless (defined($self->{'updates'})) {
	warn "ERROR: No updates found, skipping write_update_files";
	return undef;
    }
    
    my $date_time_format = '%FT%TZ';
    my $date_time = strftime($date_time_format,gmtime());

# filename changed to remove SQL extension
#    my $updates_filename = $self->{'path'}{'updates-files-dir'} . "/hansard-updates-$date_time.sql";    
    my $updates_filename = $self->{'constants'}{'hansard-updates-directory'} . "/hansard-updates-$date_time";
    if (-e $updates_filename) {
	warn "ERROR: Replacing existing file $updates_filename";
    }
    
    unless (open(UPDATES, ">$updates_filename")) {
	warn "ERROR: Cannot open $updates_filename; error was $!";
	$self->{'stats'}{'write-update-files-status'} = "error-opening-file ($updates_filename)";
	return undef;
    }

    print UPDATES "-- updates for hansard (generated at $date_time)\n-- timestamps are in GMT\n-- command line arguments were:\n\n";

    foreach my $arg_name (sort keys %{$self->{'args'}}) {
	print UPDATES "-- --$arg_name";
	if ($self->{'args'}{$arg_name}) {
	    print UPDATES "=" . $self->{'args'}{$arg_name};
	}
	print UPDATES "\n";
    }

    my $num_updates = 0;
    foreach my $date (sort keys %{$self->{'updates'}}) {
	foreach my $location (sort keys %{$self->{'updates'}{$date}}) {
	    print UPDATES "-- date=$date; location=$location\n";
	    foreach my $gid (sort_gids(keys %{$self->{'updates'}{$date}{$location}})) {
		my $htime = $self->{'updates'}{$date}{$location}{$gid}{'htime'};
		# updated output format as requested by matthew@mysociety.org
		#print UPDATES "UPDATE hansard SET htime = '$htime' WHERE gid = '$gid';\n";
		print UPDATES "$gid\t$htime\n";
		$num_updates += 1;
	    }
	}
    }

    close UPDATES;
    
    return $num_updates;

}

sub is_lord {
    my ($name) = @_;

    if ($name =~ /^Lord/i) {
	return 1;
    }
    
    if ($name =~ /^Baroness/i) {
	return 1;
    }

    if ($name =~ /^Bishop/i) {
	return 1;
    }

    return undef;

}

#----- OLD ---#

sub merge_captions_hansard_old {
    my ($self) = @_;

    my $caption_id = 0;
    my $last_name = '';
    my $time = '';

#    warn Dumper $self->{'captions'};

    foreach my $date (sort keys %{$self->{'hansard'}}) {

	#warn $date;

	foreach my $location (sort keys %{$self->{'hansard'}{$date}}) {

	    #warn $location;

	    # TODO - for major gids that have one or more
	    # children, there is no speaker information. however,
	    # we will have to update the htime of the major gid
	    # with the new htime of its first speech gid (child).

	    # if speech.speaker eq captions.next.speaker: then
	    # $start_time = captions.next.start_time (adjusted to
	    # local time from GMT); discard captions.next; set
	    # $confident = true

	    foreach my $gid (sort keys %{$self->{'hansard'}{$date}{$location}}) {

		# either way: speech.start_time = $start_time

		unless (defined($self->{'hansard'}{$date}{$location}{$gid}{'name'})) {
		    # it's a heading, not a speech - skip it
		    next;
		}

		#warn "$gid: " . $self->{'hansard'}{$date}{$location}{$gid}{'name'};
		#warn "$caption_id: " . $self->{'captions'}{$date}{$location}{$caption_id}{'name'};

		my $caption_current = $self->{'captions'}{$date}{$location}{$caption_id}{'name'};
		my $hansard_current = $self->{'hansard'}{$date}{$location}{$gid}{'name'};
		my $caption_next = $self->{'captions'}{$date}{$location}{$caption_id + 1}{'name'};

		my $cmp_result = compare_names($caption_current, $hansard_current, $caption_next);

		if ($cmp_result) {
		    my $timestamp = $self->{'captions'}{$date}{$location}{$caption_id}{'timestamp'};
		    if ($timestamp =~ /(\d{4}\/\d{2}\/\d{2}) (\d{2}:\d{2}:\d{2})/) {
			$time = $2;
		    }
		    $caption_id += $cmp_result;
		}
		if ($time) {
		    $self->{'updates'}{$date}{$location}{$gid}{'htime'} = $time;
		}

	    }

	}

    }

}

sub write_update_files_OLD {
    my ($self) = @_;

    foreach my $date (sort keys %{$self->{'updates'}}) {
	foreach my $location (sort keys %{$self->{'updates'}{$date}}) {
	    foreach my $gid (sort keys %{$self->{'updates'}{$date}{$location}}) {
#		warn "$gid $date " . $self->{'updates'}{$date}{$location}{$gid}{'htime'};
	    }
	}
    }

#    warn Dumper $self->{'updates'};

    # TODO write out the updated hansard data to file, and hand it
    # over to matthew for him to integrate into TWFY!
	    
}

sub get_captions_data{
    my ($self) = @_;

    $self->get_captions_files();
    $self->process_captions_files();

}

sub get_captions_files {
    my ($self) = @_;

    my $dir_url = $self->{'constants'}{'captions-location'};

    if (defined($self->{'offline'}) && $self->{'offline'} eq 'true') {
#	warn "INFO: Skipping mirror of $dir_url";
	return 1;
    }

#    warn "INFO: Getting directory listing from $dir_url";
    
    my $ua;
    unless ($ua = LWP::UserAgent->new()) {
	warn "FATAL: Cannot create new LWP::UserAgent object; error was $!";
	die;
    }

    my $response = $ua->get($dir_url);

    unless ($response->is_success) {
	warn "FATAL: Could not fetch $dir_url; error was " . $response->status_line();
	die;
    }

    my $root;
    unless ($root = HTML::TreeBuilder->new_from_content($response->content())) {
	warn "FATAL: Cannot create new HTML::TreeBuilder object; error was $!";
	die;
    }

    $root->elementify();

    my @filenames = ();

    for (@{  $root->extract_links('a')  }) {
	my($link, $element, $attr, $tag) = @$_;
	unless ($link =~ /^parliament/) {
	    next;
	}
	push @filenames, $link;
    }

    foreach my $filename (@filenames) {
	my $dir_filename = $self->{'path'}{'captions-files-dir'} . "/$filename";
	unless (-e $dir_filename) {
	    my $dir_url_filename = "$dir_url/$filename";
#	    warn "INFO: getting a copy of $filename";
	    my $mirror_response = $ua->mirror($dir_url_filename,$dir_filename);
	    unless ($mirror_response->is_success()) {
		warn "ERROR: Could not fetch $dir_url_filename; error was " . $response->status_line();
	    }
	}
    }

}


1;
