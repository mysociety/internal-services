package BBCParl::Web;

# TODO - add other input params (broadcast_start, broadcast_end) to
# allow for the streaming of programmes that have no record_start or
# record_end information

use strict;
use Cache::Memcached;
use DateTime;
use XML::Simple;
use CGI::Fast qw/:standard/;
use LWP::UserAgent;
use WebService::TWFY::API;

use mySociety::DBHandle qw (dbh);

use Data::Dumper;

sub debug {
    my ($self, $message) = @_;
    if ($self->{'debug'}) {
	warn "DEBUG: $message";
    }
    return undef;
}

sub new {
    my ($class, $cgi, %args) = @_;

    my $self = {};
    bless $self, $class;

    if (%args) {
	foreach my $key (keys %args) {
	    $self->{'args'}{$key} = $args{$key};
	}
	
	if ($self->{'args'} && $self->{'args'}{'debug'}) {
	    $self->{'debug'} = 'true';
	}
    }

    $self->{'urls'}{'video-dir'} = mySociety::Config::get('BBC_URL_FLASH_VIDEO');
    $self->{'urls'}{'video-proxy'} = mySociety::Config::get('BBC_URL_FLASH_PROXY');
    $self->{'urls'}{'thumbnail-dir'} = mySociety::Config::get('BBC_URL_THUMBNAILS');
    $self->{'urls'}{'bbcparl-logo'} = mySociety::Config::get('BBC_URL_BBCPARL_LOGO');
    $self->{'urls'}{'flash-player'} = mySociety::Config::get('BBC_URL_FLASH_PLAYER');
    $self->{'urls'}{'help'} = 'TODO';

    $self->{'flash-params'}{'width'} = 320;
    $self->{'flash-params'}{'height'} = 180;
    $self->{'flash-params'}{'display-height'} = 220;

    $self->{'cgi'} = $cgi;

    my $cache = new Cache::Memcached { 'servers' => [ 'localhost:11211' ],
				       #'debug' => 1,
				   };

    #warn Dumper $cache->stats('misc');

    $self->{'cache'} = $cache;

    return $self;

}

sub handle_request {
    my ($self) = @_;

    if ($self->process_params()) {
	if ($self->print_result()) {
	    return $self->update_cache();
	}
    }

    return undef;

}

sub update_cache {
    my ($self) = @_;

    # add new gid:datetime pairs to the cache
    
    if ($self->{'disable-cache'}) {
	$self->debug("Skipping cache update for new gids");
    } else {
	if ($self->{'cache'}) {
	    my $cache = $self->{'cache'};
	    foreach my $gid (keys %{$self->{'to-be-cached'}}) {
		#warn "cache update: $gid, $self->{'to-be-cached'}{$gid}";
		$cache->set($gid, $self->{'to-be-cached'}{$gid});
	    }
	}
    }

    return 1;

}

sub process_params {
    my ($self) = @_;

    # valid parameters are: 1) gid, 2) datetime combination; location,
    # channel, autoplay and output are optional parameters.  default
    # values are location=commons, channel=BBCParl, autoplay=false and
    # output=js

    my $cgi = $self->{'cgi'};

    unless ($cgi) {
	$self->error("Could not find CGI object",4);
	return undef;
    }

    unless ($cgi->param()) {
	$self->error("No parameters were passed to this script.",1);
	return undef;
    }
    
    unless ($cgi->param('gid') || $cgi->param('start')) {
	$self->error("Required parameters (<i>gid</i> or <i>start</i>) were not passed to this script.",1);
	return undef;
    }
    
    # outputs can be: 1) javascript that embeds a flash video into a #
    # web-page, 2) the URL of the flash video. default is 1). if both
    # XML and JS, ignore JS.

    if ($cgi->param('output') && lc($cgi->param('output')) eq 'xml') {
	$self->{'param'}{'output'} = 'xml';
    } elsif (lc($cgi->param('output')) eq 'minimal-js') {
	$self->{'param'}{'output'} = 'minimal-js';
    } else {
	$self->{'param'}{'output'} = 'js';
    }

    if ($cgi->param('verbose')) {
	$self->{'param'}{'verbose'} = 'true';
    }

    if ($cgi->param('autostart')) {
	$self->{'param'}{'autostart'} = 'true';
    }

    unless ($self->check_location_channel()) {
	$self->error("Could not determine location and/or channel",1);
    }

    # if input is a gid, lookup the gid using TWFY API and extract the
    # start datetime and location (channel is bbcparl); if both gid
    # and datetime, ignore datetime

    if ($self->{'cgi'}->param('gid')) {
	unless ($self->get_gid_details()) {
	    return undef;
	}
    } else {
	unless ($self->get_datetime()) {
	    warn "DEBUG: datetime error";
	    return undef;
	}
    }

    # in all cases, fetch the programme id and start time of any
    # footage at recording datetime (using local database)

    if ($self->get_prog_id_from_start_param()) {	

	# there is a programme covering this start datetime; let's
	# work out the offset so we can seek straight to our datetime

	$self->calculate_seconds_offset();

	# if we have been given an end datetime, use that to specify
	# the duration (not of immediate use, but we'll need it
	# eventually)

	$self->calculate_duration();

	$self->{'output'}{'result'} = 1;

    } else {

	$self->{'output'}{'result'} = 0;

    }

    return 1;
   
}

