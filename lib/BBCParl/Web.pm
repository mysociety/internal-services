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
use Carp qw(cluck);
use HTML::Entities;

use mySociety::DBHandle qw (dbh);

use Data::Dumper;

sub debug {
    my ($self, $message) = @_;
    if ($self->{'debug'}) {
#	cluck "DEBUG: $message";
	warn "DEBUG: $message";
    }
    return undef;
}

sub error {
    my ($self, $error_message, $error_code) = @_;

    unless ($self->{'params'}{'output'}) {
	$self->{'params'}{'output'} = 'html';
    }

    $self->{'output'}{'error'}{'message'} = $error_message;
    $self->{'output'}{'error'}{'code'} = $error_code;

    $self->write_results();

    print '<p><pre>' . (Dumper $self) . '</pre></p>' ;

    return undef;

}

sub cache_get {
    my ($self, $key) = @_;

    unless ($self && $key) {
	warn "ERROR: Could not access cache (either self or key are missing)";
	return undef;
    }

    unless ($self->{'disable-cache'}) {
	my $cache = $self->{'cache'};
	my $cache_value = $cache->get($key);
	if ($cache_value) {
	    $self->debug("cache hit: $key, $cache_value");
	    return $key;
	}
    }

    return undef;

}

sub handle_request {
    my ($self) = @_;

    # first, check params (adding in default values as necessary)

    unless ($self->check_params()) {
	return undef;
    }

    # fetch data on programmes from the database

    $self->get_programme_data();

    # display information obtained from database

    $self->write_results();

}

sub write_results {
    my ($self) = @_;

    $self->debug("function: write_results");

    my $output = undef;
    if ($self->{'params'}{'output'}) {
	$output = lc($self->{'params'}{'output'});
    } else {
	$output = 'html';
    }

    if ($output eq 'html') {
	$self->write_html();
	$self->write_debug_html();
    } elsif ($output =~ /^js*/) {
	$self->write_js();
    }


}

sub write_js {
    my ($self) = @_;

    $self->debug("function: write_js");

    print header(-type => 'text/html');
    # TODO add a cache-control header to stop expiry for 1 year if it's certain result types...

    if (defined($self->{'output'}{'error'})) {
	print "<!-- Sorry, there was an error.  Message was: " . $self->{'output'}{'error'}{'message'} . ", error code was " . $self->{'output'}{'error'}{'code'} . ". -->";
    } elsif (defined($self->{'params'}{'gid'}) || defined($self->{'params'}{'start'})) {
	
	#my $content = '';
	foreach my $id (sort keys %{$self->{'programmes'}}) {
	    
	    my $embed_html_version = $self->get_video_embed_html($id);

	    my $embed_js_version = $embed_html_version;
	    $embed_js_version =~ s!\"!\\\"!g;

	    print "<!--\n";
	
	    my $attribution = "<br/><b>Credits:</b> Video from <a href='http://www.bbc.co.uk/parliament/'>BBC Parliament</a> and <a href='http://parlvid.mysociety.org/about'>mySociety</a><br/>";
	    my $form_start = "<form name='embedForm$id'>";

	    print "document.write(\"<b>Click 'START' to watch this debate</b>\");\n";
	    print "document.write(\"$embed_js_version\");\n";

#  //document.write("<br/><small><b>Share:</b> <input type='text' name='share' value='TODO!' onClick='javascript:document.embedForm$id.shar.focus();document.embedForm$id.share.select();' />");
            if ($embed_js_version !~ /<p class='error'>/) { # XXX
	        print <<EMBED;
document.write("$form_start");
document.write("<br/><b>Embed:</b> <input type='text' name='embed' value='$embed_js_version' onClick='javascript:document.embedForm$id.embed.focus();document.embedForm$id.embed.select();' /></small>");
document.write("$attribution</form>");
EMBED
            }

	    print '-->';
	    last;
	}
	
	#$self->write_body_js($content);

    }

}

sub write_body_js {
    my ($self, $content) = @_;

    print $content;

}

sub write_html {
    my ($self) = @_;

    $self->debug("function: write_html");

    print header(-type => 'text/html');
    # TODO add a cache-control header to stop expiry for 1 year if it's certain result types...

    if ($self->{'output'}{'error'}) {
	$self->write_error_html();
    } elsif (defined($self->{'params'}{'ymd'}) ||
	     (defined($self->{'params'}{'year'}) &&
	      defined($self->{'params'}{'month'}) &&
	      defined($self->{'params'}{'day'}))) {
	$self->write_ymd_html();
    } elsif (defined($self->{'params'}{'search'})) {
	$self->write_search_results_html();
    } elsif (defined($self->{'output'}{'recent'})) {
	$self->write_recent_programmes_html();
    } elsif (defined($self->{'params'}{'programme'})) {
	$self->write_programme_html();
    } elsif (defined($self->{'params'}{'gid'})) {
	$self->write_programme_html();
    } elsif (defined($self->{'params'}{'start'})) {
	$self->write_programme_html();
    } else {
	$self->{'output'}{'error'}{'message'} = 'Sorry, something went wrong. Not sure what, but you definitely should not be seeing this.';
	$self->{'output'}{'error'}{'code'} = 999;
    	$self->write_error_html();
    }

    $self->write_footer_html();

}

sub write_body_html {
    my ($self, $content) = @_;

print <<HTML;    
<div class="yui-b"><div class="yui-g">
$content
</div></div>
HTML

}

sub write_footer_html {
    my ($self) = @_;

    print <<HTML;
</div>
<div class="yui-b">

<div id="calendar"></div>

<fieldset id="nav-sidebar">
<legend>Search by Date</legend>
<form name="date-search" type="get" action="/search/date">
HTML

    print "<div><label for='day'>Day:</label> <select name='day'>\n";
    foreach my $day (1 .. 31) {
	print "<option value='$day'>$day</option>\n";
    }
    print "</select></div>\n";

    my %months = ('1' => 'Jan',
		  '2' => 'Feb',
		  '3' => 'Mar',
		  '4' => 'Apr',
		  '5' => 'May',
		  '6' => 'Jun',
		  '7' => 'Jul',
		  '8' => 'Aug',
		  '9' => 'Sep',
		  '10' => 'Oct',
		  '11' => 'Nov',
		  '12' => 'Dec');

    print "<div><label for='month'>Month:</label> <select name='month'>\n";
    foreach my $month (1 .. 12) {
	print "<option value='$month'>$months{$month}</option>\n";
    }
    print "</select></div>\n";

    print "<div><label for='year'>Year:</label> <select name='year'>\n";
    foreach my $year (2007 .. 2100) {
	print "<option value='$year'>$year</option>\n";
    }
    print "</select></div>\n";

    my $debug = Dumper $self;

    print <<HTML;

<input type="submit" value="Browse programmes">
</form>
</fieldset>

</div> 
</div> 
<div id="ft">
Video footage is &copy; <a href="http://www.bbc.co.uk/parliament/">BBC Parliament</a>.  Commissioned as a prototype by <a href="http://backstage.bbc.co.uk/">BBC Backstage</a>, built by <a href="http://www.mysociety.org/">mySociety</a>.
</div>
</div> 

HTML

if ($self->{'debug'}) {

    print <<HTML;
<br clear="all">
<div>
<pre>$debug</pre>
</div>
HTML

}

    print <<HTML;
</body> 
</html> 
HTML

}

