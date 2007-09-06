package BBCParl::Programmes;

use strict;

use Data::Dumper;

#use HTML::Entities;
#use POSIX qw ( strftime sys_wait_h);
#use Date::Manip;
#use WebService::TWFY::API;

use Storable qw (freeze nfreeze thaw);
use LWP::UserAgent;
use XML::Simple;
use DateTime;
use DateTime::TimeZone;

use mySociety::DBHandle qw (dbh);
use BBCParl::SQS;

use mySociety::Config;

sub new {
    my ($class, %args) = @_;

    my $self = {};

    bless $self, $class;

    foreach my $key (keys %args) {
	$self->{'args'}{$key} = $args{$key};
    }

    # raw-footage is ec2->bitter
    $self->{'constants'}{'raw-footage-queue'} = mySociety::Config::get('BBC_QUEUE_RAW_FOOTAGE');
    # processing-reqeusts is bitter->ec2
    $self->{'constants'}{'processing-requests-queue'} = mySociety::Config::get('BBC_QUEUE_PROCESSING_REQUESTS');
    # available-programmes is ec2->bitter
    $self->{'constants'}{'available-programmes-queue'} = mySociety::Config::get('BBC_QUEUE_AVAILABLE_PROGRAMMES');

    $self->{'constants'}{'tv-schedule-api-url'} = 'http://www0.rdthdo.bbc.co.uk/cgi-perl/api/query.pl';

    $self->{'params'}{'channel_id'} = ',BBCParl';
    $self->{'params'}{'method'} = 'bbc.schedule.getProgrammes';
    $self->{'params'}{'limit'} = '500';
    $self->{'params'}{'detail'} = 'schedule';
    $self->{'params'}{'format'} = 'simple';

    $self->{'path'}{'home-dir'} = (getpwuid($<))[7];
    $self->{'path'}{'aws'} = $self->{'path'}{'home-dir'} . "/aws/aws";

    # TODO - use the same value for westminster hall $location in all files

    # TODO - think we can remove these lines?
#    $self->{'timezones'}{'commons'} = 'Europe/London';
#    $self->{'timezones'}{'lords'} = 'Europe/London';
#    $self->{'timezones'}{'westminster-hall'} = 'Europe/London';
#    $self->{'timezones'}{'northern-ireland'} = 'Europe/London';
#    $self->{'timezones'}{'welsh'} = 'Europe/London';
#    $self->{'timezones'}{'scottish'} = 'Europe/London';
#    $self->{'timezones'}{'default'} = 'Europe/London';

    return $self;
}

sub update_raw_footage_table {
    my ($self) = @_;

    # TODO - replace this with an SQS-based system of raw-footage
    # notifications

    my $q = BBCParl::SQS->new();
    
    my $requests_queue = $self->{'constants'}{'raw-footage-queue'};
    my $num_requests = 0;

    # start off by checking the queue for new footage files that have
    # been added to S3

    while (1) {
#        warn "DEBUG: Getting a message from the queue";
        my ($message_body, $queue_url, $message_id) = $q->receive($requests_queue);
        if ($message_id) {
	    $self->{'raw-footage-to-add'}{$message_body} = $message_id;
	    $self->{'raw-footage-queue-url'} = $queue_url;
	    $num_requests += 1;
        } else {
#            warn "DEBUG: No more messages in queue";
            last;
        }
    }

    # foreach filename, insert its details into db bbcparlvid
    # table raw-footage (status = not-yet-processed)

    foreach my $filename (keys %{$self->{'raw-footage-to-add'}}) {
	if (dbh()->selectrow_array('SELECT filename FROM raw_footage WHERE filename = ?',  {}, $filename)) {
	    #warn "DEBUG: raw footage $filename is already registered in the database";
	    next;
	}
	my ($start, $end) = extract_start_end($filename);
	if ($start && $end) {
	    warn "DEBUG: Adding raw footage $filename to database";
	    {
		dbh()->do(
			  "INSERT INTO raw_footage (filename, start_dt, end_dt, status)
                       VALUES(?, ?, ?, 'not-yet-processed')",
			  {},
			  $filename, $start, $end);
	    }
	} else {
	    warn "ERROR: $filename is not correct format";
	    warn "ERROR: Cannot add to database for processing";
	}
	$q->delete($self->{'raw-footage-queue-url'}, # queue_url
		   $self->{'raw-footage-to-add'}{$filename}); # message_id
	
    }

    dbh()->commit();

    return $num_requests;

}