sub check_location_channel {
    my ($self) = @_;

    unless ($self) {
	return undef;
    }

    my $cgi = $self->{'cgi'};

    my ($location, $channel);

    $location = $cgi->param('location');
    if ($location) {
	$location = lc $location;
    } else {
	$location = 'commons';
    }
    $self->{'param'}{'location'} = $location;

    $channel = $cgi->param('channel');
    if ($channel) {
	$channel = lc $channel;
    } else {
	$channel = 'BBCParl';
    }
    $self->{'param'}{'channel'} = $channel;

    return 1;

}

sub error_xml {
    my ($self, $error, $code) = @_;

    my $cgi = $self->{'cgi'};

    print header(-type => 'application/xml',
		 -expires => '+1y'),
    "<error><code>$code</code><message>$error</message></error>\n";

    return undef;

}

sub error {
    my ($self, $error, $code) = @_;

    unless ($code) {
	$code = 0;
    }

    if ($self->{'param'} && $self->{'param'}{'output'} && $self->{'param'}{'output'} eq 'xml') {
	$self->error_xml($error,$code);
    } else {

	print header(-type => 'text/html');

	if ($self->{'param'} && $self->{'param'}{'verbose'}) {
	
	    print <<END;
<!--
    document.write("Error $code: $error");
// -->
END

1;

	} else {

	    print <<END;
<!--
// Error: code $code
//
// $error
//
// Please see $self->{'urls'}{'help'} for more information on how to use this service.
-->
END

1;

	}

    }

    return undef;

}

