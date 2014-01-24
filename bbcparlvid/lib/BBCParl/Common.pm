package BBCParl::Common;

use strict;

# Horrible boilerplate to set up appropriate library paths.
use FindBin;
use lib "$FindBin::Bin/../lib";

use mySociety::Config;

sub load_secrets {

    mySociety::Config::set_file("$FindBin::Bin/../conf/general");

      my ($access_id, $secret_key);

      $access_id = mySociety::Config::get('AMAZON_ACCESS_ID');
      $secret_key = mySociety::Config::get('AMAZON_SECRET_KEY');
      
      return ($access_id, $secret_key);

  }

sub extract_start_end {
    my ($filename) = @_;
    if ($filename =~ /.+?(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2}Z)(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2}Z)/) {
        return ("$1 $2", "$3 $4");
    } else {
        return undef;
    }
}

sub extract_datetime_array {
    my ($date_time) = @_;
    if ($date_time =~ /(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})/) {
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

1;