sub write_ymd_html {
    my ($self) = @_;

    my $content = '';
    my $ymd = $self->{'params'}{'ymd'};
    my @date;
    if ($ymd =~ /(\d{4})[^\d]?(\d{1,2})[^\d]?(\d{1,2})/) {
	@date = ('year' => $1,
		 'month' => $2,
		 'day' => $3);

	my $ymd_separator = '/';
	
	my $dt = DateTime->new(@date);
	my $date_time_format = '%A %e %B %Y';
	my $current_date = $dt->strftime($date_time_format);
	my $current_ymd = $dt->ymd($ymd_separator);
	$dt->add('days' => 1);
	my $next_date = $dt->strftime($date_time_format);
	my $next_ymd = $dt->ymd($ymd_separator);
	$dt->subtract('days' => 2);
	my $previous_date = $dt->strftime($date_time_format);
	my $previous_ymd = $dt->ymd($ymd_separator);

	$self->write_start_html($current_date);

	$content .= "<p>Browse: <a href='/$previous_ymd'>$previous_date</a> | <a href='/$next_ymd'>$next_date</a></p>\n";

	$content .= $self->get_programme_listing_set_html('partial');

    } else {

	$self->write_start_html("Date not recognised");

	$content = "<h3>Date not recognised ($ymd)</h3>\n<p>Sorry, that date was not recognised. Please try again.</p>";
    }

    $self->write_body_html($content);

}

sub get_programme_listing_set_html {
    my ($self, $full_or_partial, $reverse) = @_;

    my @all_prog_ids = reverse sort {$a <=> $b} keys %{$self->{'programmes'}};

    if ($reverse) {
	@all_prog_ids = reverse @all_prog_ids;
    }

    my $page = 1;
    if (defined($self->{'params'}{'page'}) && ($self->{'params'}{'page'} =~ /^\d+$/)) {
	$page = $self->{'params'}{'page'};
    }

    my $page_start_number = 0;
    if ($page) {
	$page_start_number = ($page - 1) * $self->{'constants'}{'page-size'};
    }
    my $page_end_number = $page_start_number + $self->{'constants'}{'page-size'} - 1;
    
    my $content = '';
    my $item_number = 0;
    my @list_prog_ids;

    if ($self->{'debug'}) {
	$content = "page_start_number $page_start_number page_end_number $page_end_number";
    }

    foreach my $id (@all_prog_ids) {

	if ($self->{'programmes'}{$id}{'status'} eq 'available' ||
	    ($self->{'programmes'}{$id}{'status'} ne 'available' &&
	     defined($self->{'params'}{'filter'}) &&
	     $self->{'params'}{'filter'} eq 'all')) {

	    if ($item_number >= $page_start_number &&
		$item_number <= $page_end_number) {

		$content .= $self->get_programme_listing_html($id, 'auto_start' => 0, 'full_or_partial' => $full_or_partial);
		if ($self->{'debug'}) {
		    $content .= "<p>item_number $item_number</p>";
		}
	    }

	    push @list_prog_ids, $id;
	    $item_number += 1;

	}

    }

    $content = $self->get_results_page_links($page, @list_prog_ids) . $content;

    $content .= $self->get_results_page_links($page, @list_prog_ids);

    return $content;

}

sub get_results_page_links {
    my ($self, $page, @prog_ids) = @_;

    my $cgi = $self->{'cgi'};

    unless ($cgi) {
	$self->error("Could not find CGI object");
	return undef;
    }

    my $url = $cgi->url(-query => 1);
    $url =~ s/;/&/g;
    $url =~ s/[&]?page=.*//;
    unless ($url =~ /\?/) {
	$url .= '?';
    }

    my $num_results = 0;
    foreach my $id (@prog_ids) {
	if ($self->{'programmes'}{$id}{'status'} eq 'available') {
	    $num_results ++;
	}
    }

    my $num_start_results = (($page - 1) * $self->{'constants'}{'page-size'}) + 1;
    my $num_end_results = $num_start_results + $self->{'constants'}{'page-size'} - 1;
    if ($num_end_results > $num_results) {
	$num_end_results = $num_results;
    }

    my $last_page_number = ($num_results) / $self->{'constants'}{'page-size'};
    $last_page_number = int($last_page_number + 0.9);

    my $content;
    if ($self->{'debug'}) {
	$content = "$url";
    }
    $content .= "<p class='results-paging'>Results $num_start_results - $num_end_results of $num_results";
    if ($num_results > $self->{'constants'}{'page-size'}) {
	$content .=" &mdash; page: ";
	for (my $page_number = 1; $page_number <= $last_page_number; $page_number++) {
	    if ($page eq $page_number) {
		$content .= "$page_number ";
	    } else {
		$content .= "<a href='$url&page=$page_number'>$page_number</a> ";
	    }
	}
	$content .= "</p>";
    }

    return $content;

}

sub write_recent_programmes_html {
    my ($self) = @_;

    $self->write_start_html("Recent programmes");

    my $content = "<p>Showing the most recently recorded programmes that are available to watch online.</p>";

    $content .= $self->get_programme_listing_set_html('partial');

    $self->write_body_html($content);

}

sub write_programme_html {
    my ($self) = @_;

    my @all_prog_ids = reverse sort {$a <=> $b} keys %{$self->{'programmes'}};
    my $id = $all_prog_ids[0];

    my $content = '';

    $content .= $self->get_programme_listing_set_html('full');

    my $title = $self->{'programmes'}{$id}{'title'} .
	" (broadcast on " . $self->{'programmes'}{$id}{'date'} .
	" at " . $self->{'programmes'}{$id}{'time'} .
	")";

    $self->write_start_html($title);

    $self->write_body_html($content);

}

