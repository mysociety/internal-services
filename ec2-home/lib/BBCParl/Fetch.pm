package BBCParl::Fetch;

use strict;

use POSIX qw (strftime);
use BBCParl::EC2;
use BBCParl::S3;
use BBCParl::SQS;

sub new {
    my ($class, $test) = @_;
    my $self = {};
    bless $self, $class;

    $self->{'path'}{'home-dir'} = (getpwuid($<))[7];
    $self->{'path'}{'config-dir'} = $self->{'path'}{'home-dir'} . '/conf';

    $self->{'path'}{'processing-dir'} = '/mnt/processing';
    $self->{'path'}{'downloads-dir'} = $self->{'path'}{'processing-dir'} . '/downloads';
    $self->{'path'}{'mpeg-output-dir'} = $self->{'path'}{'processing-dir'} . '/raw-footage';
    
#    $self->{'path'}{'aws'} = $self->{'path'}{'home-dir'} . '/bin/aws/aws';

    $self->{'path'}{'ffmpeg'} = 'ffmpeg';

    $self->{'path'}{'fetch-program'} = 'mplayer';

    # TODO - eventually, we should have a per-download sleep period, and fork() to sleep/reap individual downloads

    $self->{'constants'}{'download-sleep'} = 23400;  # 23400 secs == 6 hours = 60 secs * 60 mins * 6 hours

    $self->{'constants'}{'raw-footage-bucket'} = 'bbcparlvid-raw-footage';

    $self->{'constants'}{'raw-footage-queue'} = 'bbcparlvid-raw-footage';

    # TODO - remove temporary testing value:

###    $self->{'constants'}{'download-sleep'} = 10;

    return $self;
}

sub run {
    my ($self) = @_;

#    warn "INFO: starting to download video";

    $self->load_config(); # work out what we need to download
    $self->fetch_video(); # start mplayer downloading the video
    $self->reap_processes(); # kill mplayer
    $self->process_raw_files(); # convert raw files (wmv, etc.) to mpg files
    $self->upload_processed_files(); # upload mpg files to amazon S3 storage

#    warn "INFO: finished downloading video";

}

sub load_config {
    my ($self) = @_;

#    warn "INFO: loading config files";

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

}

sub fetch_video {
    my ($self) = @_;

    foreach my $channel (keys %{$self->{'channels'}}) {

#	warn "INFO: fetching video for $channel";

	unless (defined($self->{'channels'}{$channel}{'args'}{'stream'})) {
	    warn "ERROR: stream URL not defined; skipping download for $channel.";
	    next;
	}
	
	my @program_args = ();
	
	# calculate the current date_time (UTC)
	
	my $date_time_format = '%FT%TZ';
	my $date_time = strftime($date_time_format,gmtime());
	
	unless (-e $self->{'path'}{'downloads-dir'} . "/$channel") {
	    #warn "INFO: Creating new directory for downloads (" . $self->{'path'}{'downloads-dir'} . "/$channel)";
	    # create directory for this channel
	    unless (mkdir($self->{'path'}{'downloads-dir'} . "/$channel",770)) {
		warn "ERROR: Could not create directory (" . $self->{'path'}{'downloads-dir'} . "/$channel)";
		warn "ERROR: Skipping download for $channel";
		next;
	    }
	}

	my $directory = $self->{'path'}{'downloads-dir'};
	my $filename = "$channel/$channel.$date_time." . $self->{'channels'}{$channel}{'args'}{'file-type'};

	$self->{'channels'}{$channel}{'args'}{'dumpfile'} = "$directory/$filename";

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
#	warn "INFO: running $program $program_args";

	# send mplayer STDOUT output to /dev/null

	my $child_pid = open(PROCESS, "|exec $command > /dev/null");

	# create a reference to PROCESS, just to suppress the
	# "only-used once" warning

	my $process_ref = *PROCESS{IO};
	
	# WARNING: DO NOT CLOSE PROCESS!!! If you close PROCESS, the
	# script will never kill mplayer.

#	warn "INFO: started new mplayer process (pid is $child_pid)";

	$self->{'pids'}{$child_pid}{'command'} = $command;
	$self->{'pids'}{$child_pid}{'directory'} = $directory;
	$self->{'pids'}{$child_pid}{'filename'} = $filename;

    }

}

