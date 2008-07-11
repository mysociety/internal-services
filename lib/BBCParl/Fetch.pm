package BBCParl::Fetch;

use strict;

use POSIX qw (strftime);
use mySociety::DBHandle qw (dbh);
use BBCParl::Common;

sub debug {
    my ($self, $message) = @_;
    if ($self->{'debug'}) {
        warn "DEBUG: $message";
    }
    return undef;
}

# TODO add in parallel downloads feature (choose larger of the two files)

# TODO move across from Programmes.pm the subroutine
# update_raw_footage_table (see TODO in that file) and move subroutine
# extract_start_end into BBCParl::Common (and then update the manner
# in which it is called by Programmes.pm and Fetch.pm and others).

sub new {
    
    my ($class, %args) = @_;

    my $self = {};

    bless $self, $class;

    foreach my $key (keys %args) {
        $self->{'args'}{$key} = $args{$key};
    }

    if ($self->{'args'} && $self->{'args'}{'debug'}) {
        $self->{'debug'} = 'true';
    }

    $self->{'path'}{'home-dir'} = (getpwuid($<))[7];

    $self->{'path'}{'config-dir'} = "$FindBin::Bin/../conf/";

    $self->load_config(); # work out what we need to download

    $self->{'path'}{'downloads-dir'} = mySociety::Config::get('FOOTAGE_DIR');

    $self->{'path'}{'mpeg-output-dir'} = $self->{'path'}{'downloads-dir'};
    
    $self->{'path'}{'process-program'} = '/usr/bin/ffmpeg';

    $self->{'path'}{'fetch-program'} = '/usr/bin/mplayer';

    # TODO - eventually, we should have a per-download sleep period,
    # and fork() to sleep/reap individual downloads

    #$self->{'constants'}{'download-sleep'} = 23400;  # 23400 secs == 6 hours = 60 secs * 60 mins * 6 hours

    $self->{'constants'}{'download-sleep'} = 4500;  # 4500 secs == 1.25 hours = 60 secs * 60 mins * 1.25 hours

    $self->{'constants'}{'output-dimensions'} = "320x180";

    return $self;
}

sub run {
    my ($self) = @_;

    $self->debug("starting to download video");

    $self->fetch_video(); # start mplayer downloading the video
    $self->reap_processes(); # kill mplayer
    $self->process_raw_files(); # convert raw files (wmv, etc.) to mpg files

#    $self->upload_processed_files(); # upload mpg files to amazon S3 storage

    $self->update_database();

    $self->debug("DONE");

}

sub load_config {
    my ($self) = @_;
    
    $self->debug("loading config files");

    my $channels_config_filename = $self->{'path'}{'config-dir'} . '/channels.conf';

    unless (-e $channels_config_filename) {
	# TODO - use a proper logging system
	warn "FATAL: Cannot find file: $channels_config_filename";
	die;
    }

    unless(open (CHANNELS, $channels_config_filename)) {
	# TODO - use a proper logging system
	warn "FATAL: Cannot open file: $channels_config_filename ($!)";
	die;
    }

    # load the overall channel config file

    my @channels;
    while (<CHANNELS>) {
	if (/^#/) {
	    next;
	}
	if (/channels\s*=\s*(.+)/) {
	    my $channels = $1;
	    $channels =~ s/\s//gi;
	    @channels = split (',', $channels);
	}
    }
    
    close (CHANNELS);

    foreach my $channel (@channels) {

	$self->debug("loading config for channel $channel");

	# load the per-channel config files

	my $per_channel_config = $self->{'path'}{'config-dir'} . "/$channel.conf";
	unless (open (CHANNEL,$per_channel_config)) {
	    warn "ERROR: Cannot open file: $per_channel_config ($!)";
	    warn "ERROR: Skipping channel $channel for mplayer download.";
	    next;
	}

	while (<CHANNEL>) {
	    if (/^#/) {
		next;
	    }
	    if (/^(.+?)\s*=\s*(.+)\s*$/) {
		$self->{'channels'}{$channel}{'args'}{lc($1)} = $2;
	    }
	}
	
	close (CHANNEL);

	# set up other program args

	unless (defined($self->{'channels'}{$channel}{'args'}{'file-type'})) {
	    $self->{'channels'}{$channel}{'args'}{'file-type'} = 'unknown-file-type';
	}

	$self->{'channels'}{$channel}{'args'}{'slave'} = '';
	$self->{'channels'}{$channel}{'args'}{'quiet'} = '';
	$self->{'channels'}{$channel}{'args'}{'dumpstream'} = '';
	$self->{'channels'}{$channel}{'args'}{'noframedrop'} = '';
	$self->{'channels'}{$channel}{'args'}{'nolirc'} = '';
	$self->{'channels'}{$channel}{'args'}{'msglevel'} = 'all=0';
#	$self->{'channels'}{$channel}{'args'}{'really-quiet'} = '';

    }

    $self->debug("loaded channels config - all done");

}

