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
use BBCParl::Common;

use mySociety::Config;

sub debug {
    my ($self, $message) = @_;
    if ($self->{'debug'}) {
	warn "DEBUG: $message";
    }
    return undef;
}

# TODO make this load channels.conf, check that for channel_ids, and
# then process footage one channel at a time - needs to update across
# multiple subroutines

sub new {
    my ($class, %args) = @_;

    my $self = {};

    bless $self, $class;

    mySociety::Config::set_file("$FindBin::Bin/../conf/general");

    foreach my $key (keys %args) {
	$self->{'args'}{$key} = $args{$key};
    }

    $self->{'constants'}{'tv-schedule-api-url'} = 'http://www0.rdthdo.bbc.co.uk/cgi-perl/api/query.pl';

    $self->{'params'}{'channel_id'} = ',BBCParl';
    $self->{'params'}{'method'} = 'bbc.schedule.getProgrammes';
    $self->{'params'}{'limit'} = '500';
    $self->{'params'}{'detail'} = 'schedule';
    $self->{'params'}{'format'} = 'simple';

    #$self->{'path'}{'home-dir'} = (getpwuid($<))[7];
    #$self->{'path'}{'aws'} = $self->{'path'}{'home-dir'} . "/aws/aws";

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

# TODO move the following to Process.pm (connecting from sponge to bitter directly)

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
	$self->debug("setting status = 'processed' for $filename");

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
	    $self->debug("INSERT INTO programmes (" . join (',', @params) . ") VALUES (" . join (',', map {'?'} @params) . ")");
	    dbh->do("INSERT INTO programmes (" . join (',', @params) . ") VALUES (" . join (',', map {'?'} @params) . ")",
		    {},
		    map {
			$self->{'programmes'}{$prog_start}{$_};
		    } @params);
	}
       
	dbh()->commit();

    }

}


1;