sub get_gid_details {
    my ($self) = @_;

    my $cgi = $self->{'cgi'};

    my $gid = $cgi->param('gid');
    unless ($gid) {
	$self->error("No value specified for required parameter <i>gid</i>.",1);
	return undef;
    }

    # check whether the gid is cached in memcached

    unless ($self->{'disable-cache'}) {
	my $cache = $self->{'cache'};
	
	my $cache_value = $cache->get($gid);
	#warn $cache_value;
	if ($cache_value) {
	    $self->debug("gid cache hit: $gid, $cache_value");
	    if ($cache_value =~ /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/i) {
		$self->debug("gid matches regexp: $gid, $cache_value");
		$self->{'param'}{'start'} = $cache_value;
		return $gid;
	    }
	}
    }

    my $api = WebService::TWFY::API->new();

    my $speech_response = $api->query( 'getDebates',
				       { 'type' => $self->{'param'}{'location'},
					 'gid' => $gid,
					 'output' => 'xml'
					 } );
    
    unless ($speech_response->is_success()) {
	$self->error("Sorry, there was an error fetching the necessary data from an external source (API error).  Please check your parameter values or try again later.",2);
	return undef;
    }

    my $speech_results = $speech_response->{results};
    
    unless ($speech_results) {
	$self->error("Sorry, there was an error fetching the necessary data from an external source (empty results from API).  Please check your parameter values or try again later.",2);
	return undef;
    }

    $self->debug(Dumper $speech_results);
    
    my $speech_results_ref = XMLin($speech_results,
				   'ForceArray' => ['match']);
    
    foreach my $match_ref (@{$speech_results_ref->{'match'}}) {

	# It seems that we have to cycle through parent gids, and
	# hence use the last gid datetime (since the parents may not
	# be using the correct date time)

	my $gid_date_time = "$$match_ref{'hdate'}T$$match_ref{'htime'}";
	$self->debug("gid: $gid; date-time from hansard: $gid_date_time");
	unless ($gid_date_time = $self->convert_to_UTC($gid_date_time)) {
	    warn "ERROR: convert_to_UTC returned undef result, aborting.";
	    return undef;
	}

	# add to cache list, but only actually put them in the cache
	# when the request has been served and closed

	$self->{'to-be-cached'}{$$match_ref{'gid'}} = $gid_date_time;

	if ($gid eq $$match_ref{'gid'}) {
	    $self->{'param'}{'start'} = $gid_date_time;
	}
    }

    if (my $start = $self->{'param'}{'start'}) {
	$self->debug("Created start param for this gid: $start");
	return $start;
    } else {

	# if we get to this point, it means that we didn't get our
	# chosen gid in the results from TWFY

	$self->error("Sorry, there was an error fetching the necessary data from an external source (gid was not in results from API).  Please try again later.",2);
	return undef;
    }
}

sub convert_to_UTC {
    my ($self, $date_time) = @_;

    my @date_time = extract_datetime_array($date_time);

    unless (@date_time) {
	$self->error('Internal datetime calculation error.',3);
	return undef;
    }

    # TODO - generalise the timezone so that it is based on a
    # $location lookup, not hard-coded as London/Europe.

    # create a new DateTime object with timezone London/Europe, and
    # then convert it to UTC and use UTC time

    my $dt = eval {

	my $dt = DateTime->new(@date_time,
			       'time_zone' => 'Europe/London');

	$dt->set_time_zone('UTC');
	my $date_time_format = '%FT%TZ';
	return $dt->strftime($date_time_format);

    };

    if ($@) {
	$self->error($@,5);
	return undef;
    }

    return $dt;

}

sub get_datetime {
    my ($self) = @_;

    my $cgi = $self->{'cgi'};
    my $start = $cgi->param('start');

    map {
	if ($cgi->param($_) &&
	    $cgi->param($_) =~ /^(\d{4}).?(\d{2}).?(\d{2}).+?(\d{2}).?(\d{2})(.+\d{2})?(Z|GMT)?$/i) {
	    $self->{'param'}{$_} = "$1-$2-$3T$4:$5";
	    if ($6) {
		$self->{'param'}{$_} .= $6;
	    } else {
		$self->{'param'}{$_} .= ':00';
	    }
	    if ($7) {
		$self->{'param'}{$_} .= "Z";
	    } else {
		unless ($self->{'param'}{$_} = $self->convert_to_UTC($self->{'param'}{$_})) {
		    warn "DEBUG: conversion to UTC error";
		    return undef;
		}
	    }
	}
    } ('start', 'end');

    if ($self->{'param'}{'start'}) {
	return 1;
    } else {
	$self->error("Required parameter <i>start</i> not given in correct format <i>yyyy-mm-ddThh:mm(:ss)(Z|GMT)</i>.",1);
	return undef;
    }

}

