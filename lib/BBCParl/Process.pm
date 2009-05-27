package BBCParl::Process;

use strict;

use LWP::UserAgent;
use XML::Simple;
use DateTime;
use DateTime::TimeZone;
use Data::Dumper;

use mySociety::Config;
use mySociety::DBHandle qw (dbh);
use BBCParl::Common;
use File::Basename;

sub debug {
    my ($self, $message) = @_;
    if ($self->{'debug'}) {
        warn "DEBUG: $message\n";
    }
    return undef;
}

# TODO make this load channels.conf, check that for channel_ids, and
# then process footage one channel at a time - needs to update across
# multiple subroutines

sub new {
    my ($class) = @_;
    my $self = {};
    bless $self, $class;
    my($filename, $directories, $suffix) = fileparse(__FILE__);
    
    $self->{'path'}{'config-dir'} = $directories . "../../conf/";
    mySociety::Config::set_file($self->{'path'}{'config-dir'} . "general");
    
    $self->{'path'}{'ffmpeg'} = '/usr/bin/ffmpeg';
    $self->{'path'}{'mencoder'} = mySociety::Config::get('MENCODER');
    $self->{'path'}{'yamdi'} = '/usr/bin/yamdi';

    $self->{'path'}{'footage-cache-dir'} = mySociety::Config::get('FOOTAGE_DIR');
    $self->{'path'}{'footage-cache-dir'} .= '/'
        unless $self->{'path'}{'footage-cache-dir'} =~ m{/$};
    $self->{'path'}{'output-dir'} = mySociety::Config::get('OUTPUT_DIR');
    $self->{'path'}{'output-dir'} .= '/'
        unless $self->{'path'}{'output-dir'} =~ m{/$};

    $self->{'constants'}{'tv-schedule-api-url'} = 'http://www0.rdthdo.bbc.co.uk/cgi-perl/api/query.pl';
    
    $self->load_flv_api_config();

    $self->{'params'}{'channel_id'} = ',BBCParl';
    $self->{'params'}{'method'} = 'bbc.schedule.getProgrammes';
    $self->{'params'}{'limit'} = '500';
    $self->{'params'}{'detail'} = 'schedule';
    $self->{'params'}{'format'} = 'simple';
    return $self;
}

sub load_flv_api_config {
    my ($self) = @_;
    
    $self->debug("loading flv api config");

    my $flv_api_config_filename = $self->{'path'}{'config-dir'} . '/flv-api.conf';

    unless (-e $flv_api_config_filename) {
	warn "FATAL: Cannot find file: $flv_api_config_filename";
	die;
    }

    unless(open (FLV_CONFIG, $flv_api_config_filename)) {
	warn "FATAL: Cannot open file: $flv_api_config_filename ($!)";
	die;
    }
    
    while (<FLV_CONFIG>) {
    	if (/^#/) {
    	    next;
    	}
    	if (/(\S+)\s*=\s*(\S+)/) {
    	    $self->{'constants'}{'flv-api-' . $1} = $2;
    	}
    }
    close (FLV_CONFIG);
}

sub get_raw_footage_to_process {
    my ($self) = @_;

    my $st = dbh()->prepare("SELECT filename, start_dt, end_dt FROM raw_footage WHERE status = 'not-yet-processed'");
    $st->execute();

    my $num_files = 0;

    while (my @row = $st->fetchrow_array()) {

	$num_files += 1;
	$self->{'raw-footage-to-process'}{$row[0]}{'start'} = $row[1];
	$self->{'raw-footage-to-process'}{$row[0]}{'end'} = $row[2];

    }

    return $num_files;

}