sub get_programme_listing_html {
    my ($self, $id, %params) = @_;

    my $video_embed_code = $self->get_video_embed_html($id, %params);

    my $title = $self->{'programmes'}{$id}{'title'};
    my $datetime = $self->{'programmes'}{$id}{'broadcast-start'};
    if (defined($self->{'programmes'}{$id}{'start'})) {
	$datetime = $self->{'programmes'}{$id}{'start'};
    }
    my $description = $self->{'programmes'}{$id}{'synopsis'};
    my $channel_id = $self->{'programmes'}{$id}{'channel-id'};
    my $channel = '';
    my $offset = $self->{'programmes'}{$id}{'offset'};

    if ($channel_id && $channel_id eq 'BBCParl') {
	$channel = 'BBC Parliament';
    }

    my $date = '';
    my $time = '';
    my $ymd = '';

    my %months = ('01' => 'January',
		  '02' => 'February',
		  '03' => 'March',
		  '04' => 'April',
		  '05' => 'May',
		  '06' => 'June',
		  '07' => 'July',
		  '08' => 'August',
		  '09' => 'September',
		  '10' => 'October',
		  '11' => 'November',
		  '12' => 'December');

    if ($datetime =~ /(\d{4})-(\d{2})-(\d{2}).(\d{2}):(\d{2}):(\d{2})/) {
	$date = "$3 $months{$2} $1";
	$time = "$4:$5";
	$ymd = "$1/$2/$3";
    }

    $self->{'programmes'}{$id}{'date'} = $date;
    $self->{'programmes'}{$id}{'time'} = $time;

    my $listing_html = "";
    my $type = "";
    my $var = "";
    my $speech_or_broadcast = '';
    if (defined($self->{'programmes'}{$id}{'gid'})) {
	$type = 'gid';
	$var = $self->{'programmes'}{$id}{'gid'};
	$speech_or_broadcast = 'Speech';
    } else {
	$type = 'programme';
	$var = $id;
	$speech_or_broadcast = 'Broadcast';
    }

    $listing_html = "<div class='results-title'><img src='/movie.gif' align='middle' width='20' height='22' alt='Video'> <b>$title &mdash; <a href='/$type/$var/autostart'>watch it online</a></b></div>";
    $listing_html .= "<div class='results-description'>$description</div><div class='results-description'>$speech_or_broadcast at $time on <a href='/$ymd'>$date</a>.";

    if (defined($self->{'programmes'}{$id}{'gid'})) {
	$listing_html .= " Read the transcript on <a href='http://www.theyworkforyou.com/debates/?id=$self->{'programmes'}{$id}{'gid'}'>TheyworkForYou.com</a>";
    }

    $listing_html .= "</div>";

    if ($self->{'debug'}) {
	$self->debug("params: " . Dumper %params);
    }

    my $content;
    if ($params{'full_or_partial'} eq 'partial') {
	$content = "<div class='text-listing'>$listing_html</div>";
    } else {
	$content = "<div class='video-container'><div class='video-embed'>$video_embed_code</div><div class='programme-info'>$listing_html</div></div>";
    }

    return $content;

}

sub get_video_embed_html {
    my ($self, $id, %params) = @_;

    my $auto_start = '';
    if ($self->{'params'}{'autostart'}) {
	unless (defined($self->{'output'}{'autostart'})) {
	    $auto_start = '&autoStart=true';
	    $self->{'output'}{'autostart'} = 1;
	}
    }

    my $filename = "$id.flv";
    my $video_url = $self->{'urls'}{'video-proxy'} . "/$filename";
    my $thumbnail_url = "http://parlvid.mysociety.org/bbcparl-logo.png";
    my $duration = '';
    my $secs_offset = $self->{'programmes'}{$id}{'offset'};
    unless ($secs_offset) {
	$secs_offset = 0;
    }
    
    my $embed_html = '';

    if ($self->{'programmes'}{$id}{'rights'} eq 'internet'
	&&
	$self->{'programmes'}{$id}{'status'} eq 'available') {
	$embed_html =
	    '<embed src="' . $self->{'urls'}{'flash-player'} . '"' .
	    ' width="' . $self->{'flash-params'}{'width'} . '"' .
	    ' height="' . $self->{'flash-params'}{'height'} . '"' .
	    ' allowfullscreen="true"' .
	    ' flashvars="&displayheight=' . $self->{'flash-params'}{'display-height'} .
	    "&file=$video_url&height=" . $self->{'flash-params'}{'height'} .
	    "&previewImage=$thumbnail_url&width=" . $self->{'flash-params'}{'width'} .
	    '&largecontrols=true&logo=' . $self->{'urls'}{'bbcparl-logo'} .
	    '&secondsToHide=0' .
	    "$auto_start&duration=$duration&startAt=$secs_offset" .
	    '" />';
    } else {
	$embed_html = "<p class='error'><b>We are very sorry about this, but it looks like that programme is not available for you to download.</b></p>";
    }

    return $embed_html;

}

sub write_search_results_html {
    my ($self) = @_;

    my $query = $self->{'params'}{'query'};

    if ($query) {
	$self->write_start_html("Search results for: $query");
    } else {
	$self->write_start_html($self->{'constants'}{'search-tip'});
    }

    my $content = '';

    if (defined($self->{'people'})) {

	my $num_ppl = keys %{$self->{'people'}};

	if ($num_ppl == 1) {

	    my @person_ids = keys %{$self->{'people'}};
	    $self->debug("person ids: " . join(',',@person_ids));
	    my $person_id = $person_ids[0];
	    foreach my $match_ref (@{$self->{'people'}{$person_id}{'speeches'}{'rows'}{'match'}}) {
		$self->debug(Dumper $match_ref);
		my $name = $$match_ref{'speaker'}{'first_name'} . ' ' . $$match_ref{'speaker'}{'last_name'};
		my $party = $$match_ref{'speaker'}{'party'};
		my $const = $$match_ref{'speaker'}{'constituency'};
		$content .= "<h3>Recent footage for: <a href='/person/$person_id'>$name</a> ($party, $const)</h3>";
		$query = undef;
		last;
	    }

	} elsif ($num_ppl > 1) {

	    $content .= "<div id='mps-list'><h3>MPs matching '$query':</h3>\n<ul>\n";
	    foreach my $person_id (sort keys %{$self->{'people'}}) {
		$content .= "<li><a href='/person/$person_id'>" . $self->{'people'}{$person_id}{'name'} . "</a> (" . $self->{'people'}{$person_id}{'party'} . ", " . $self->{'people'}{$person_id}{'constituency'} . ")</li>";
	    }
	    $content .= "</ul></div>";

	}

    }

    if (defined($self->{'programmes'})) {

	if ($query) {
	    $content .= "<h3>Video results matching: $query</h3>";
	}
    
	$content .= $self->get_programme_listing_set_html('partial');

    }

    unless ($content) {
	if ($self->{'params'}{'query'}) {
	    $content .= '<p>No results for that search - please try again.</p>';
	} else {
	    $content .= '<p>' . $self->{'constants'}{'search-tip'} . '</p>';
	}
    }

    $self->write_body_html($content);

}