sub get_prog_id_from_start_param {
    my ($self) = @_;

    # find a programme with recording start < start < recording end,
    # on the correct channel and location.  currently the only channel
    # is BBCParl, but this option is included in case we later expand
    # our coverage to other sources (e.c. C-SPAN).  since commons
    # coverage is always carried live, this currently means that a
    # given datetime will return commons coverage if the commons is
    # sitting at that time, and the location parameter has not been
    # set to something other than commons.

    my $select_statement = "SELECT id, record_start, record_end FROM programmes " .
			    "WHERE record_start <= ? AND record_end > ? " .
			    "AND status = 'available' AND rights = 'internet' " .
			    "AND channel_id = ? AND location = ?";

    # 'start' appears twice in this list, because it is used twice as
    # a bind parameter in the SELECT statement

    my @var_names = ('start', 'start', 'channel', 'location');

    foreach my $name (@var_names) {
	unless ($self->{'param'} && $self->{'param'}{$name}) {
	    $self->error("Did not find any value for parameter $name, cannot proceed with SQL query",1);
	    return undef;
	}
    }

    my @bind_variables = map { $self->{'param'}{$_} } @var_names;

    my $st = dbh()->prepare($select_statement);
    $st->execute(@bind_variables);

    while (my @row = $st->fetchrow_array()) {

	# note the id, the start and end times

	$self->{'programme'}{'id'} = $row[0];
	$self->{'programme'}{'record-start'} = $row[1];
	$self->{'programme'}{'record-end'} = $row[2];
	last;

    }

    if ($self->{'programme'}{'id'}) {
	return $self->{'programme'}{'id'};
    } else {
	return undef;
    }

}

sub calculate_seconds_offset {
    my ($self) = @_;

    $self->debug("Comparing $self->{'programme'}{'record-start'} and $self->{'param'}{'start'}");

    if ($self->{'param'}{'start'}) {
	my $o = $self->calculate_seconds_diff($self->{'programme'}{'record-start'},
								    $self->{'param'}{'start'});
	$self->{'output'}{'offset'} = $o;
	return $self->{'output'}{'offset'};
    } else {
	return undef;
    }

}

sub calculate_byte_offset {
    my ($self) = @_;

    unless ($self->{'output'}{'offset'}) {
	return undef;
    }

    # One final thing: for a given duration in seconds, calculate the
    # actual byte offset (HEAD request to $prog_id.flv to get the
    # content-size, db lookup to get the duration of the programme, and
    # hence $offset*$size/$duration to get bytes offset. Finally, replace
    # $prog_id.flv/offset/$secs_offset output with
    # $prog_id.flv/offset/$bytes_offset

    my $prog_id = $self->{'programme'}{'id'};

    my $url = "$self->{'urls'}{'video-dir'}/$prog_id.flv";

    my $ua = LWP::UserAgent->new();

    my $response = $ua->head($url);

    if ($response->is_success) {
	my $file_size = $response->header('content-length');
	#warn Dumper $response;

	my $select_statement = "SELECT broadcast_start, broadcast_end FROM programmes where id = ?";
	my $st = dbh()->prepare($select_statement);
	$st->execute($prog_id);
	
	my ($start, $end);
	while (my @row = $st->fetchrow_array()) {
	    $start = $row[0];
	    $end = $row[1];
	    last;
	}
	
	my $duration = $self->calculate_seconds_diff($start,
						     $end);

	unless ($duration > 0) {
	    $self->error("Programme apparently lasts for negative or zero seconds",1);
	    return undef;
	}

	my $bytes_per_sec = $file_size / $duration;

	$self->{'output'}{'bytes-offset'} = $bytes_per_sec * $self->{'output'}{'offset'};

	return $self->{'output'}{'bytes-offset'};

    }

    return undef;
    
}

sub calculate_duration {
    my ($self) = @_;

    if (my $end = $self->{'param'}{'end'}) {
	$self->{'output'}{'duration'} = $self->calculate_seconds_diff($self->{'param'}{'end'},
								      $self->{'param'}{'record-end'});
	return $self->{'output'}{'duration'};
    } else {
	return undef;
    }

}

sub calculate_seconds_diff {
    my ($self, $d1, $d2) = @_;

    my (@d1, @d2);

    @d1 = extract_datetime_array($d1);
    @d2 = extract_datetime_array($d2);

    unless (@d2 && @d2) {
	$self->error('Internal datetime calculation error.',3);
	return undef;
    }

    my $diff = eval {
	
	my $dt1 = DateTime->new(@d1,'time_zone','UTC');
	my $dt2 = DateTime->new(@d2,'time_zone','UTC');
	    
	my $diff = $dt1->subtract_datetime_absolute( $dt2 );

	return $diff->seconds();

    };

    if ($@) {
	$self->error($@,5);
	return undef;
    }

    return $diff;
    
}