sub extract_start_end {
    my ($filename) = @_;
    if ($filename =~ /.+?(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})Z(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})Z/) {
	return ("$1 $2", "$3 $4");
    } else {
	return undef;
    }
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

sub update_footage_status {
    my ($self) = @_;

    foreach my $filename (keys %{$self->{'raw-footage-to-process'}}) {
	warn "DEBUG: setting status = 'processed' for $filename";

	dbh()->do(
		  "UPDATE raw_footage SET status = 'processed' WHERE filename = ?",
		  {},
		  $filename);
	
    }

    dbh()->commit();

    return 1;

}

sub calculate_date_time_range {
    my ($self) = @_;

    my $start = '';
    my $end = '';

    foreach my $filename (keys %{$self->{'raw-footage-to-process'}}) {
	warn "DEBUG: Calculating date-range with $filename";
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
	warn "DEBUG: Files range from $start to $end";
	return ($start, $end);
    } else {
	warn "ERROR: Did not calculate a date-range.";
	return undef;
    }

}

sub update_programmes_from_footage {
    my ($self) = @_;

    # connect to bbcparlvid database

    my $dbh = mySociety::DBHandle->new_dbh();
    unless ($dbh) {
	warn "FATAL: Cannot connect to database.";
	return undef;
    }

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
	    $rights = 'internet';
	} elsif ($title_synopsis =~ /^Scottish/i) {
	    $location = 'scottish';
	    $rights = 'internet';
	} elsif ($title_synopsis =~ /^Westminster Hall/i) {
	    $location = 'westminster-hall';
	    $rights = 'internet';
	} elsif ($title_synopsis =~ /^Northern Ireland Assembly/i) {
	    $location = 'northern-ireland';
	    $rights = 'internet';
	} elsif ($title_synopsis =~ /^Welsh/i) {
	    $location = 'welsh';
	    $rights = 'internet';
	} elsif ($title_synopsis =~ /^Mayor/i) {
	    $location = 'gla';
	    $rights = 'internet';
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
	    #warn "DEBUG: $prog_start is already in the database; skipping duplicate database insert.";
	    next;
	}

	#warn Dumper $self->{'programmes'}{$prog_start};

	my @params = qw (location broadcast_start broadcast_end title synopsis crid channel_id rights);
	if ($self->{'programmes'}{$prog_start}{'record_start'}) {
	    push @params, qw (record_start record_end);
	}

	{
	    #warn "INSERT INTO programmes (" . join (',', @params) . ") VALUES (" . join (',', map {'?'} @params) . ")";
	    dbh->do("INSERT INTO programmes (" . join (',', @params) . ") VALUES (" . join (',', map {'?'} @params) . ")",
		    {},
		    map {
			$self->{'programmes'}{$prog_start}{$_};
		    } @params);
	}
       
	dbh()->commit();

    }

}