sub write_error_html {
    my ($self) = @_;

    $self->write_start_html("Error");
    
    print <<HTML;
<h3>Sorry, something went wrong.</h3>
    <p>$self->{'output'}{'error'}{'message'}</p>
    <p>Technical note: the error code was $self->{'output'}{'error'}{'code'}.</p>
HTML

}

sub write_start_html {
    my ($self, $title_string) = @_;

    if ($self->{'output'}{'header-printed'}) {
	return undef;
    }

    my $service_name = 'UK Parliament Online Video Archive';

    my $title = '';
    if ($title_string) {
	$title = $title_string;
    } else {
	$title = "Welcome";
    }

    my $search_tip = $self->{'constants'}{'search-tip'};
    my $search_size = length($search_tip);
    my $search_value = '';

    if ($self->{'params'}{'query'}) {
	$search_value = $self->{'params'}{'query'};
    } else {
	$search_value = $search_tip;
    }

    my $style_yahoo_base = $self->{'urls'}{'stylesheets'}{'yahoo'};
    my $style_yahoo_calendar = $self->{'urls'}{'stylesheets'}{'yahoo-calendar'};
    my $yahoo_js_deps = $self->{'urls'}{'js'}{'yahoo-calendar-deps'};
    my $yahoo_js_source = $self->{'urls'}{'js'}{'yahoo-calendar-source'};

    print <<HTML;
<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<title>$title - $service_name</title>
<link rel="stylesheet" href="$style_yahoo_base" type="text/css">
<link rel="stylesheet" href="$style_yahoo_calendar" type="text/css">
<link href="/style/layout.css" rel="stylesheet" type="text/css">
<!-- <script type="text/javascript" src="$yahoo_js_deps"></script> -->
<!-- <script type="text/javascript" src="$yahoo_js_source"></script> -->
</head>
<body class=" yui-skin-sam">
<div id="doc" class="yui-t4"> 
<div id="hd">
<span class="search-form">
<form method="get" action="/search" id="search_top">
<input type="text" name="query" size="$search_size" value="$search_value">
<input type="submit" name="submit" value="Search">
</form>
</span>
<h1><b>$service_name</b> <span class="beta-test">Beta Test</span></h1>
</div>

<div id="bd"> 
<div id="yui-main"> 

<h3><a href="/">Home</a> / $title_string</h3>

HTML

    $self->{'output'}{'header-printed'} = 1;

}

sub write_debug_html {
    my ($self) = @_;

    return undef;
    print '<p><b>Debugging information:</b></p><p><pre>' . (Dumper $self) . '</pre></p>' ;

}

sub get_date_strings {
    my ($self, $ymd) = @_;

    my @date;
    $self->debug($ymd);
    if ($ymd =~ /(\d{4})[^\d]?(\d{1,2})[^\d]?(\d{1,2})/) {
#    if ($ymd =~ /(\d{4}).?(\d{1-2}).?(\d{1-2})/) {
	@date = ('year' => $1,
		 'month' => $2,
		 'day' => $3);
    } else {
	return undef;
    }

    $self->debug("date array: " . join (',', @date));

    my $ymd_separator = '/';

    my $dt = DateTime->new(@date);
    my $date_time_format = '%A %e %B %Y';
    my $current_date = $dt->strftime($date_time_format);
    my $current_ymd = $dt->ymd($ymd_separator);
    $dt->add('days' => 1);
    my $next_date = $dt->strftime($date_time_format);
    my $next_ymd = $dt->ymd($ymd_separator);
    $dt->subtract('days' => 2);
    my $previous_date = $dt->strftime($date_time_format);
    my $previous_ymd = $dt->ymd($ymd_separator);
    return ($current_ymd, $current_date, $previous_ymd, $previous_date, $next_ymd, $next_date);

}

sub print_main_search_form {
    my ($self, $query) = @_;

    $self->debug("print main search form: $query");

    unless ($query) {
	$query = '';
    }

    print <<HTML;
<form name="search-form-main" method="get" action="/search">
<input name="query" size="20" value="$query">
<input type="submit" value="Search for MPs, programme names and debate text">
</form>

HTML
1;

}

sub print_html_header {
    my ($self, $input) = @_;

    if ($self->{'output'}{'header-done'}) {
	return undef;
    }

    my ($current_ymd, $current_date, @others) = $self->get_date_strings($input);

    my $title = '';
    if ($current_date) {
	$title = $current_date;
    } else {
	$title = $input;
    }

    my $service_name = 'UK Parliament Online Video Archive';

    print <<HTML;
<html>
<head>
<title>$title - $service_name</title>
<link href="/style/html.css" rel="stylesheet" type="text/css">
</head>
<body>

<div id="search-form">
<form name="search-form" method="get" action="/search">
<input name="query" size="20">
<input type="submit" value="Search for MPs, programme names and debate text">
</form>
</div>

<h2><a href="/home">$service_name</a></h2>

HTML

if (defined($self->{'output'}) && defined($self->{'output'}{'recent'})) {
    print <<HTML;
    <p class='message'>
<b>An online video archive of the UK Parliament and other political bodies in the UK.</b>
The $self->{'output'}{'recent'} most recent programmes are shown below.
</p>

HTML

}

    print <<HTML;

<div id="wrapper">
<div id="content">
HTML

$self->{'output'}{'header-done'} = 1;

}

sub print_html_footer {
    my ($self, $ymd) = @_;

    my ($current_ymd, $current_date, $previous_ymd, $previous_date, $next_ymd, $next_date) = $self->get_date_strings($ymd);

    my $debug = Dumper $self;

    print <<HTML;
<!-- end content div --></div>
<div id='calendar'>

<div id="nav-sidebar">

<fieldset class="nav-sidebar">
<legend>Quick Links</legend>
<ul>
HTML

if ($ymd) {

    print <<HTML;
<li><a href="/$previous_ymd">Previous day</a></li>
<li><a href="/$next_ymd">Next day</a></li>
HTML

}

    print <<HTML;
<li><a href="/home/">Recent programmes</a></li>
</ul>
</fieldset>

<fieldset id="nav-sidebar">
<legend>Search by Date</legend>
<form name="date-search" type="get" action="/search/date">
HTML

    print "<label for='day'>Day:</label> <select name='day'>\n";
    foreach my $day (1 .. 31) {
	print "<option value='$day'>$day</option>\n";
    }
    print "</select><br/>\n";

    my %months = ('1' => 'Jan',
		  '2' => 'Feb',
		  '3' => 'Mar',
		  '4' => 'Apr',
		  '5' => 'May',
		  '6' => 'Jun',
		  '7' => 'Jul',
		  '8' => 'Aug',
		  '9' => 'Sep',
		  '10' => 'Oct',
		  '11' => 'Nov',
		  '12' => 'Dec');

    print "<label for='month'>Month:</label> <select name='month'>\n";
    foreach my $month (1 .. 12) {
	print "<option value='$month'>$months{$month}</option>\n";
    }
    print "</select><br/>\n";

    print "<label for='year'>Year:</label> <select name='year'>\n";
    foreach my $year (2007 .. 2100) {
	print "<option value='$year'>$year</option>\n";
    }
    print "</select><br/>\n";

    print <<HTML;

<input type="submit" value="Browse programmes">
</form>
</fieldset>

</div>
<!-- end wrapper div --></div>
<div id="footer">
<p>This site was hand-made by robots / <a href="/about/">More info</a></p>
<pre>
$debug
</pre>
</div>
</body></html>

HTML

}