sub reap_processes {
    my ($self) = @_;

    my $duration = $self->{'constants'}{'download-sleep'};

#    warn "INFO: Sleeping for $duration seconds";

    sleep ($duration);

# go through the pids in @child_pids and kill each of them

    foreach my $pid (keys %{$self->{'pids'}}) {

	# kill the mplayer process

#	warn "INFO: trying to kill mplayer process (pid is $pid)";
	my $count = kill(9,$pid);
	if ($count < 1) {
	    warn "ERROR: did not send signal to mplayer process (pid was $pid) - probably died early?";
	}

	my $date_time_format = '%FT%TZ';
	my $date_time = strftime($date_time_format,gmtime());
	
	# work out what files need to be processed

	my $directory = $self->{'pids'}{$pid}{'directory'};
	my $filename = $self->{'pids'}{$pid}{'filename'};

	unless (-e "$directory/$filename") {
	    warn "ERROR: Cannot find download file ($directory/$filename) - skipping";
	    next;
	}

#	warn "DEBUG: adding $filename to \$self->{'files-to-process'}{$pid}{'filename'}";

	$self->{'files-to-process'}{$pid}{'directory'} = $directory;
	$self->{'files-to-process'}{$pid}{'filename'} = $filename;
	$self->{'files-to-process'}{$pid}{'end-date-time'} = $date_time;

    }

}

sub process_raw_files {
    my ($self) = @_;

    foreach my $pid (sort keys %{$self->{'files-to-process'}}) {

	my $directory = $self->{'files-to-process'}{$pid}{'directory'};
	my $output_directory = $self->{'path'}{'mpeg-output-dir'};
	my $filename = $self->{'files-to-process'}{$pid}{'filename'};
	my $date_time = $self->{'files-to-process'}{$pid}{'end-date-time'};

	my $ffmpeg = $self->{'path'}{'ffmpeg'};

	# add end-time to output_filename, change extension to .mpeg

	if ($filename =~ /^(.+Z)\.(.+?)$/) {

	    my $input_filename = "$directory/$filename";
	    my $output_filename = "$output_directory/$1$date_time.mpeg";
#	    warn "DEBUG: $ffmpeg -v quiet -async 2 -i $input_filename -s 320x180 $output_filename > /dev/null";

#	    warn "DEBUG: Encoding $input_filename to MPEG format as $output_filename";

	    # convert to MPEG video, 320x180

	    my $ffmpeg_output = `$ffmpeg -v quiet -async 2 -i $input_filename -s 320x180 $output_filename 2>&1 > /dev/null`;

	    unless (-e $output_filename) {
		warn "ERROR: Output file from mpeg conversion not found ($output_filename)";
		warn "ERROR: Not deleting input file ($input_filename)";
	    } else {
		$self->{'files-to-upload'}{$output_filename} = 1;
		unlink ($input_filename);
	    }

	} else {

	    warn "ERROR: Wrong filename format ($filename)";
	    warn "ERROR: Skipping processing and upload ($filename)";
	    next;

	}
    }

}

sub upload_processed_files {
    my ($self) = @_;

    unless (defined($self->{'files-to-upload'})) {
	warn "ERROR: Nothing to upload to S3, skipping upload step";
	return 1;
    }

    my $bucket = $self->{'constants'}{'raw-footage-bucket'};

    my $store = BBCParl::S3->new();

#    use Data::Dumper; warn Dumper $self;

    foreach my $local_filename (sort keys %{$self->{'files-to-upload'}}) {

	my $remote_filename;

	if ($local_filename =~ /^(.+)\/(.+)$/) {
	    $remote_filename = "$bucket/$2";
	}
	
	warn "DEBUG: uploading $local_filename to $remote_filename";

	if ($store->put($local_filename, $remote_filename)) {

	    # upload an SQS token per new raw-footage file - a script
	    # on bitter will check for new tokens of this form and
	    # update local database of footage

	    my $q = BBCParl::SQS->new();

	    my $token = $remote_filename;
	    my $queue_name = $self->{'constants'}{'raw-footage-queue'};

	    $q->send($queue_name, $token);

	    # don't delete files as soon as they have been uploaded -
	    # they get automatically deleted in Process.pm once they
	    # are more than 3 days old

	    #unlink($local_filename);

	} else {
	    warn "ERROR: Did not store $local_filename in S3";
	}

    }
    
    return 1;

}

1;