sub calculate_date_time_range {
    my ($self) = @_;

    my $start = '';
    my $end = '';

    foreach my $filename (sort keys %{$self->{'raw-footage-to-process'}}) {
	$self->debug("Calculating date-range with $filename");
	if ($filename =~ /.+?(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z/) {
	    if ($start eq '' || $start gt $1) {
		$start = $1;
	    }
	    if ($end eq '' || $end lt $2) {
		$end = $2;
	    }
	}
    }
	
    if ($start && $end) {
	$self->{'params'}{'start'} = $start;
	$self->{'params'}{'end'} = $end;
	$self->debug("Files range from $start to $end");
	return ($start, $end);
    } else {
	warn "ERROR: Did not calculate a date-range.";
	return undef;
    }

}

sub update_programmes{
    my ($self) = @_;

    $self->{params}{start} = DateTime->now()->subtract( days => 1 )->datetime();
    $self->{params}{end} = DateTime->now()->datetime();

    # call the BBC TV web api

    my $ua;
    unless ($ua = LWP::UserAgent->new()) {
	warn "FATAL: Cannot create new LWP::UserAgent object; error was $!";
	return undef;
    }

    my $url = $self->{'constants'}{'tv-schedule-api-url'} . '?';

    foreach my $name (keys %{$self->{'params'}}) {
	$url .= "$name=" . $self->{'params'}{$name} . '&';
    }
    $self->debug("Requesting $url");
    my $response = $ua->get($url);

    unless ($response->is_success) {
	warn "FATAL: Could not fetch $url; error was " . $response->status_line();
	return undef;
    }

    my $results = $response->content();

    # convert it into an XML object
    
    my $results_ref = XMLin($results,
			    'ForceArray' => ['programme']);

    if (defined($results_ref->{'error'})) {
	warn "ERROR: Could not fetch data from TV API; error was " . $results_ref->{'error'}{'message'};
	warn "ERROR: URI was $url";
	return undef;
    }

    foreach my $prog_ref (@{$results_ref->{'schedule'}{'programme'}}) {
	my $start = $prog_ref->{'start'};
	map {
	    $self->{'programmes'}{$start}{$_} = $prog_ref->{$_};
	} qw (channel_id synopsis duration title);
	$self->{'programmes'}{$start}{'crid'} = $prog_ref->{'programme_id'};
    }

    # foreach programme, determine the rights situation and the
    # broadcast start/end times - these should be in UTC (GMT)

#    warn Dumper $self;

    foreach my $prog_start (sort keys %{$self->{'programmes'}}) {
	my $title_synopsis = $self->{'programmes'}{$prog_start}{'title'} . ' ' .  $self->{'programmes'}{$prog_start}{'synopsis'};
	my $location = '';
	my $rights = 'none';

	if ($title_synopsis =~ /^Lords/i ||
	    $title_synopsis =~ /^House of Lords/i ||
	    $title_synopsis =~ /^Live.*?Lords/i) {
	    $location = 'lords';
	    $rights = 'internet';
	} elsif ($title_synopsis =~ /^(Live )?Scottish/i) {
	    $location = 'scottish';
	    $rights = 'internet';
	} elsif ($title_synopsis =~ /^Westminster Hall/i) {
	    $location = 'westminster-hall';
	    $rights = 'internet';
	} elsif ($title_synopsis =~ /^(Live )?(Northern Ireland|NI)(?! Questions)/i) {
	    $location = 'northern-ireland';
	    $rights = 'internet';
	} elsif ($title_synopsis =~ /^(Live )?Welsh/i) {
	    $location = 'welsh';
	    $rights = 'internet';
	} elsif ($title_synopsis =~ /^Mayor/i) {
	    $location = 'gla';
	    $rights = 'internet';
	} elsif ($title_synopsis =~ /^(Live )?House of Commons/i ||
		 $title_synopsis =~ /^Commons/i ||
		 $title_synopsis =~ /(in|to) the (House of )?Commons /i ||
		 $title_synopsis =~ /^.+? Bill/i ||
		 $title_synopsis =~ /^.+? Committee/i ||
		 $title_synopsis =~ /^.+? Questions/i ||
		 $title_synopsis =~ /Budget/i ||
		 $title_synopsis =~ /recorded coverage of the .+? committee session/i) {
	    $location = 'commons';
	    $rights = 'internet';
	} else {
	    $location = 'other';
	    $rights = 'none';
	}
	unless ($rights) {
	    $rights = 'none';
	}

	$self->{'programmes'}{$prog_start}{'rights'} = $rights;
	$self->{'programmes'}{$prog_start}{'location'} = $location;

	my $duration = $self->{'programmes'}{$prog_start}{'title'} . ' ' .  $self->{'programmes'}{$prog_start}{'duration'};

	# work out the start/end date-times for broadcast (on air)

	my $broadcast_start = $prog_start;
	my $broadcast_end = '';

	my @date_time = ();
	if ($broadcast_start =~ /(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z/) {
	    @date_time = ('year' => $1,
			  'month' => $2,
			  'day' => $3,
			  'hour' => $4,
			  'minute' => $5,
			  'second' => $6);
	} else {
	    warn "ERROR: $broadcast_start does not contain an hh:mm:ss time";
	    warn "ERROR: skipping this programme";
	    next;
	}

	my $dt = DateTime->new(@date_time,'time_zone','UTC');

	if ($duration =~ /(\d{2}):(\d{2}):(\d{2})/) {
	    $dt->add('hours' => $1,
		     'minutes' => $2,
		     'seconds' => $3);
	    my $date_time_format = '%FT%TZ';
	    $broadcast_end = $dt->strftime($date_time_format);
	}

	$self->{'programmes'}{$prog_start}{'broadcast_start'} = $broadcast_start;
	$self->{'programmes'}{$prog_start}{'broadcast_end'} = $broadcast_end;

	# foreach programme, work out the recording start/end times
	# given duration (if possible) - these should be in UTC (GMT)

	my ($rec_start, $rec_end) = ('','');

	if ($title_synopsis =~ /^live/i || $title_synopsis =~ /\s+live\s/i) {

	    # live broadcasts are easy, record date/time == broadcast date/time
	    $rec_start = $broadcast_start;
	    $rec_end = $broadcast_end;

	} else {

	    # TODO - try to extract the recording date from the
	    # title/synopsis? this will also need us to find out when
	    # the relevant meeting or debate started. not doing this
	    # for the initial release.

	}

	$self->{'programmes'}{$prog_start}{'record_start'} = $rec_start;
	$self->{'programmes'}{$prog_start}{'record_end'} = $rec_end;
	
	# foreach different recorded programme, create a
	# unique_id - note that some programmes may be broadcast
	# multiple times between $start and $end date-times

	# NOTE - to be able to distinguish between different airings
	# of the same programme, we need to know the recording date -
	# but for the moment, we only have this for live broadcasts,
	# so we'll use $broadcast_start for the moment. TODO - fix
	# this once we have resolved the question of recording
	# date/times.

	# foreach unique_id, check whether it has been added to
	# the db, and if yes, then whether already been processed or
	# flagged for processing (db column processing-status)

    
	if (dbh()->selectrow_array('SELECT broadcast_start FROM programmes WHERE broadcast_start = ? AND channel_id = ?',
				   {},
				   $prog_start,
				   $self->{'programmes'}{$prog_start}{'channel_id'},
				   )) {
	    $self->debug("$prog_start is already in the database; skipping duplicate database insert.");
	    next;
	}

	#warn Dumper $self->{'programmes'}{$prog_start};

	my @params = qw (location broadcast_start broadcast_end title synopsis crid channel_id rights);
	if ($self->{'programmes'}{$prog_start}{'record_start'}) {
	    push @params, qw (record_start record_end);
	}

	{
	    dbh->do("INSERT INTO programmes (" . join (',', @params) . ") VALUES (" . join (',', map {'?'} @params) . ")",
		    {},
		    map {
			$self->{'programmes'}{$prog_start}{$_};
		    } @params);
	}
       
	dbh()->commit();

    }

}

sub update_footage_status {
    my ($self) = @_;

    foreach my $filename (keys %{$self->{'raw-footage-to-process'}}) {
	$self->debug("setting status = 'processed' for $filename");

	dbh()->do(
		  "UPDATE raw_footage SET status = 'processed' WHERE filename = ?",
		  {},
		  $filename);
	
    }

    dbh()->commit();

    return 1;

}

sub get_processing_requests {
    my ($self) = @_;

    my $st = dbh()->prepare("SELECT id, location, broadcast_start, broadcast_end, channel_id FROM programmes WHERE status = 'not-yet-processed' AND rights != 'none' ORDER BY broadcast_start asc");
    $st->execute();

    # TODO - fetch all programmes, filter by rights; for "internet"
    # process as normal; for all others, update status to
    # "will-not-process" (since we don't have the rights)

    $self->{requests} = [];
    while (my @row = $st->fetchrow_array()) {

	my %data = ( 'id' => $row[0],
		     'location' => $row[1],
		     'broadcast_start' => $row[2],
		     'broadcast_end' => $row[3],
		     'channel_id' => $row[4],
		     'action' => 'process-raw-footage',
		     'formats' => 'flash,mp4,thumbnail');
	
	# TODO - make this work for all channels (have to specify what
	# channels to process in an input param somewhere)

	if (lc($data{'channel_id'}) eq 'bbcparl') {
	    $data{'channel_id'} = 'parliament';
	}
	
	push @{$self->{requests}}, { %data };

	# TODO - need to include thumbnails
	# NOTE: mplayer $inputFilename -ss $timeOffsetInSeconds
	# -nosound -vo jpeg:outdir=$outDir -frames 1 will always
	# generate two thumbnails (from
	# http://gallery.menalto.com/node/40548)
    }

    return scalar @{$self->{requests}};
}

sub login_to_flv_api {
    my ($self, $ua) = @_;

    my %form = ('username' => $self->{'constants'}{'flv-api-username'},
                'password' => $self->{'constants'}{'flv-api-password'}, 
                'dologin' => '1');

    my $url = $self->{'constants'}{'flv-api-url'};
    $self->debug("logging into  $url");
    my $response = $ua->post( $url, \%form ); 
    unless ($response->is_success) {
	    warn "FATAL: Could not fetch $url; error was " . $response->status_line();
	    return undef;
    }
    my $content = $response->content();
    unless ($content =~ /Logged in/){
        warn "FATAL: Could not log in to flv API";
        return undef;
    }    
    
    return 1;
}

sub get_broadcast_date_and_time{
    my ($self, $broadcast_start) = @_;
    my $broadcast_date;
    my $broadcast_time;
    if ($broadcast_start =~ /(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})/){
        $broadcast_date = $1;
        $broadcast_time = $2;
        $broadcast_time =~ s/:/-/g;
        return ($broadcast_date, $broadcast_time);
    }else{
        warn "FATAL: Could not get date and time for programme";
        return (undef, undef);
    }    
    
}

sub find_xml_url{
    my ($self, $ua, $broadcast_date, $broadcast_time) = @_;
 
    my $programme_url = $self->{'constants'}{'flv-api-url'} . $self->{'constants'}{'flv-api-programme-path'};
    $programme_url = $programme_url . $broadcast_date . '/' . $broadcast_time;
    $self->debug("requesting $programme_url");
    my $response = $ua->get($programme_url);

    unless ($response->is_success) {
	    warn "FATAL: Could not fetch $programme_url; error was " . $response->status_line();
	    return undef;
    }
    my $content = $response->content();
    unless ($content =~ /Logged in/){
        warn "FATAL: Logged out of flv API";
        return undef;
    } 
    return $self->get_xml_url($content);
    
}

sub get_xml_url(){
    my ($self, $text) = @_;
    my $xml_url_string =  '(' . $self->{'constants'}{'flv-api-url'} . 'programme/\d+/pp/flvxml)';
    if ($text =~ m#$xml_url_string#){
        my $xml_url = $1;
        return $xml_url;
    }else{
        warn "FATAL: Could not get xml url";
        return undef;
    }
}

sub find_flv_url {
    
    my ($self, $ua, $xml_url) = @_;
    $self->debug("requesting $xml_url");
    my $response = $ua->get($xml_url);
    unless ($response->is_success) {
	    warn "FATAL: Could not fetch $xml_url; error was " . $response->status_line();
	    return undef;
    }
    my $content = $response->content();
    return $self->get_flv_url($content);
}

sub get_flv_url{
    my ($self, $text) = @_;
    my $flv_string = '<location>/(programme/\d+/download/.*?/flash.flv)</location>';
    if ($text =~ m#$flv_string#){
        my $flv_path = $1;
        return $self->{'constants'}{'flv-api-url'} . $flv_path;
    }else{
        warn "FATAL: Could not get flv url";
        return undef;
    }
}

sub get_flv_file{
    
    my ($self, $ua, $flv_url, $output_dir, $prog_id) = @_;
    $self->debug("requesting $flv_url");
    my $request = HTTP::Request->new(GET => $flv_url);
    my $response = $ua->request($request, $output_dir . $prog_id . '.flv');
    unless ($response->is_success) {
	    warn "FATAL: Could not fetch $flv_url; error was " . $response->status_line();
	    return undef;
    }
    return 1;
}

sub process_flv_file{
    
    my ($self, $output_dir, $prog_id) = @_;
    # update FLV file cue-points using yamdi
    my $yamdi = $self->{'path'}{'yamdi'};
    my $yamdi_input = "$output_dir$prog_id.flv";
    my $yamdi_output = "$yamdi_input.yamdi";

    $self->debug("adding FLV metadata (using $yamdi on $yamdi_input)");

    my $yamdi_command = "$yamdi -i $yamdi_input -o $yamdi_output";
    my $yamdi_command_output =`$yamdi_command`;

    my $status = "footage-not-available";

    if (-e $yamdi_output) {
        my $file_size = (stat $yamdi_output)[7];
        if ($file_size <= 4096) {
            warn "ERROR: Empty file ($file_size), footage-not-available";
        } else {
            my $final_output_filename = $self->{'path'}{'output-dir'} . "$prog_id.flv";
            my $move = system("mv $yamdi_output $final_output_filename"); # cross domain
            if ($move) {
                warn "ERROR: Could not move $yamdi_output to $final_output_filename: $move";
            } else {
                unlink $yamdi_input;
                $status = 'available';
            }
        }

    } else {
        warn "ERROR: could not find $yamdi_output";
        warn "ERROR: Need to re-run yamdi on $prog_id.flv to add cue points";
        warn "ERROR: yamdi said: $yamdi_command_output";
    }

    $self->set_prog_status($prog_id, $status);
}

sub get_flv_files_for_programmes {

    my ($self) = @_;
    my $ua;
    $self->debug("Setting up user agent");
    unless ($ua = LWP::UserAgent->new(cookie_jar => {})) {
	    warn "FATAL: Cannot create new LWP::UserAgent object; error was $!";
	    return undef;
    }
    
    my $output_dir = $self->{'path'}{'footage-cache-dir'};
    return undef unless $self->login_to_flv_api($ua);

    
    foreach my $request (@{$self->{requests}}) {
        
        my $start_p = $request->{broadcast_start};
        my $prog_id = $request->{id};
        $self->debug("Getting broadcast date and time");
        my ($broadcast_date, $broadcast_time) = $self->get_broadcast_date_and_time($start_p);
        return undef unless $broadcast_date;
         
        my $xml_url = $self->find_xml_url($ua, $broadcast_date, $broadcast_time);
        sleep 10;
        
        unless ($xml_url){
            $self->skip_programme($prog_id);
            next;
        }
        
        my $flv_url = $self->find_flv_url($ua, $xml_url);
        sleep 10;
        
        unless ($flv_url){
            $self->skip_programme($prog_id);
            next; 
        }
        
        my $flv_saved = $self->get_flv_file($ua, $flv_url, $output_dir, $prog_id);
        sleep 10;
        
        unless ($flv_saved){
            $self->skip_programme($prog_id);
            next; 
        }       
        
        $self->process_flv_file($output_dir, $prog_id);
    }
    
    return 1;
    
}

sub skip_programme{
    my ($self, $prog_id) = @_;
    warn "ERROR: skipping request $prog_id and marking as footage-not-available";
    $self->set_prog_status($prog_id, "footage-not-available");
}

sub get_footage_for_programmes {
    my ($self) = @_;

    my $progs_to_process = 0;

    foreach my $request (@{$self->{requests}}) {
	my $start_p = $request->{broadcast_start};
	my $end_p = $request->{broadcast_end};
	
	my $sql = "select filename, start_dt, end_dt from raw_footage where channel_id = ? and "
	    . "( "
	    . "( ( start_dt <= ? or start_dt <= ?) and ( end_dt >= ? or end_dt >= ? ) ) "
	    . " or "
	    . "( ( start_dt > ? ) and ( end_dt < ? ) ) "
	    . ") order by filename asc;";

	# TODO - make this work for all channels (have to specify what
	# channels to process in an input param somewhere)

	my $channel_id = 'BBCParl';

	my $st = dbh()->prepare($sql);
	$st->execute($channel_id,
		     $start_p, $end_p,
		     $start_p, $end_p,
		     $start_p, $end_p);

	my @filenames = ();
	
	# determine which footage files should be addressed for this programme
    
	while (my @row = $st->fetchrow_array()) {

	    my $filename = $row[0];
	    my $start_dt = $row[1];
	    my $end_dt = $row[2];

	    push @filenames, $filename;
	    next;

#	    $self->debug("check between $start_dt and $end_dt ($filename)");
#	    if ($start_p gt $end_dt && $end_p gt $end_dt) {
#		$self->debug("Skipping $filename");
#	    } elsif ($start_p lt $end_dt && $end_p gt $start_dt) {
#		$self->debug("hit on $filename");
#		push @filenames, $filename;
#	    } elsif ($start_p lt $end_dt && $end_p lt $end_dt) {
#		$self->debug("final hit on $filename");
#		push @filenames, $filename;
#		last;
#	    }
	}

	if (@filenames) {
	    $request->{footage} = [ @filenames ];
	    $progs_to_process += 1;
	}
    }

    return $progs_to_process;
}

sub process_requests { 
   my ($self) = @_;

   foreach my $request (@{$self->{requests}}) {

       my $prog_id = $request->{id};
       my ($start, $end) = map { $request->{$_} } qw (broadcast_start broadcast_end);

       unless (defined($request->{footage})) {
	   warn 'ERROR: No footage was defined for request ' . $prog_id . '; skipping processing for this request.';
	   $self->set_prog_status($prog_id, "footage-not-available");
	   next;
       }

       $self->debug("Processing request for ID $prog_id, $start - $end");

       # calculate the offset(s) for each file of raw footage
       my $encoding_args = ();
       my @files_used = ();
       my @filenames = sort @{$request->{footage}};
       for (my $i = 0; $i < @filenames; $i++) {

	   my $last_file = undef;
	   my $filename = $filenames[$i];

	   # remove bucket name from $filename

	   if ($filename =~ /^(.+?)([^\/]+)$/) {
	       $filename = $2;
	   }

	   my ($file_start, $file_end) = BBCParl::Common::extract_start_end($filename);
	   map { s/Z//; } ($file_start, $file_end);

	   # does the footage end before this file starts?
	   if ($end lt $file_start) {
	       $self->debug("Programme already ended, skipping $filename");
	       last;
	   }

	   # at least some of the this file is needed - work out how
	   # much of this file we need to convert

	   # calculate how many secs between $file_start and $start
	   # if start >= file_start, calculate offset
	   # else offset = 0;

	   my $offset = 0;
	   my $slice_start;
	   if ($start ge $file_start) {
	       $offset = calculate_offset($start, $file_start);
	       $slice_start = $start;
	   } else {
	       $slice_start = $file_start;
	   }
	   
	   # do we need to use footage from the next file?

	   my $duration = 0;
	   if ($end le $file_end) {

	       # this will be the final slice - find the duration
	       # between the start of this slice (either $file_start
	       # or $start) and $end

	       $duration = calculate_offset($slice_start, $end);
	       $last_file = 'true';

	   } else {

	       # we'll be using footage from the next file, so
	       # calculate when the next file starts and use
	       # everything from this file up to that point

	       # first, check if there is another file!

	       if (($i + 1 < @filenames) && (my $next_filename = $filenames[$i+1])) {
		   
		   my ($next_start,$next_end) = BBCParl::Common::extract_start_end($next_filename);

		   # if the next file starts before start, we can just
		   # use that footage, so skip the current file

		   if ($next_start lt $start) {
		       $self->debug("Not using $filename, as next file starts before start of needed footage");
		       next;
		   } else {
		       $duration = calculate_offset($slice_start, $next_start);
		   }

	       } else {

		   # the other file is needed, but missing! just go up
		   # to the end of this file.

		   $duration = calculate_offset($slice_start, $file_end);

	       }

	   }

	   $self->debug("$filename, offset ${offset}s, duration ${duration}s");

	   $encoding_args->{$filename}{'duration'} = $duration;
	   $encoding_args->{$filename}{'offset'} = $offset;

	   push @files_used, $filenames[$i];

	   if ($last_file) {
	       last;
	   }

       }

       unless (@files_used) {
	   warn "ERROR: No files were marked as being of use for request $prog_id; skipping this request.";
	   $self->set_prog_status($prog_id, "footage-not-available");
	   next;
       }
   
       # TODO - make this a loop that operates on each encoding type
       # in turn (e.g. flv, mp4, thumbnails)

       # now comes the video encoding, which is done in several stages
       # by a mixture of ffmpeg and mencoder

       my $mencoder = $self->{'path'}{'mencoder'};
       my $ffmpeg = $self->{'path'}{'ffmpeg'};
       my $output_dir = $self->{'path'}{'footage-cache-dir'};
   
       my $avi_args = undef;
       my $intermediate = 0;

       # extract video file slices from the MPEG files

       my @video_slices = ();
       $intermediate = 0;
       my $skip_request = undef;

       foreach my $filename (@files_used) {

	   if ($filename =~ /^(.+?)([^\/]+)$/) {
	       $filename = $2;
	   }

	   my $input_dir_filename = $self->{'path'}{'footage-cache-dir'} . $filename;
	   my $output_dir_filename = "$output_dir$prog_id.slice.$intermediate.flv";

	   unless ($input_dir_filename) {
	       warn "ERROR: No filename specified, cannot perform conversion on an empty file";
	       $skip_request = 1;
	       last;
	   }

	   unless (-s $input_dir_filename) {
	       warn "ERROR: Cannot find $input_dir_filename or is empty";
	       $skip_request = 1;
	       last;
	   }

	   my $duration = $encoding_args->{$filename}{'duration'};
	   my $offset = $encoding_args->{$filename}{'offset'};

	   # TODO - maybe add "-mc 0" to input params?

	   my $flash_args = " -ss $offset -t $duration -i $input_dir_filename $output_dir_filename";
	   #$flash_args .= "$output_dir_filename -ovc lavc -oac lavc";

	   my $start_time = time();
	   my $ffmpeg_output = `$ffmpeg -v quiet $flash_args 2>&1`;
	   $self->debug("Creating FLV slice $intermediate, encoding took " . (time()-$start_time) . 's');

	   # TODO - the following error-catching code doesn't seem to
	   # work (reliably)

	   if ($ffmpeg_output =~ /^(.+ error .+)$/im) {
	       warn "ERROR: Error in converting $filename";
	       warn "ERROR: Error was: $1";
	       $skip_request = 1;
	       last;
	   }

           if (-s $output_dir_filename <= 4096) {
	       warn "ERROR: File does not exist or is <4k in size ($output_dir_filename)";
	       $skip_request = 1;
               last;
	   }

	   push @video_slices, $output_dir_filename;
	   $intermediate += 1;
       }

       if ($skip_request) {
	   warn "ERROR: Unrecoverable error; skipping request $prog_id and marking as footage-not-available";
	   $self->set_prog_status($prog_id, "footage-not-available");
	   next;
       }

       # if there is more than one slice, concatenate them all using
       # mencoder
       if (@video_slices > 1) {

	   my $input_filenames = join (' ', @video_slices);
	   my $output_dir_filename = "$output_dir$prog_id.flv";

	   # TODO - should the audio codec be mp3 (rather than copy)?
	   # TODO - check for errors in $mencoder_output
	   my $mencoder_command = "$mencoder $input_filenames -o $output_dir_filename -of lavf -oac copy -ovc lavc -lavcopts vcodec=flv 2>&1";
	   `$mencoder_command`;

	   # remove the incremental slice files
	   foreach (@video_slices) {
	       my $unlink_ret_value = unlink $_;
	       unless ($unlink_ret_value == 1) {
		   warn "ERROR: Did not delete $_; unlink return value was $unlink_ret_value";
	       }
	   }
	   
       } else {
	   rename "$output_dir$prog_id.slice.0.flv", "$output_dir$prog_id.flv";
       }
       $self->process_flv_file($output_dir, $prog_id);

   }

   return 1;
}

sub set_prog_status {
    my ($self, $prog_id, $status) = @_;
    $self->debug("setting programme $prog_id to status $status");
    dbh()->do(
	      "UPDATE programmes SET status = ? WHERE id = ?",
	      {},
	      $status,
	      $prog_id);
    dbh()->commit();
}

sub cache_cleanup {
    my ($self) = @_;
    
    # TODO - remove and replace with a separate cache-cleaning process
    
    # Once we've done all the requests in the queue, remove all mpeg
    # files from the local raw-footage cache more than 3 days old

    my $days_to_keep = 7;
    
    my $cutoff_dt = DateTime->now();
    $cutoff_dt->subtract( days => $days_to_keep );
    my $cutoff = $cutoff_dt->datetime();

    $self->debug("cache_cleanup for raw-footage: cutoff datetime is $cutoff");

    my $raw_footage_dir = $self->{'path'}{'footage-cache-dir'};
    
    # list all files in raw-footage

    # foreach my $filename (@files) {
    # extract the end-time
    # if end-time < $ymd_hms, unlink $filename

    my @filenames = split("\n",`ls $raw_footage_dir`);

    foreach my $filename (sort @filenames) {
	if ($filename =~ /.+(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z.mpeg/) {
	    if ($1 lt $cutoff) {
		#$self->debug("unlinking $filename");
		unlink "$raw_footage_dir/$filename";
	    }
	}
    }

    return 1;

}

sub calculate_offset {
    my ($d1, $d2) = @_;

    #warn "$d1 <-> $d2";

    my @d1 = BBCParl::Common::extract_datetime_array ($d1);
    my @d2 = BBCParl::Common::extract_datetime_array ($d2);
	       
    my $dt = DateTime->new(@d1);
    my $diff = $dt->subtract_datetime_absolute( DateTime->new(@d2));
    return $diff->seconds();
}


sub mirror_footage_locally {
    my ($self) = @_;

    warn "DEBUG: All mpeg files should already be available locally";

    my $store = BBCParl::S3->new();
    my $bucket = $self->{'constants'}{'raw-footage-bucket'};
    my $dir = $self->{'path'}{'footage-cache-dir'};

    # XXX
    foreach my $request_id (sort keys %{$self->{'requests'}}) {
	my @filenames = split (',', $self->{'requests'}{$request_id}{'footage'});
	foreach my $filename (@filenames) {
	    if ($self->{'mirror-footage'}{$filename}) {
		next;
	    }
	    if ($filename =~ /^(.+?)\/(.+)$/) {
		$bucket = $1;
		$filename = $2;
	    }
	    warn "DEBUG: fetching $filename";
	    if (my $dir_file = $store->get($bucket, $dir, $filename)) {
		$self->{'mirror-footage'}{$filename} = $dir_file;
		warn "DEBUG: file size is " . `ls -s $dir_file`;
	    } else {
		return undef;
	    }
	}
    }

    return 1;

}

1;
