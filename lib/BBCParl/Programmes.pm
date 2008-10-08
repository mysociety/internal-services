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

1;