sub fetch_video {
    my ($self) = @_;

    foreach my $channel (keys %{$self->{'channels'}}) {

	$self->debug("fetching video for $channel");

	unless (defined($self->{'channels'}{$channel}{'args'}{'stream'})) {
	    warn "ERROR: stream URL not defined; skipping download for $channel.";
	    next;
	}
	
	my @program_args = ();
	
	# calculate the current date_time (UTC)
	
	my $date_time_format = '%FT%TZ';
	my $date_time = strftime($date_time_format,gmtime());
	
	my $directory = $self->{'path'}{'downloads-dir'};
	my $filename = "$directory/$channel.$date_time." . $self->{'channels'}{$channel}{'args'}{'file-type'};

	$self->{'channels'}{$channel}{'args'}{'dumpfile'} = $filename;

	foreach my $key (keys %{$self->{'channels'}{$channel}{'args'}}) {
	    if ($key eq 'stream' || $key eq 'file-type') {
		next;
	    } else {
		push @program_args, "-$key " . $self->{'channels'}{$channel}{'args'}{$key};
	    }
	}
	
	push @program_args, $self->{'channels'}{$channel}{'args'}{'stream'};

	my $program = $self->{'path'}{'fetch-program'};
	my $program_args = join (' ',@program_args);
	my $command = "$program $program_args";
	$self->debug("running: $program $program_args");

	# send mplayer STDOUT output to /dev/null

	my $child_pid = open(PROCESS, "|exec $command > /dev/null");

	# create a reference to PROCESS (required only to suppress the
	# "only-used once" warning)

	my $process_ref = *PROCESS{IO};
	
	# WARNING: do not close() the PROCESS filehandle!!! If you close PROCESS, the
	# script will never kill mplayer, which is a Bad Thing.

	$self->debug("started new mplayer process (pid is $child_pid)");

	$self->{'pids'}{$child_pid}{'command'} = $command;
	$self->{'pids'}{$child_pid}{'filename'} = $filename;

    }

}

sub reap_processes {
    my ($self) = @_;

    my $duration = $self->{'constants'}{'download-sleep'};
    
    $self->debug("Sleeping for $duration seconds");

    sleep ($duration);

    # go through the pids in @child_pids and kill each of them

    foreach my $pid (keys %{$self->{'pids'}}) {

	# kill the mplayer process

	$self->debug("trying to kill mplayer process (pid is $pid)");
	my $count = kill(9,$pid);
	if ($count < 1) {
	    warn "ERROR: did not send signal to mplayer process (pid was $pid) - probably died early?";
	}

	my $date_time_format = '%FT%TZ';
	my $date_time = strftime($date_time_format,gmtime());
	
	# work out what files need to be processed

	my $filename = $self->{'pids'}{$pid}{'filename'};

	unless (-e "$filename") {
	    warn "ERROR: Cannot find download file ($filename) - skipping";
	    next;
	}

	$self->debug("adding $filename to \$self->{'files-to-process'}{$pid}{'filename'}");

	$self->{'files-to-process'}{$pid}{'filename'} = $filename;
	$self->{'files-to-process'}{$pid}{'end-date-time'} = $date_time;

    }

}

sub process_raw_files {
    my ($self) = @_;

    foreach my $pid (sort keys %{$self->{'files-to-process'}}) {

	my $output_directory = $self->{'path'}{'mpeg-output-dir'};
	my $filename = $self->{'files-to-process'}{$pid}{'filename'};
	my $date_time = $self->{'files-to-process'}{$pid}{'end-date-time'};

	my $process_program = $self->{'path'}{'process-program'};

	my $dimensions = $self->{'constants'}{'output-dimensions'};

	# add end-time to output_filename, change extension to .mpeg

	if ($filename =~ /([^\/]+Z)\.(.+?)$/) {

	    my $input_filename = $filename;
	    my $output_filename = "$output_directory/$1$date_time.mpeg";

	    $self->debug("Encoding $input_filename to MPEG format as $output_filename");

	    # convert to MPEG video, 320x180, STDERR to STDOUT

	    my $convert_command = "$process_program -v quiet -async 2 -i $input_filename -s $dimensions $output_filename 2>&1";
	    $self->debug("running: $convert_command");

	    $self->debug("DEBUG: starting MPEG encoding at " . `date`);
	    my $ffmpeg_output = `$convert_command`;
	    $self->debug("DEBUG: finished MPEG encoding at " . `date`);

	    $self->debug("Output from ffmpeg was: $ffmpeg_output");

	    unless (-e $output_filename) {
		warn "ERROR: Output file from mpeg conversion not found ($output_filename)";
		warn "ERROR: Not deleting input file ($input_filename)";
	    } else {
		$self->{'database-updates'}{$output_filename} = 1;
		unlink ($input_filename);
	    }

	} else {

	    warn "ERROR: Wrong filename format ($filename)";
	    warn "ERROR: Skipping processing ($filename)";
	    next;

	}
    }

}

sub update_database {
    my ($self) = @_;

    unless (defined($self->{'database-updates'})) {
	warn "ERROR: no database updates required.";
	return 1;
    }

    foreach my $filename (sort keys %{$self->{'database-updates'}}) {
	
	$self->debug("TODO: update database on bitter with $filename");

	# TODO update raw-footage table

	# return true unless error

	# TODO replace the SQS notifications system with a direct
	# database update - therefore move this code to Fetch.pm
	# wholesale (having removed the SQS references) and tweak
	# accordingly?

	# foreach filename, insert its details into db bbcparlvid
	# table raw-footage (status = not-yet-processed)
	
	if (dbh()->selectrow_array('SELECT filename FROM raw_footage WHERE filename = ?',  {}, $filename)) {
	    warn "ERROR: raw footage $filename is already registered in the database";
	    next;
	}
	
	$self->debug("updating raw_footage db table to include channel name (derived from filename)");

	my ($start, $end) = BBCParl::Common::extract_start_end($filename);
	
	my $channel = 'unknown';
	if ($filename =~ /bbcparliament/) {
	    $channel = 'BBCParl';
	}

	if ($start && $end) {
	    $self->debug("Adding raw footage $filename to database");
	    {
		dbh()->do(
			  "INSERT INTO raw_footage (filename, start_dt, end_dt, status, channel_id)
                       VALUES(?, ?, ?, 'not-yet-processed', ?)",
			  {},
			  $filename, $start, $end, $channel);
	    }
	} else {
	    warn "ERROR: $filename is not correct format";
	    warn "ERROR: Cannot add $filename to database for processing";
	}
	
    }

    dbh()->commit();

}

1;
