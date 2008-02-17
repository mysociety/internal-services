package BBCParl::S3;

use strict;

use POSIX qw (strftime);
use BBCParl::EC2;

# TODO - move the video-fetching parts into FetchMedia.pm

sub new {
    my ($class, $test) = @_;
    my $self = {};
    bless $self, $class;

    $self->{'path'}{'home-dir'} = (getpwuid($<))[7];
    $self->{'path'}{'config-dir'} = $self->{'path'}{'home-dir'} . '/conf';
    $self->{'path'}{'downloads-dir'} = $self->{'path'}{'home-dir'} . '/downloads';

    $self->{'path'}{'aws'} = $self->{'path'}{'home-dir'} . '/bin/aws/aws';

    # this is only needed if we're calling S3 from within this
    # script, but atm we're using an external program for S3 (aws)

##    ($self->{'aws'}{'access-id'}, $self->{'aws'}{'secret-key'}) = BBCParl::EC2::load_secrets();

    return $self;

}

sub put {
    my ($self, $local_filename, $remote_filename, $acl) = @_;

#    warn "DEBUG: trying to upload files to S3 ($local_filename, $remote_filename)";

    my @uploaded_files = ();

    my $uploader_program = $self->{'path'}{'aws'};

    my $acl_header = '';

    if (lc($acl) eq 'public') {
	warn "DEBUG: Adding public-read ACL header";
	$acl_header = 'x-amz-acl:public-read';
    }

    # upload each file to S3 and add to @uploaded_files

    # fix aws to accept additional params for PUT (headers) and use
    # this to make a file world-readable TODO - simply include the
    # HTTP header "x-amz-acl: public-read"

    my @args = ( 'put', $remote_filename, $local_filename, $acl_header);
    my $upload_ret_value = system($uploader_program,@args);

    if ($upload_ret_value == 0) {
	return $remote_filename;
    } else {
	warn "ERROR: Failed to upload $local_filename; $uploader_program return value was $upload_ret_value";
	return undef;
    }
    
}

sub get {
    my ($self, $bucket, $dir, $filename) = @_;

    my $new_dir = '';
    unless (-e $dir) {
	my @dirs = split ("/", $dir);
	foreach my $sub_dir (@dirs) {
	    $new_dir = "$new_dir/$sub_dir";
	    unless (-e $new_dir) {
		unless (mkdir $new_dir) {
		    warn "ERROR: Failed to create $new_dir; error was $!";
		    last;
		}
	    }
	}
    }

    my $program = $self->{'path'}{'aws'};
    my $dir_file = "$dir/$filename";

    if (-e $dir_file) {
	warn "DEBUG: $filename has already been downloaded ($dir_file); skipping mirror step for this file";
    } else {

    warn "DEBUG: downloading $bucket/$filename to $dir_file";

	my @args = ( 'get',
		     "$bucket/$filename",
		     $dir_file);
#		     '2>&1 >/dev/null');
	warn "DEBUG: Getting file with " . join (' ', $program, @args);
	my $retry = 0;
	while ($retry < 2) {
	    if (system($program, @args) != 0) {
		warn "ERROR: Could not download $filename to $dir_file (probably 404 Not Found)";
	    }
	    unless (-e $dir_file) {
		warn "ERROR: Did not download $filename to $dir_file (file not found locally after download)";
		return undef;
	    }
	    if (`ls -s $dir_file` =~ /^(\d+)\s+/) {
		# check that it's actually downloaded okay
		if ($1 == 0) {
		    $retry += 1;
		    next;
		} else {
		    last;
		}
	    }
	}
    }

    return $dir_file;

}

1;
