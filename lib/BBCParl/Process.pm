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

    mySociety::Config::set_file("$FindBin::Bin/../conf/general");

    $self->{'path'}{'ffmpeg'} = '/usr/bin/ffmpeg';
    $self->{'path'}{'mencoder'} = mySociety::Config::get('MENCODER');
    $self->{'path'}{'yamdi'} = '/usr/bin/yamdi';

    $self->{'path'}{'footage-cache-dir'} = mySociety::Config::get('FOOTAGE_DIR');
    $self->{'path'}{'output-dir'} = mySociety::Config::get('OUTPUT_DIR');

    $self->{'constants'}{'tv-schedule-api-url'} = 'http://www0.rdthdo.bbc.co.uk/cgi-perl/api/query.pl';

    $self->{'params'}{'channel_id'} = ',BBCParl';
    $self->{'params'}{'method'} = 'bbc.schedule.getProgrammes';
    $self->{'params'}{'limit'} = '500';
    $self->{'params'}{'detail'} = 'schedule';
    $self->{'params'}{'format'} = 'simple';

    return $self;
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


sub update_programmes_from_footage {
    my ($self) = @_;

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
#	    $rights = 'internet';
	} elsif ($title_synopsis =~ /^Scottish/i) {
	    $location = 'scottish';
#	    $rights = 'internet';
	} elsif ($title_synopsis =~ /^Westminster Hall/i) {
	    $location = 'westminster-hall';
#	    $rights = 'internet';
	} elsif ($title_synopsis =~ /^Northern Ireland Assembly/i) {
	    $location = 'northern-ireland';
#	    $rights = 'internet';
	} elsif ($title_synopsis =~ /^Welsh/i) {
	    $location = 'welsh';
#	    $rights = 'internet';
	} elsif ($title_synopsis =~ /^Mayor/i) {
	    $location = 'gla';
#	    $rights = 'internet';
	} elsif ($title_synopsis =~ /^House of Commons/i ||
		 $title_synopsis =~ /^Live House of Commons/i ||
		 $title_synopsis =~ /^Commons/i ||
		 $title_synopsis =~ /in the House of Commons /i ||
		 $title_synopsis =~ /^.+? Bill/i ||
		 $title_synopsis =~ /^.+? Committee/i ||
		 $title_synopsis =~ /^.+? Questions/i ||
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

       $self->debug("\nProcessing request for ID $prog_id, $start - $end");

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
       my $output_dir = $self->{'path'}{'output-dir'};
   
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
	   my $output_dir_filename = "$output_dir/$prog_id.slice.$intermediate.flv";

	   unless ($input_dir_filename) {
	       warn "ERROR: No filename specified, cannot perform conversion on an empty file";
	       $skip_request = 1;
	       last;
	   }

	   unless (-e $input_dir_filename) {
	       warn "ERROR: Cannot find $input_dir_filename";
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
	   }

	   unless (-e $output_dir_filename) {
	       warn "ERROR: Cannot find file $output_dir_filename";
	       warn "ERROR: ffmpeg output was:";
	       warn $ffmpeg_output;
	       $skip_request = 1;
	   }

	   my $file_size = `ls -sh $output_dir_filename`;

	   if ($file_size eq '4.0K') {
	       warn "ERROR: Fragment is empty (4.0k file size), skipping rest of the fragments ($output_dir_filename)";
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
	   my $output_dir_filename = "$output_dir/$prog_id.flv";

	   # TODO - should the audio codec be mp3 (rather than copy)?
	   # TODO - check for errors in $mencoder_output
	   my $mencoder_command = "$mencoder $input_filenames -o $output_dir_filename -of lavf -oac copy -ovc lavc -lavcopts vcodec=flv 2>&1";
	   `$mencoder_command`;

	   # remove the incremental slice files

	   for (my $i = 0; $i < @files_used; $i++) {
	       my $file_to_unlink = "$output_dir/$prog_id.slice.$i.flv";
	       my $unlink_ret_value = unlink ("$file_to_unlink");
	       unless ($unlink_ret_value == 1) {
		   warn "ERROR: Did not delete $file_to_unlink; unlink return value was $unlink_ret_value";
	       }
	   }
	   
       } else {
	   rename "$output_dir/$prog_id.slice.0.flv", "$output_dir/$prog_id.flv";
       }

       my $final_output_filename = "$output_dir/$prog_id.flv";
       
       # update FLV file cue-points using yamdi

       my $yamdi = $self->{'path'}{'yamdi'};
       my $yamdi_input = $final_output_filename;
       my $yamdi_output = "$yamdi_input.yamdi";

       $self->debug("adding FLV metadata (using $yamdi on $yamdi_input)");

	my $yamdi_command = "$yamdi -i $yamdi_input -o $yamdi_output";
	my $yamdi_command_output =`$yamdi_command`;

	if (-e $yamdi_output) {
	    rename $yamdi_output, $yamdi_input;
	} else {
	    warn "ERROR: could not find $yamdi_output";
	    warn "ERROR: Need to re-run yamdi on $prog_id.flv to add cue points";
	    warn "ERROR: yamdi said: $yamdi_command_output";
	}

       my $status = 'available';

       my $file_size = `ls -sh $final_output_filename`;

       unless ($file_size) {
	   $status = "footage-not-available";
       }

       if ($file_size) {
	   if ($file_size eq '4.0K') {
	       warn "ERROR: Empty file, footage-not-available";
	       $status = "footage-not-available";
	   }
       }
	   
       $self->set_prog_status($prog_id, $status);

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

    my $days_to_keep = 3;
    
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
		$self->debug("unlinking $filename");
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
