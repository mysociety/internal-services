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

sub get_processing_requests {
    my ($self) = @_;

    my $st = dbh()->prepare("SELECT id, location, broadcast_start, broadcast_end, channel_id FROM programmes WHERE status = 'not-yet-processed' AND rights != 'none' ORDER BY broadcast_start asc");
    $st->execute();

    $self->{requests} = [];
    while (my @row = $st->fetchrow_array()) {
        my %data = ( 'id' => $row[0],
            'location' => $row[1],
            'broadcast_start' => $row[2],
            'broadcast_end' => $row[3],
            'channel_id' => $row[4]
        );

        # TODO - make this work for all channels (have to specify what
        # channels to process in an input param somewhere)
        if (lc($data{'channel_id'}) eq 'bbcparl') {
            $data{'channel_id'} = 'parliament';
        }

        push @{$self->{requests}}, { %data };
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

sub process_flv_file {
    my ($self, $output_dir, $prog_id) = @_;

    # Shrink FLV file to half size
    my $mencoder = $self->{'path'}{'mencoder'};
    my $input = "$output_dir$prog_id.flv";
    my $output = "$output_dir$prog_id.small.flv";
    $self->debug("shrinking FLV to half-size");
    `$mencoder $input -vf scale=320:180 -o $output -of lavf -oac copy -ovc lavc -lavcopts vcodec=flv 2>&1`;

    unless (-e $output) {
        warn "ERROR: mencoder output file missing";
        $self->skip_programme($prog_id);
        return;
    }

    # update FLV file cue-points using yamdi
    my $yamdi = $self->{'path'}{'yamdi'};
    my $yamdi_output = "$input.yamdi";
    $self->debug("adding FLV metadata (using $yamdi on $output)");
    my $yamdi_command_output = `$yamdi -i $output -o $yamdi_output`;

    unless (-e $yamdi_output) {
        warn "ERROR: yamdi failed (output $yamdi_command_output)";
        $self->skip_programme($prog_id);
        return;
    }

    # Generate a thumbnail (from http://gallery.menalto.com/node/40548 )
    my $thumbnail_filename = $self->{'path'}{'output-dir'} . "tn/$prog_id.jpg";
    `mplayer $yamdi_output -ss 300 -nosound -vo jpeg:outdir=$output_dir -frames 2 2>/dev/null`;
    system("mv $output_dir/00000002.jpg $thumbnail_filename");

    my $file_size = (stat $yamdi_output)[7];
    unless ($file_size > 4096) {
        warn "ERROR: Empty file ($file_size), footage-not-available";
        $self->skip_programme($prog_id);
        return;
    }

    my $final_output_filename = $self->{'path'}{'output-dir'} . "$prog_id.flv";
    my $move = system("mv $yamdi_output $final_output_filename"); # cross domain
    if ($move) {
        warn "ERROR: Could not move $yamdi_output to $final_output_filename: $move";
        $self->skip_programme($prog_id);
        return;
    }

    unlink $input;
    unlink $output;
    $self->set_prog_status($prog_id, 'available');
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

sub calculate_offset {
    my ($d1, $d2) = @_;

    #warn "$d1 <-> $d2";

    my @d1 = BBCParl::Common::extract_datetime_array ($d1);
    my @d2 = BBCParl::Common::extract_datetime_array ($d2);
	       
    my $dt = DateTime->new(@d1);
    my $diff = $dt->subtract_datetime_absolute( DateTime->new(@d2));
    return $diff->seconds();
}

1;