sub check_params {
    my ($self) = @_;

    # setup cgi object and check that some params have been given

    my $cgi = $self->{'cgi'};

    unless ($cgi) {
	$self->error("Could not find CGI object",4);
	return undef;
    }

#    unless ($cgi->param()) {
#	$self->error("No parameters were passed to this script.",1);
#	return undef;
#    }

    my %params = ('action' => 'watch',
		  'output' => 'html',
		  'location' => 'commons',
		  'channel' => 'BBCParl',
		  'gid' => '',
		  'start' => '',
		  'end' => '',
		  'programme' => '',
		  'ymd' => '',
		  'autostart' => '',
		  'offset' => '',
		  'search' => '',
		  'query' => '',
		  'day' => '',
		  'month' => '',
		  'year' => '',
		  'filter' => '',
		  'person' => '',
		  'page' => '',
		  'debug' => ''
		  );

    foreach my $key (keys %params) {
	my $value = $cgi->param($key);

	# if there's no user-supplied value for a given parameter, use
	# the default value (can be an empty string)

	if ($value) {
	    $value = HTML::Entities::encode($value);
	}

	if ((defined($value) && $value eq '') || (!defined($value))) {
	    $value = $params{$key};
	}
	unless ($value eq '') {
	    $self->{'params'}{$key} = $value;
	    $self->debug("Value of parameter $key is $value");
	}
    }

    unless ($self->valid_output_param()) {
	$self->error("Output parameter ($self->{'params'}{'output'}) is not a recognised value.",15);
	return undef;
    }

    return 1;

}

sub valid_output_param {
    my ($self) = @_;

    unless (defined($self->{'params'}{'output'})) {
	return undef;
    }

    map {
	if (lc($self->{'params'}{'output'}) eq $_) {
	    return 1;
	}
    } qw (html js-full js-minimal js-list xml);

    return undef;

}