sub enqueue_processing_requests {
    my ($self) = @_;

    my $queue = BBCParl::SQS->new();
    my $queue_name = $self->{'constants'}{'processing-requests-queue'};
    my $message_count = 0;

    my $st = dbh()->prepare("SELECT id, location, broadcast_start, broadcast_end, channel_id FROM programmes WHERE status = 'not-yet-processed' AND rights != 'none' ORDER BY id");
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
		     'formats' => 'flash,mp4');
	
	if (lc($data{'channel_id'}) eq 'bbcparl') {
	    $data{'channel_id'} = 'parliament';
	}
	
	my $token = '';
	
	foreach my $key (keys %data) {
	    $token .= "$key=" . $data{$key} . "\n";
	}

	warn Dumper %data;
	
	my @filenames = ();
	foreach my $filename (sort keys %{$self->{'raw-footage-to-process'}}) {
	    my ($start, $end) = extract_start_end($filename);
	    warn "DEBUG: check between $start and $end ($filename)";
	    if ($start le $data{'broadcast_start'} && $data{'broadcast_start'} le $end) {
		warn "DEBUG: hit on $filename";
		push @filenames, $filename;
		if ($start le $data{'broadcast_end'} && $data{'broadcast_end'} le $end) {
		    warn "DEBUG: found the last file we need";
		    last;
		}
	    } elsif ($start le $data{'broadcast_end'} && $data{'broadcast_end'} le $end) {
		warn "DEBUG: hit on $filename";
		push @filenames, $filename;
	    }
	}

	if (@filenames) {
	    $token .= "footage=" . join (',',@filenames) . "\n";
	} else {
	    warn "DEBUG: No footage files found - skipping this one";
	    dbh()->do(
		      "UPDATE programmes SET status = 'footage-not-available' WHERE id = ?",
		      {},
		      $data{'id'});
	    next;
	}
	
	# TODO - need to include thumbnails

	# TODO - re-use the gid-getting code from Captions.pm - move
	# it into BBCParl::Util, and have something that can return
	# all gids in a given time-frame. I think this should work.

	# TODO - foreach token - work out all gids on $date that fall
	# within start/end times, get the htime (TWFY API) for each of
	# them, convert htime to UTC, and add them to the token
	# (i.e. these are the date-times for PNG image capture)

	# NOTE: mplayer $inputFilename -ss $timeOffsetInSeconds
	# -nosound -vo jpeg:outdir=$outDir -frames 1 will always
	# generate two thumbnails (from
	# http://gallery.menalto.com/node/40548)

	# foreach token, add to the Amazon SQS queue
	# 'bbcparlvid-processing-requests'

	warn "DEBUG: Adding programme $data{'id'} to the processing queue $queue_name";

	warn Dumper $token;

	if ($queue->send($queue_name, $token)) {
	    $message_count += 1;
	} else {
	    warn "ERROR: Failed to send Amazon SQS message ($queue_name)";
	}

	warn "DEBUG: Updating status of programme (id=$data{'id'})";

	dbh()->do(
		  "UPDATE programmes SET status = 'added-to-processing-queue' WHERE id = ?",
		  {},
		  $data{'id'});

    }

#    dbh()->commit();

    warn "DEBUG: Sent $message_count processing requests to EC2";

    return 1;

}

sub update_programmes_from_processing {
    my ($self) = @_;

    # connect to bbcparlvid database

    my $dbh = mySociety::DBHandle->new_dbh();
    unless ($dbh) {
	warn "FATAL: Cannot connect to database.";
	return undef;
    }

    my $updates_queue = $self->{'constants'}{'available-programmes-queue'};

    my $q = BBCParl::SQS->new();

    while (1) {
#        warn "DEBUG: Getting a message from the queue $updates_queue";
        my ($message_body, $queue_url, $message_id) = $q->receive($updates_queue);
        if ($message_id) {
#            warn "DEBUG: Got $message_id";
	    $self->{'new-programmes'}{$message_id} = $message_body;
	    $self->{'new-programmes-queue-url'} = $queue_url;
        } else {
#            warn "DEBUG: No more messages in queue $updates_queue";
            last;
        }
    }

    foreach my $message_id (keys %{$self->{'new-programmes'}}) {
	if ($self->{'new-programmes'}{$message_id} =~ /(\d+).flv,(.+)/i) {
	    warn "DEBUG: programme $1 status $2";
	    dbh()->do(
		      "UPDATE programmes SET status = ? WHERE id = ?",
		      {},
		      $2,
		      $1);
	    $q->delete($self->{'new-programmes-queue-url'},
		       $message_id);
	} elsif ($self->{'new-programmes'}{$message_id} =~ /(\d+).flv/i) {
	    dbh()->do(
		      "UPDATE programmes SET status = 'available' WHERE id = ?",
		      {},
		      $1);
	    $q->delete($self->{'new-programmes-queue-url'},
		       $message_id);
	} else {
	    warn "ERROR: Incorrect message format ($self->{'new-programmes'}{$message_id})";
	}
    }

    dbh()->commit();

    return 0;

}

1;
