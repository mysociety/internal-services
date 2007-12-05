package BBCParl::Process;

use strict;

use DateTime;
use File::Copy;

use Data::Dumper;

use BBCParl::SQS;
use BBCParl::EC2;
use BBCParl::S3;

use mySociety::Config;

sub debug {
    my ($self, $message) = @_;
    if ($self->{'debug'}) {
        warn "DEBUG: $message";
    }
    return undef;
}

sub new {
    my ($class) = @_;
    my $self = {};
    bless $self, $class;

    mySociety::Config::set_file("$FindBin::Bin/../conf/general");

    $self->{'path'}{'home-dir'} = (getpwuid($<))[7];
#    $self->{'path'}{'aws'} = $self->{'path'}{'home-dir'} . "/bin/aws/aws";
    $self->{'path'}{'ffmpeg'} = '/usr/bin/ffmpeg';
    $self->{'path'}{'mencoder'} = '/usr/bin/mencoder';
    $self->{'path'}{'flvtool2'} = '/usr/bin/flvtool2';
    $self->{'path'}{'yamdi'} = $self->{'path'}{'home-dir'} . '/bin/yamdi';

    $self->{'path'}{'processing-dir'} = '/mnt/processing';
    $self->{'path'}{'footage-cache-dir'} = $self->{'path'}{'processing-dir'} .'/raw-footage/bbcparliament';
    $self->{'path'}{'output-cache-dir'} = $self->{'path'}{'processing-dir'} .'/output';

    $self->{'constants'}{'raw-footage-bucket'} = mySociety::Config::get('BBC_BUCKET_RAW_FOOTAGE');
    $self->{'constants'}{'programmes-bucket'} = mySociety::Config::get('BBC_BUCKET_PROGRAMMES');

    # raw-footage is ec2->bitter
    $self->{'constants'}{'raw-footage-queue'} = mySociety::Config::get('BBC_QUEUE_RAW_FOOTAGE');
    # processing-requests is bitter->ec2
    $self->{'constants'}{'processing-requests-queue'} = mySociety::Config::get('BBC_QUEUE_PROCESSING_REQUESTS');
    # available-programmes is ec2->bitter
    $self->{'constants'}{'available-programmes-queue'} = mySociety::Config::get('BBC_QUEUE_AVAILABLE_PROGRAMMES');

    return $self;
}

sub run {
    my ($self) = @_;

    # in this function, we check for new processing requests (Amazon
    # SQS queue) and convert the appropriate part(s) of the specified
    # raw footage file(s) to flash video; the flash video file for
    # each new programme (request) is uploaded to Aaazon S3 storage,
    # and a new message is added to Amazon SQS telling the central
    # server that a new flash video file is available for streaming.

    unless ($self->get_processing_requests()) {
	return 0;
    }

    unless ($self->process_requests()) {
	return 0;
    }

    unless ($self->cache_cleanup()) {
	return 0;
    }

    return 1;
}

sub get_processing_requests {
    my ($self) = @_;

    my $q = BBCParl::SQS->new();

    my $requests_queue = $self->{'constants'}{'processing-requests-queue'};
    my $request_id = 0;

    $self->debug("Checking for messages from the processing queue (EC2)");

    my $messages_to_get = 2;

    while ($messages_to_get > 0) {
	$self->debug("DEBUG: Checking the queue for a new message");
	my ($message_body, $queue_url, $message_id) = $q->receive($requests_queue);
	if ($message_id) {
	    #warn "DEBUG: Got $message_id";
	    $self->{'requests'}{$request_id}{'message-id'} = $message_id;
	    foreach my $line (split("\n",$message_body)) {
		if ($line =~ /(.+)=(.+)/) {
		    $self->{'requests'}{$request_id}{$1} = $2;
		}
	    }
	    $self->{'processing-requests-queue'}{'queue-url'} = $queue_url;

	    $self->debug("DEBUG: Removing request $request_id from the processing queue");

	    my $retries = 5;

	    while ($retries > 0) {

		if ($q->delete($self->{'processing-requests-queue'}{'queue-url'},
				   $self->{'requests'}{$request_id}{'message-id'})) {
		    last;
		} else {
		    warn "ERROR: Did not remove request $request_id from the procesing queue";
		    $retries -= 1;
		    sleep 10;
		}
	    }

	    $messages_to_get -= 1;
	    $request_id += 1;

	} else {
	    $self->debug("DEBUG: No more messages in queue");
	    last;
	}

    }

    return 1;

}