sub get_programme_data {
    my ($self) = @_;

    # the actual data that we fetch depends on the action parameter

    $self->debug("getting programme data");

    unless ($self->{'params'} && $self->{'params'}{'action'}) {
	$self->error("No action parameter was specified",0);
	return undef;
    }

    my $action = lc($self->{'params'}{'action'});

    if ($self->{'params'}{'search'} || $self->{'params'}{'query'} || $self->{'params'}{'person'}) {
	unless ($self->get_programmes_from_search()) {
	    return undef;
	}
    }

    elsif ($self->{'params'}{'ymd'}) {
	unless ($self->get_programmes_from_ymd()) {
	    return undef;
	}
    }


    # we're looking for a specific programme, either by gid, prog or
    # start date-time (if we get a valid gid with an available
    # programme, it will create a start date-time param for us)

    elsif ($self->{'params'}{'gid'}) {
	unless ($self->get_programme_from_gid()) {
	    return undef;
	}
	unless ($self->calculate_seconds_offsets()) {
	    return undef;
	}
    }
    
    elsif ($self->{'params'}{'programme'}) {
	unless ($self->get_programme_from_prog()) {
	    return undef;
	}
    }
    
    elsif ($self->{'params'}{'start'}) {
	unless ($self->get_programme_from_start()) {
	    return undef;
	}
	unless ($self->calculate_seconds_offsets()) {
	    return undef;
	}
    }
   
    else {
	unless ($self->get_recent_programmes()) {
	    return undef;
	}
    }

    $self->debug("Got all the data that we need");

    return 1;

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

    $self->{'urls'}{'stylesheets'}{'yahoo'} = "http://yui.yahooapis.com/2.3.1/build/reset-fonts-grids/reset-fonts-grids.css";
    $self->{'urls'}{'stylesheets'}{'yahoo-calendar'} = "http://yui.yahooapis.com/2.3.1/build/calendar/assets/skins/sam/calendar.css";
    $self->{'urls'}{'js'}{'yahoo-calendar-deps'} = "http://yui.yahooapis.com/2.3.1/build/yahoo-dom-event/yahoo-dom-event.js";
    $self->{'urls'}{'js'}{'yahoo-calendar-source'} = "http://yui.yahooapis.com/2.3.1/build/calendar/calendar-min.js";

    $self->{'flash-params'}{'width'} = 360;
    $self->{'flash-params'}{'height'} = 300;
    $self->{'flash-params'}{'display-height'} = 300;

    $self->{'cgi'} = $cgi;

    $self->{'constants'}{'twfy-api-location'} = 'http://www.theyworkforyou.com/api/';
    $self->{'constants'}{'search-tip'} = "Search for an MP or programme";

    $self->{'constants'}{'page-size'} = 10;
    $self->{'constants'}{'recent-programmes'} = 50;

    my $cache = new Cache::Memcached { 'servers' => [ 'localhost:11211' ],
				       #'debug' => 1,
				   };

    #warn Dumper $cache->stats('misc');

    $self->{'cache'} = $cache;

    return $self;

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

sub get_recent_programmes {
    my ($self, $number) = @_;

    unless ($number) {
	$number = $self->{'constants'}{'recent-programmes'};
    }

    $self->{'output'}{'recent'} = $number;

    my $select_statement = "SELECT id, record_start, record_end, title, synopsis, rights, status, channel_id, broadcast_start, broadcast_end FROM programmes " .
	"WHERE status = 'available' ORDER BY id DESC LIMIT ?";

    my $st = dbh()->prepare($select_statement);
    $st->execute($number);

    my $last_programme_id = undef;
    while (my @row = $st->fetchrow_array()) {

	# note the id, the start and end times
	
	$self->update_programmes_hash(@row);

	$last_programme_id = $row[0];

    }

    $self->debug("Got database results: " . Dumper $self->{'programmes'} );

    if (defined($last_programme_id)) {
	return $last_programme_id;
    } else {
	return -1;
    }

}

sub update_programmes_hash {
    my ($self, @row) = @_;

    if (defined($self->{'programmes'}{$row[0]})) {
	$self->debug("Not updating anything in $row[0]");
	return undef;
    }

    $self->{'programmes'}{$row[0]}{'id'} = $row[0];
    $self->{'programmes'}{$row[0]}{'record-start'} = $row[1];
    $self->{'programmes'}{$row[0]}{'record-end'} = $row[2];
    $self->{'programmes'}{$row[0]}{'title'} = HTML::Entities::encode($row[3]);
    $self->{'programmes'}{$row[0]}{'synopsis'} = HTML::Entities::encode($row[4]);
    $self->{'programmes'}{$row[0]}{'rights'} = $row[5];
    $self->{'programmes'}{$row[0]}{'status'} = $row[6];
    $self->{'programmes'}{$row[0]}{'channel_id'} = $row[7];
    $self->{'programmes'}{$row[0]}{'broadcast-start'} = $row[8];
    $self->{'programmes'}{$row[0]}{'broadcast-end'} = $row[9];
    
}

sub get_programmes_from_search {
    my ($self) = @_;

    $self->debug("get_programmes_from_search");

    if ($self->{'params'}{'year'} &&
	$self->{'params'}{'month'} &&
	$self->{'params'}{'day'}) {
	my @date = (
		    $self->{'params'}{'year'},
		    $self->{'params'}{'month'},
		    $self->{'params'}{'day'});
	$self->debug(join (',', @date));
	$self->{'params'}{'ymd'} = join('-', @date);
	return $self->get_programmes_from_ymd();
    }

    if (defined($self->{'params'}{'query'})) {

	if ($self->{'params'}{'query'} =~ /^\s+$/ ||
	    length ($self->{'params'}{'query'}) < 3) {
	    return 1;
	} else {
	    $self->search_for_mps();
	    if (defined($self->{'params'}{'person'})) {
		my $num_results = $self->get_programmes_from_person();
		if ($num_results > 0) {
		    return 1;
		}
	    }
	    $self->get_programmes_from_query();
	    return 1;
	}

    } elsif (defined($self->{'params'}{'person'})) {

	$self->search_for_mps();
	my $num_results = $self->get_programmes_from_person();
	unless ($num_results) {
	    $self->get_programmes_from_query();
	}
	return 1;

    } else {
		
	$self->debug("No query for search");
	return 1;

    }

}

sub search_for_mps {
    my ($self) = @_;
    
    my $api = WebService::TWFY::API->new();
	
    my @names = ();

    if (defined($self->{'params'}{'query'})) {

	my $response = $api->query( 'getMPs',
				    {
					'search' => $self->{'params'}{'query'},
					'output' => 'xml',
				    } );
	
	unless ($response->is_success()) {
	    warn "ERROR: Could not fetch data from TWFY API; error was " . $response->status_line();
	    warn "ERROR: Skipping MP names search";
	    return undef;
	}
	
	my $results = $response->{results};
	
	# get the response into some usable form
	
	my $results_ref = XMLin($results,
				'ForceArray' => ['match']);
	
	$self->{'results'} = $results_ref;
	
	@names = sort keys %{$results_ref->{'match'}};
	
	foreach my $name (@names) {
	    
	    my $person_id = $results_ref->{'match'}{$name}{'person_id'};
	    map { $self->{'people'}{$person_id}{$_} = $results_ref->{'match'}{$name}{$_}; } 
	    qw (party constituency);
	    $self->{'people'}{$person_id}{'name'} = $name;
	    
	}

	if (scalar @names == 1) {
	    
	    # fetch debates from TWFY for person_id, and call get_programmes_by_gid for each MP

	    $self->debug("just one person with that name");
	    
	    my $person_id = $results_ref->{'match'}{$names[0]}{'person_id'};
	    $self->{'params'}{'person'} = $person_id;
	    $self->{'params'}{'query'} = $self->{'people'}{$person_id}{'name'};
	    
	}

    }

    return scalar @names;

}

sub get_programmes_from_ymd {
    my ($self, $ymd) = @_;

    unless ($ymd) {
	if ($self->{'params'}{'ymd'}) {
	    $ymd = $self->{'params'}{'ymd'};
	} else {
	    $self->error("No value specified for required parameter 'ymd'.",1);
	    return undef;
	}
    }

    $self->debug("getting data using ymd param $ymd");

    my ($start_date_time, $end_date_time) = ('','');

    if ($ymd =~ /(\d{4})[^\d]?(\d{1,2})[^\d]?(\d{1,2})/) {
	my @ymd = ('year' => $1,
		   'month' => $2,
		   'day' => $3);

	my $date_time_format = '%FT%TZ';
	
	$start_date_time = eval {
	    my $dt = DateTime->new(@ymd,
				   'hour' => 0,
				   'minute' => 0,
				   'second' => 0);
	    return $dt->strftime($date_time_format);
	};

	$end_date_time = eval {
	    my $dt = DateTime->new(@ymd,
				   'hour' => 23,
				   'minute' => 59,
				   'second' => 59);
	    return $dt->strftime($date_time_format);
	};

	if ($@) {
	    $self->error("Sorry, that date was not recognised - please try again with a correct date.",14);
	    return undef;
	}

    } else {
	$self->error("Sorry, that date was not recognised - please try again with a correct date.",14);
	return undef;
    }

    if ($self->get_programmes_from_database('time-period',
					    $start_date_time,
					    $end_date_time,
					    $self->{'params'}{'channel'},)) {

	# don't just want to show commons coverage in our listing
	# $self->{'params'}{'location'})) {

	foreach my $id (keys %{$self->{'programmes'}}) {
	    $self->{'programmes'}{$id}{'offset'} = 0;
	}
    }

    return 1;
}

sub get_programmes_from_query {
    my ($self) = @_;

    $self->debug("searching in database for programmes about " . $self->{'params'}{'query'});

    if ($self->{'params'}{'query'}) {
	if ($self->get_programmes_from_database('title-synopsis',
						$self->{'params'}{'query'},
						$self->{'params'}{'channel'},)) {
	    
	    foreach my $id (keys %{$self->{'programmes'}}) {
		$self->{'programmes'}{$id}{'offset'} = 0;
	    }
	}
	return 1;
    } else {
	$self->{'output'}{'error'}{'message'} = "Sorry, could not search for an empty string";
	$self->{'output'}{'error'}{'code'} = 41;
	return undef;
    }

}

sub get_programmes_from_person {
    my ($self, $person_id) = @_;

    my $api = WebService::TWFY::API->new();

    unless ($person_id) {
	$person_id = $self->{'params'}{'person'};
    }

    $self->debug("get_programmes_from_person - getting speeches for person id: $person_id");
    
    my $speech_response = $api->query ( 'getDebates',
					{ 'type' => 'commons',
					  'person' => $person_id,
					  'output' => 'xml'
					  } );
    
    unless ($speech_response->is_success()) {
	$self->debug("ERROR: Could not fetch data from TWFY API; error was " . $speech_response->status_line(), 16);
    }
    
    my $speech_results = $speech_response->{results};
    
    my $speech_results_ref = XMLin($speech_results,
				   'ForceArray' => ['match']);

    $self->debug(Dumper $speech_results_ref);
    
    $self->{'people'}{$person_id}{'speeches'} = $speech_results_ref;

    my $num_results = 0;
    foreach my $match_ref (@{$speech_results_ref->{'rows'}{'match'}}) {

	$num_results ++;
	
	my $gid = $$match_ref{'gid'};
	
	$self->debug($gid);
	
	$self->debug(Dumper $self->{'params'});
	
	my $prog_id = $self->get_programme_from_gid($gid);
	
    }

    if ($num_results > 0) {

	$self->calculate_seconds_offsets();

    } else {

	if ($speech_results_ref->{'searchdescription'} =~ /spoken by (.+) in/gi) {
	    unless ($1 =~ /^\s*$/) {
		$self->{'params'}{'query'} = lc($1);
		return $num_results;
	    }
	}

	$self->debug("Cannot work out person name");
	$self->{'output'}{'error'}{'message'} = "Sorry, could not work out the name of that person.";
	$self->{'output'}{'error'}{'code'} = 40;
    
    }

    return $num_results;
    
}

sub get_programme_from_prog {
    my ($self) = @_;

    $self->debug("getting data using prog param");

    my $prog = undef;

    if ($self->{'params'}{'programme'}) {
	$prog = $self->{'params'}{'programme'};
    } else {
	$self->error("No value specified for required parameter 'programme'.",1);
	return undef;
    }

    if ($self->get_programmes_from_database('prog',$prog) == $prog) {
	# got the programme details - check if it's available and if it's okay for internet streaming 
	if (defined($self->{'programmes'}) && defined($self->{'programmes'}{$prog})) {
	    if ($self->{'programmes'}{$prog}{'status'} eq 'available') {
		if ($self->{'programmes'}{$prog}{'rights'} eq 'internet') {
		    $self->{'programmes'}{$prog}{'offset'} = 0;
		    return $prog;
		} else {
		    $self->error("That programme is not available to watch online - only a subset of all programmes are allowed to be streamed over the Internet.  Sorry about that.",13);
		    return undef;
		}
	    } else {
		$self->error("That programme is not available to watch online - the footage was probably not captured correctly by our computers.  Sorry about that - we promise to try harder in future!",12);
		return undef;
	    }
	}
   } else {
	# didn't get the programme details
	$self->error("There is no programme with that programme id.",11);
	return undef;
    }

}

sub get_programme_from_gid {
    my ($self, $gid) = @_;

    unless (defined($gid)) {
	if ($self->{'params'}{'gid'}) {
	    $gid = $self->{'params'}{'gid'};
	} else {
	    $self->error("No value specified for required parameter 'gid'.",1);
	    return undef;
	}
    }

    $self->debug("getting data using gid param $gid");

    # check whether the gid is cached in memcached and if so, whether
    # the value matches the correct regexp for date-time

    # TODO - cache key=value needs to be updated

#    my $cache_value = undef;
#    if ($cache_value = $self->cache_get($gid)) {
#	if ($cache_value =~ /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/i) {
#	    $self->debug("gid matches regexp: $gid, $cache_value");
#	    $self->{'params'}{'start'} = $cache_value;
#	    $self->{'output'}{'gid'} = $gid;
#	    return $gid;
#	}
#    }

    my $api = WebService::TWFY::API->new();

    my $speech_response = $api->query( 'getDebates',
				       { 'type' => $self->{'params'}{'location'},
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

#    $self->debug(Dumper $speech_results);
    
    my $speech_results_ref = XMLin($speech_results,
				   'ForceArray' => ['match']);
    
    foreach my $match_ref (@{$speech_results_ref->{'match'}}) {

	# It seems that we have to cycle through parent gids, and
	# hence use the last gid datetime (since the parents may not
        # be using the correct date time)

	my $gid_date_time = "$$match_ref{'hdate'}T$$match_ref{'htime'}";
	$self->debug("gid: " . $$match_ref{'gid'} . "; date-time from hansard: $gid_date_time");
	unless ($gid_date_time = $self->convert_to_UTC($gid_date_time)) {
	    warn "ERROR: convert_to_UTC returned undef result, aborting.";
	    return undef;
	}

	# add to cache list, but only actually put them in the cache
	# when the request has been served and closed

	$self->{'to-be-cached'}{$$match_ref{'gid'}} = $gid_date_time;

	if ($gid eq $$match_ref{'gid'}) {
	    my $prog_id = $self->get_programme_from_start($gid_date_time);
	    if (defined($prog_id)
		&&
		($self->{'programmes'}{$prog_id}{'start'} eq $gid_date_time)) {

		# store title and sysnopsis somewhere else, and
		# overwrite it each time with the correct values for
		# the first gid encountered in a given speech
		
		$self->{'programmes'}{$prog_id}{'gid'} = $$match_ref{'gid'};

		$self->{'gids'}{$gid}{'title'} = $$match_ref{'parent'}{'body'};
		$self->{'gids'}{$gid}{'body'} = $$match_ref{'body'};


	    }
	    return $prog_id;
	}
    }

    # if we get to this point, it means that we didn't get our
    # chosen gid in the results from TWFY
    
    $self->error("Sorry, there was an error fetching the necessary data from an external source (gid was not in results from API).  Please try again later.",2);
    return undef;
    
}

sub convert_to_UTC {
    my ($self, $date_time) = @_;

    my @date_time = $self->extract_datetime_array($date_time);

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

sub get_start_end_tidy {
    my ($self, $datetime) = @_;

    if ($datetime &&
	$datetime =~ /^(\d{4}).?(\d{2}).?(\d{2}).+?(\d{2}).?(\d{2})(.+\d{2})?(Z|GMT)?$/i) {
	
	$datetime = "$1-$2-$3T$4:$5";
	if ($6) {
	    $datetime .= $6;
	} else {
	    $datetime .= ':00';
	}
	if ($7) {
	    $datetime .= "Z";
	} else {
	    unless ($datetime = $self->convert_to_UTC($datetime)) {
		$self->debug("DEBUG: conversion to UTC error");
		return undef;
	    }
	}
	return $datetime;
    } else {
	return undef;
    }
    
}

sub get_programme_from_start {
    my ($self, $start) = @_;

    unless ($start) {
	$start = $self->{'params'}{'start'};
    }

    $start = $self->get_start_end_tidy($start); 

    unless ($start) {
	$self->error("Required parameter <i>start</i> not given in correct format <i>yyyy-mm-ddThh:mm(:ss)(Z|GMT)</i>.",1);
	return undef;
    }

    # find a programme with recording start < start < recording end,
    # on the correct channel and location.  currently the only channel
    # is BBCParl, but this option is included in case we later expand
    # our coverage to other sources (e.c. C-SPAN).  since commons
    # coverage is always carried live, this currently means that a
    # given datetime will return commons coverage if the commons is
    # sitting at that time, and the location parameter has not been
    # set to something other than commons.

    $self->debug("Looking up programme id for start time $start");

    # 'start' appears twice in this list, because it is used twice as
    # a bind parameter in the SELECT statement

    my $prog_id = $self->get_programmes_from_database('time-stamp',
						      $start,
						      $start,
						      $self->{'params'}{'channel'},
						      $self->{'params'}{'location'});

    if (defined($prog_id)) {
	$self->debug("Programme id was $prog_id");
	if (defined($self->{'programmes'}{$prog_id}{'start'})) {
	    if ($self->{'programmes'}{$prog_id}{'start'} gt $start) {
		$self->debug("Updating start param with value: $start");
		$self->{'programmes'}{$prog_id}{'start'} = $start;
	    } else {
		$self->debug("Keeping start for $prog_id at $self->{'programmes'}{$prog_id}{'start'}");
		# don't return more than one reference per programme? TODO - resolve this!!!
	    }
	} else {
	    $self->debug("Creating start param with value: $start");
	    $self->{'programmes'}{$prog_id}{'start'} = $start;
	}
	return $prog_id;
    } else {
	$self->debug("No programme for $start");
	$self->{'output'}{'error'}{'message'} = "We don't have any available footage for that person or start time.";
	$self->{'output'}{'error'}{'code'} = 21;
	return undef;
    }

}

sub get_programmes_from_database {
    my ($self, $type, @bind_variables) = @_;

    my $bind_length = 0;
    my $select_statement = "SELECT id, record_start, record_end, title, synopsis, rights, status, channel_id, broadcast_start, broadcast_end FROM programmes ";
    if ($type eq 'time-stamp') {

	# only needs 4 now - first two variables no longer doubled-up
	#$bind_length = 6;

	$bind_length = 4;

	# ignore record_start, not relevant for non-live programmes,
	# and not needed for commons since it is always live (so
	# record_start not needed to get the correct prog_id for a
	# given timestamp)

	#$select_statement .= "WHERE (record_start <= ? AND record_end > ?) OR (broadcast_start <= ? AND broadcast_end > ?) " .

	$select_statement .= "WHERE broadcast_start <= ? AND broadcast_end > ? " .
	    #"AND status = 'available' AND rights = 'internet' " .
	    "AND channel_id = ? AND location = ?";

	# doubling-up of first two variables no longer needed
	#@bind_variables = (@bind_variables[0,1], @bind_variables);

    } elsif ($type eq 'time-period') {

	$bind_length = 4;

	$select_statement .= "WHERE broadcast_start >= ? AND broadcast_start <= ? " .
	    #"AND status = 'available' AND rights = 'internet' " .
	    "AND channel_id = ? ";
	if (scalar @bind_variables == $bind_length) {
	    $select_statement .= "AND location = ?";
	} else {
	    $bind_length -= 1;
	}


    } elsif ($type eq 'prog') {

	$bind_length = 1;
	$select_statement .= "WHERE id = ?";

    } elsif ($type eq 'title-synopsis') {

	$bind_length = 3;
	$bind_variables[0] = "%$bind_variables[0]%";
	@bind_variables = ($bind_variables[0], @bind_variables);
	$select_statement .= "WHERE UPPER(title) LIKE UPPER(?) OR UPPER(synopsis) LIKE UPPER(?) AND channel_id = ?";

    }

    unless (scalar @bind_variables == $bind_length) {
	$self->error("Database lookup did not get enough params (needs $bind_length) - got: " . join(", ", @bind_variables),1);
	return undef;
    }

    $self->debug("select_statement: $select_statement");
    $self->debug("bind vars: " . join (", ",@bind_variables));

    my $st = dbh()->prepare($select_statement);
    $st->execute(@bind_variables);

    my $last_programme_id = undef;
    while (my @row = $st->fetchrow_array()) {

	# note the id, the start and end times
	
	$self->update_programmes_hash(@row);

	$last_programme_id = $row[0];

    }

    $self->debug("Got database results: " . Dumper $self->{'programmes'} );

    if (defined($last_programme_id)) {
	$self->debug("last prog id:$last_programme_id;");
	return $last_programme_id;
    } else {
	$self->debug("No programme found.");
	return undef;
    }

}

sub calculate_seconds_offsets {
    my ($self) = @_;

    unless (defined($self->{'programmes'})) {
	$self->debug("No programmes found to calculate offsets");
	return 1;
    }

    foreach my $id (keys %{$self->{'programmes'}}) {

	if (defined($self->{'programmes'}{$id}{'offset'})) {
	    $self->debug("skipping offset calculation for $id, already set elsewhere");
	    next;
	}

	$self->debug("Comparing $self->{'programmes'}{$id}{'record-start'} and $self->{'programmes'}{$id}{'start'}");

	if (defined($self->{'programmes'}{$id}{'start'})) {

	    unless (defined($self->{'programmes'}{$id}{'record-start'})) {
		warn ("ERROR: Programme $id does not have a record-start value (calculate_seconds_offset)");
		return undef;
	    }

	    my $offset = $self->calculate_seconds_diff($self->{'programmes'}{$id}{'record-start'},
						       $self->{'programmes'}{$id}{'start'});
	    
	    # to make sure that we don't start in the middle of the second
	    # sentence of a speech, start N seconds offset from the specified time
	    
	    my $additional_offset = mySociety::Config::get('BBC_OFFSET_SECS');
	    
	    # check whether $additional_offset is an integer!!
	    
	    unless ($additional_offset =~ /^\d+$/) {
		$additional_offset = 0;
	    }
	    
	    $offset -= $additional_offset;
	    if ($offset < 0) {
		$offset = 0;
	    }
	    
	    $self->{'programmes'}{$id}{'offset'} = $offset;
	    $self->debug("offset is $offset for $id");
	} else {
	    $self->error("Start parameter not defined, cannot calculate offset",8);
	    return undef;
	}

    }

    return 1;

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

    @d1 = $self->extract_datetime_array($d1);
    @d2 = $self->extract_datetime_array($d2);

    $self->debug("Datetime array was: " . Dumper @d1);
    $self->debug("Datetime array was: " . Dumper @d2);

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
    my ($self, $string) = @_;

    if ($string =~ /^(\d{4})-(\d{2})-(\d{2}).+(\d{2}):(\d{2}):(\d{2})/) {
	my @array = ('year' => $1,
		     'month' => $2,
		     'day' => $3,
		     'hour' => $4,
		     'minute' => $5,
		     'second' => $6);
	return @array;
    } else {
	$self->error("Datetime string did not match regexp: $string",10);
	return undef;
    }

}

1;