sub extract_datetime_array {
    my ($string) = @_;

    if ($string =~ /^(\d{4})-(\d{2})-(\d{2}).+(\d{2}):(\d{2}):(\d{2})/) {
	return ('year' => $1,
		'month' => $2,
		'day' => $3,
		'hour' => $4,
		'minute' => $5,
		'second' => $6);
    } else {
	return undef;
    }

}

sub print_result {
    my ($self) = @_;

    unless ($self->{'param'}) {
	$self->error("Could not find internal param attribute.",6);
	return undef;
    }

    # work out what sort of output is needed - full javascript,
    # minimal javascript, or XML?

    my $output = $self->{'param'}{'output'} || 'js';

    if ($self->{'output'}{'result'}) {

	# first, set up all the necessary variables (setting them to
	# empty strings if necessary)

	my $prog_id = $self->{'programme'}{'id'};

	my $secs_offset = 0;
	if (defined(my $o = $self->{'output'}{'offset'})) {
	    $secs_offset = $o;
	}
	$self->debug("Offset for this start position is $secs_offset seconds from the beginning of the file");
	$secs_offset = sprintf('%.0f',$secs_offset);
	$self->debug("Offset for this start position is $secs_offset rounded seconds from the beginning of the file");

	my $duration = '';
	if (my $d = $self->{'output'}{'duration'}) {
	    $duration = $d;
	}

	my $logo_url = $self->{'urls'}{'bbcparl-logo'};
	my $thumbnail_url = "$self->{'urls'}{'thumbnail-dir'}/$prog_id.$secs_offset.png";
	
	#   TODO - remove this next line
	$thumbnail_url = '';
	
	my $video_url = "$self->{'urls'}{'video-proxy'}/$prog_id.flv";
	my $auto_start = $self->{'param'}{'autostart'};
	if ($auto_start && $auto_start =~ /^(yes|true|y|1)/i) {
	    $auto_start = 'true';
	} else {
	    $auto_start = 'false';
	}

	my $embed = "<embed src=\"$self->{'urls'}{'flash-player'}\" width=\"$self->{'flash-params'}{'width'}\" height=\"$self->{'flash-params'}{'height'}\" allowfullscreen=\"true\" flashvars=\"&displayheight=$self->{'flash-params'}{'display-height'}&file=$video_url&height=$self->{'flash-params'}{'height'}&image=$thumbnail_url&width=$self->{'flash-params'}{'width'}&largecontrols=true&logo=$logo_url&overstretch=none&autostart=$auto_start&duration=$duration&startAt=$secs_offset\" />";
	# we need to escape all "" marks in order to place the embed string in a text box
	$embed =~ s!\"!\\\"!g;

	if ($output eq 'js' || $output eq 'minimal-js') {
	    print header(-type => 'text/html');
#		     -expires => '+1y');
	    print "<--\n";

	    if ($output eq 'js') {
		print "document.write(\"<form name='embedForm'>'\")\n";
	    }

	    print "document.write(\"$embed\")\n";

	    if ($output eq 'js') {
		print <<EMBED;
    document.write("<b>Embed:</b> <input type='text' name='embed' value='$embed' onClick='javascript:document.embedForm.embed.focus();document.embedForm.embed.select();' />");
    document.write("</form>");
EMBED
    1;
	    }

	    print '-->';
	}

	if ($output eq 'xml') {
	    print header(-type => 'application/xml');
#		     -expires => '+1y');	    
	    print "<result><url>$video_url</url></result>\n";
	}

    } else {

	# there is no available programme covering that time span

	if (lc($self->{'param'}{'output'}) eq 'xml') {

	    $self->error_xml("No programme found matching those parameters", 1);
	    return undef;

	} else {

	    print header(-type=>'text/html');
#			 -expires=>'+1y'); # send javascript, cache it for 1 year

	    if ($self->{'param'}{'verbose'}) {

		print "<!--\ndocument.write('<p>Error: no programme to display for this date/time.</p>')\n-->\n";

	    } else {

		print "<!--\n//There is no programme to display for the specified gid or datetime.\n-->\n";

	    }

	}

    }

    close STDOUT;
 
    return 1;

}

1;
