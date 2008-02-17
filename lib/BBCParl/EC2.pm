package BBCParl::EC2;

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

sub old_load_secrets {

    my $secrets_filename = '/home/bbcparlvid/conf/.awssecret';

    unless (-e $secrets_filename) {
	warn "FATAL: Cannot find file: $secrets_filename";
	die;
    }

    unless (open(SECRETS, $secrets_filename)) {
	# TODO - use a proper logging system
	warn "FATAL: Cannot open file: $secrets_filename";
	die;
    }

    my ($access_id, $secret_key);

    while (<SECRETS>) {
	chomp;
	unless (defined($access_id)) {
	    $access_id = $_;
	    next;
	}
	unless (defined($secret_key)) {
	    $secret_key = $_;
	    last;
	}
    }

    close SECRETS;

}

1;