sub process_requests { 
   my ($self) = @_;

   my $q = BBCParl::SQS->new();

   $self->debug("DEBUG: starting to process requests");

#   warn "DEBUG: preparing to mirror footage on local storage";

   my $skip_request = undef;

#   unless ($self->mirror_footage_locally()) {
#       warn "DEBUG: Did not mirror necessary footage; unrecoverable error, skipping request.";
#       $skip_request = 1;
#   }
   
   foreach my $request_id (sort keys %{$self->{'requests'}}) {

       $skip_request = undef;

       my $encoding_args = ();

       unless (defined($self->{'requests'}{$request_id}{'footage'})) {
	   warn "ERROR: No footage was defined for request $request_id; skipping processing for this request.";
	   $skip_request = 1;
       }

       # calculate the offset(s) for each file of raw footage

       $self->debug("DEBUG: Calculating offsets for FLV encoding");

       my ($start,$end) = map { $self->{'requests'}{$request_id}{$_}; } qw (broadcast_start broadcast_end);

       my @files_used = ();
       my @filenames = sort split (',', $self->{'requests'}{$request_id}{'footage'});
       for (my $i = 0; $i < @filenames; $i++) {

	   if ($skip_request) {
	       last;
	   }

	   my $last_file = undef;
	   my $filename = $filenames[$i];

	   # remove bucket name from $filename

	   if ($filename =~ /^(.+?)\/(.+)$/) {
	       $filename = $2;
	   }

	   $self->debug("Calculating offset for $filename");

	   my ($file_start, $file_end) = BBCParl::EC2::extract_start_end($filename);
	   map { s/Z//; } ($file_start, $file_end);

	   # does the footage end before this file starts?
	   if ($end lt $file_start) {
	       $self->debug("DEBUG: Programme already ended, skipping $filename");
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
	   
	   $self->debug("offset is $offset seconds ($start and $file_start)");
	   
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
		   
		   my ($next_start,$next_end) = BBCParl::EC2::extract_start_end($next_filename);

		   # if the next file starts before start, we can just
		   # use that footage, so skip the current file

		   if ($next_start lt $start) {
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

	   $self->debug("duration is $duration");

	   $encoding_args->{$filename}{'duration'} = $duration;
	   $encoding_args->{$filename}{'offset'} = $offset;

	   push @files_used, $filenames[$i];

	   if ($last_file) {
	       last;
	   }

       }

       unless (@files_used) {
	   warn "ERROR: No files were marked as being of use for this request; skipping this request.";
	   $skip_request = 1;
       }
   
       $self->debug("DEBUG: Encoding args are:");

       $self->debug(Dumper $encoding_args);

       # now comes the video encoding, which is done in several stages
       # by a mixture of ffmpeg and mencoder

       my $mencoder = $self->{'path'}{'mencoder'};
       my $ffmpeg = $self->{'path'}{'ffmpeg'};
       my $prog_id = $self->{'requests'}{$request_id}{'id'};
       my $output_dir = $self->{'path'}{'output-cache-dir'};
   
       my $avi_args = undef;
       my $intermediate = 0;

       # extract FLV file slices from the MPEG files

       my @flv_slices = ();
       $intermediate = 0;

       foreach my $filename (@files_used) {

	   if ($skip_request) {
	       last;
	   }

	   $self->debug("DEBUG: Using part of $filename");

	   if ($filename =~ /^(.+?)\/(.+)$/) {
	       $filename = $2;
	   }

	   #warn "DEBUG: Indexing on $filename";

	   my $input_dir_filename = $self->{'path'}{'footage-cache-dir'} . "/" . $filename;
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

	   $self->debug("DEBUG: Create FLV slice: $ffmpeg -v quiet $flash_args 2>&1");
	   $self->debug("DEBUG: starting FLV encoding at " . `date`);
	   my $ffmpeg_output = `$ffmpeg -v quiet $flash_args 2>&1`;
	   $self->debug("DEBUG: ending FLV encoding at " . `date`);
	   #warn $ffmpeg_output;

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
	   
	   push @flv_slices, $output_dir_filename;
	   $intermediate += 1;
       }

       if ($skip_request) {
	   warn "ERROR: Unrecoverable error; skipping request $request_id and marking as footage-not-available";

	   my $token = "$prog_id.flv,footage-not-available";
	   my $queue_name = $self->{'constants'}{'available-programmes-queue'};
	   
	   my $retries = 5;

	   while ($retries > 0) {

	       if ($q->send($queue_name, $token)) {
		   $self->debug("sent update for programme $prog_id (request $request_id) via $queue_name");
		   last;
	       } else {
		   $retries -= 1;
		   sleep 10;
	       }

	       if ($retries == 0) {
		   warn "ERROR: Could not add a message to the available programmes queue";
		   next;
	       }

	   }

       }

       # if there is more than one slice, concatenate them all using
       # mencoder

	   if (@flv_slices > 1) {

	   $self->debug("DEBUG: Joining slices together");

	   my $input_filenames = join (' ', @flv_slices);

	   my $output_dir_filename = "$output_dir/$prog_id.flv";

	   # TODO - should the audio codec be mp3 (rather than copy)?
	   # TODO - check for errors in $mencoder_output

	   my $mencoder_command = "$mencoder $input_filenames -o $output_dir_filename -of lavf -oac copy -ovc lavc -lavcopts vcodec=flv -lavfopts i_certify_that_my_video_stream_does_not_use_b_frames";

	   $self->debug("DEBUG: $mencoder_command");

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
	   
	   my $mv_command = "mv $output_dir/$prog_id.slice.0.flv $output_dir/$prog_id.flv";
	   $self->debug("DEBUG: $mv_command");
	   `$mv_command`;

       }

       my $bucket = $self->{'constants'}{'programmes-bucket'};
       my $local_filename = "$output_dir/$prog_id.flv";
       my $remote_filename = "$bucket/$prog_id.flv";
       
       $self->debug("DEBUG: adding FLV metadata (using yamdi on $local_filename)");

       # update FLV file cue-points using yamdi

       my $yamdi = $self->{'path'}{'yamdi'};

       `$yamdi -i $local_filename -o $local_filename.yamdi`;
       unlink($local_filename);
       `mv $local_filename.yamdi $local_filename`;

       my $token;

       my $file_size = `ls -sh $local_filename`;

       unless ($file_size) {
	   $token = "$remote_filename,footage-not-available";
       }

       if ($file_size) {
	   $self->debug("DEBUG: file size is $file_size");
	   if ($file_size eq '4.0K') {
	       warn "ERROR: Empty file, not-available";
	       $token = "$remote_filename,footage-not-available";
	   }
       }
	   
       unless ($token) {

	   my $store = BBCParl::S3->new();

	   # upload the FLV file and make it world-readable

	   if ($store->put($local_filename, $remote_filename, 'public')) {

	       $self->debug("DEBUG: Stored $local_filename in S3 as $remote_filename");
	       $token = "$remote_filename,available";

	   } else {

	       warn "ERROR: Failed to store $local_filename in S3";
	       $token = "$remote_filename,processed-but-not-stored-in-S3";

	   }

       }

       my $queue_name = $self->{'constants'}{'available-programmes-queue'};
	   
       my $retries = 5;

       while ($retries > 0) {
	   
	   if ($q->send($queue_name, $token)) {
	       $self->debug("sent update for programme $prog_id (request $request_id) via $queue_name");
	       last;
	   } else {
	       $retries -= 1;
	       sleep 10;
	   }
	   
	   if ($retries == 0) {
	       warn "ERROR: Could not add a message to the available programmes queue ($token)";
	   }

       }

   }

   $self->debug("DEBUG: end processing of requests");

   return 1;

}

sub cache_cleanup {
    my ($self) = @_;
    
    # TODO - remove and replace with a separate cache-cleaning process
    
    # Once we've done all the requests in the queue, remove all mpeg
    # files from the local raw-footage cache more than 3 days old
    
    my $week_old_dt = DateTime->now();
    $week_old_dt->subtract( days => 4 );
    my $cutoff = $week_old_dt->datetime();

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

    my @d1 = BBCParl::EC2::extract_datetime_array ($d1);
    my @d2 = BBCParl::EC2::extract_datetime_array ($d2);
	       
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
