#!/usr/bin/perl

# Original version downloaded from Amazon Web Services developer website
# etienne@ejhp.net - 2007-06-14
# License unknown - modifications have been placed in the public domain

# TODO - make this object oriented and remove all those horrible globals!

package Amazon::QueueServiceMethods;

# Functional interface
require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(createQueue listQueues setReceiveVisibilityTimeoutSeconds getReceiveVisibilityTimeoutSeconds sendMessage receiveMessage peekMessage deleteMessage deleteQueue checkStatus SUCCESS queue_url_xpath list_queues_url_xpath send_message_id_xpath receive_message_id_xpath receive_message_body_xpath create_queue_status_xpath send_message_status_xpath delete_message_status_xpath receive_message_status_xpath);
our @EXPORT_OK = qw(get_hmac_signature);
our $VERSION = 1.00;

# Global data
$SUCCESS = "Success";
$queue_url_xpath = "/CreateQueueResponse/QueueUrl";
$list_queues_url_xpath = "/ListQueuesResponse/QueueUrl";
$send_message_id_xpath = "/SendMessageResponse/MessageId";
$receive_message_id_xpath = "/ReceiveMessageResponse/Message/MessageId";
$receive_message_body_xpath = "/ReceiveMessageResponse/Message/MessageBody";
$create_queue_status_xpath = "/CreateQueueResponse/ResponseStatus/StatusCode";
$send_message_status_xpath = "/SendMessageResponse/ResponseStatus/StatusCode";
$delete_message_status_xpath = "/DeleteMessageResponse/ResponseStatus/StatusCode";
$receive_message_status_xpath = "/ReceiveMessageResponse/ResponseStatus/StatusCode";
$list_queues_status_xpath = "/ListQueuesResponse/ResponseStatus/StatusCode";

sub checkStatus {
    my ($response, $status_xpath) = @_;
    my $status = $response->findvalue($status_xpath);
    if (!($status eq $SUCCESS)) {
        print "Expected status: [$SUCCESS], got: [$status]\n";
        return 0;
    }
    else {
        return 1;
    }
}


use strict;

use Digest::SHA1  qw(sha1 sha1_hex sha1_base64);
use Amazon::QueryAccessXinoXPath;
use XML::XPath;  # for xml path style parsing

use Data::Dumper;

sub get_secrets {
    return BBCParl::EC2::load_secrets();
}


##
## CONSTRUCTOR
##
#sub new {
#  my ($class) = @_;
#
#  my $self = bless {
#                   }, $class;
#
#  return $self;
#}

################################################################################
###############                   Subroutines                    ###############
################################################################################

# these will break down into elementary method calls, and into compound
# test methods. The elementary calls will be obviously named the same as
# the methods themselves, and the compound calls will be prefixed with
# 'test_' and then a description of what's being tested.

# createQueue(string $service_url, string $rest_or_query, hash_ref $params)
# returns Queue URL
sub createQueue {
    my $service_url = shift;
    my $rest_or_query = shift;
    my $param_hash_ref = shift;

    if ((!$service_url) || (!$rest_or_query)) {
        return 0;
    }

    if ($rest_or_query =~ /QUERY/i) {
        my $query_client = QueryAccessXinoXPath->new();

        # build query string
        my $security_params = get_security_params($rest_or_query, 'CreateQueue', 'EXPIRES');

        my $param_string;
        for my $field_name (keys %{$param_hash_ref}) {
            $param_string .= "&" . $field_name . "=" . $param_hash_ref->{$field_name};
        }

        my $query_string = "/?Action=CreateQueue&Version=2006-04-01" . $param_string . $security_params;

        # make request. Results come back as an XPath object
        my $query_results = $query_client->make_query(
                                                      $service_url,
                                                      $query_string,
                                                      );
        unless ($query_results) {
            return 0;
        } else {
            return $query_results;
        }

    } elsif ($rest_or_query =~ /REST/i) {
        require Amazon::RestAccessXinoXPath;
        my $rest_client = Amazon::RestAccessXinoXPath->new();

        # get security headers ('POST' = CreateQueue)
        my $security_params = get_security_params($rest_or_query, 'POST', 'EXPIRES', $service_url, $param_hash_ref);

        # define query_string
        my ($query_string, $param_string, @param_string_array);
        for my $param (keys(%{$param_hash_ref})) {
            push(@param_string_array, $param . '=' . $param_hash_ref->{$param});
        }

        if (@param_string_array) {
            $query_string .= '/?';
            $param_string = join('&', @param_string_array);
            $query_string .= $param_string;
        }

        my $rest_results = $rest_client->make_query(
                                                    $service_url,
                                                    $query_string,
                                                    'POST',
                                                    $param_hash_ref,
                                                    $security_params
                                                    );

        unless ($rest_results) {
            return 0;
        } else {
            return $rest_results;
        }
    }
}



# listQueues(string $service_url, string $rest_or_query, string $queue_name_prefix)
# returns XML::XPath object ref
sub listQueues {
    my $service_url = shift;
    my $rest_or_query = shift;
    my $queue_name_prefix = shift;

    if ((!$service_url) || (!$rest_or_query)) {
        return 0;
    }

    if ($rest_or_query =~ /QUERY/i) {
        my $rest_client = QueryAccessXinoXPath->new();

        # build query string
        my $security_params = get_security_params($rest_or_query, 'ListQueues', 'EXPIRES');

        my $query_string = "/?Action=ListQueues&Version=2006-04-01" . $security_params;
        $query_string .= "&QueueNamePrefix=$queue_name_prefix" if $queue_name_prefix;

        # make request. Results come back as an XPath object
        my $rest_query_results = $rest_client->make_query(
                                                          $service_url,
                                                          $query_string,
                                                          );
        unless ($rest_query_results) {
            return 0;
        } else {
            return $rest_query_results;
        }

    } elsif ($rest_or_query =~ /REST/i) {
        require Amazon::RestAccessXinoXPath;
        my $rest_client = Amazon::RestAccessXinoXPath->new();
        my $param_hash_ref;
        $param_hash_ref->{'QueueNamePrefix'} = $queue_name_prefix if ($queue_name_prefix);

        # get security headers ('GET' = ListQueues)
        my $security_params = get_security_params($rest_or_query, 'GET', 'EXPIRES', $service_url, $param_hash_ref);

        # define query_string
        my ($query_string, $param_string, @param_string_array);
        for my $param (keys(%{$param_hash_ref})) {
            push(@param_string_array, $param . '=' . $param_hash_ref->{$param});
        }

        if (@param_string_array) {
            $query_string .= '/?';
            $param_string = join('&', @param_string_array);
            $query_string .= $param_string;
        } else {
            $service_url .= '/';
        }

        my $rest_results = $rest_client->make_query(
                                                    $service_url,
                                                    $query_string,
                                                    'GET',
                                                    $param_hash_ref,
                                                    $security_params
                                                    );

        unless ($rest_results) {
            return 0;
        } else {
            return $rest_results;
        }
    }
}

# setReceiveVisibilityTimeoutSeconds(string $service_url, string $rest_or_query, hash_ref $params)
# returns XPath'ed response
sub setReceiveVisibilityTimeoutSeconds {
    my $service_url = shift;
    my $rest_or_query = shift;
    my $param_hash_ref = shift;

    if ((!$service_url) || (!$rest_or_query)) {
        return 0;
    }

    if ($rest_or_query =~ /QUERY/i) {
        my $rest_client = QueryAccessXinoXPath->new();

        # build query string
        my $security_params = get_security_params($rest_or_query, 'SetVisibilityTimeout', 'EXPIRES');

        my $param_string;
        for my $field_name (keys %{$param_hash_ref}) {
            $param_string .= "&" . $field_name . "=" . $param_hash_ref->{$field_name};
        }

        my $query_string = "/?Action=SetVisibilityTimeout&Version=2006-04-01" . $param_string . $security_params;

        # make request. Results come back as an XPath object
        my $rest_query_results = $rest_client->make_query(
                                                          $service_url,
                                                          $query_string,
                                                          );
        unless ($rest_query_results) {
            return 0;
        } else {
            return $rest_query_results;
        }

    } elsif ($rest_or_query =~ /SOAP/i) {
    }
}


# getReceiveVisibilityTimeoutSeconds(string $service_url, string $rest_or_query, hash_ref $params)
# returns XPath'ed response
sub getReceiveVisibilityTimeoutSeconds {
    my $service_url = shift;
    my $rest_or_query = shift;
    my $param_hash_ref = shift;

    if ((!$service_url) || (!$rest_or_query)) {
        return 0;
    }

    if ($rest_or_query =~ /QUERY/i) {
        my $rest_client = QueryAccessXinoXPath->new();

        # build query string
        my $security_params = get_security_params($rest_or_query, 'GetVisibilityTimeout', 'EXPIRES');

        my $param_string;
        for my $field_name (keys %{$param_hash_ref}) {
            $param_string .= "&" . $field_name . "=" . $param_hash_ref->{$field_name};
        }

        my $query_string = "/?Action=GetVisibilityTimeout&Version=2006-04-01" . $param_string . $security_params;

        # make request. Results come back as an XPath object
        my $rest_query_results = $rest_client->make_query(
                                                          $service_url,
                                                          $query_string,
                                                          );
        unless ($rest_query_results) {
            return 0;
        } else {
            return $rest_query_results;
        }

    } elsif ($rest_or_query =~ /SOAP/i) {
    }
}


# sendMessage(string $service_url, string $rest_or_query, hash_ref $params)
sub sendMessage {
    my $service_url = shift;
    my $rest_or_query = shift;
    my $param_hash_ref = shift;

    if ((!$service_url) || (!$rest_or_query)) {
        return 0;
    }

    if ($rest_or_query =~ /QUERY/i) {
        my $rest_client = QueryAccessXinoXPath->new();

        # build query string
        my $security_params = get_security_params($rest_or_query, 'SendMessage', 'EXPIRES');

        my $param_string;
        for my $field_name (keys %{$param_hash_ref}) {
            my $message_body_count = 1;

            # MessageBodies is a compound field, need to break
            # it down into single params
            if ($field_name =~ /MessageBody/) {
                # if the contents of this field are in an array,
                # parse the array values into separate parameters
                if (ref($param_hash_ref->{$field_name}) =~ /ARRAY/) {
                    for my $message_body (@{$param_hash_ref->{$field_name}}) {
                        $param_string .= "&MessageBody." . $message_body_count . "=" . $message_body;
                        $message_body_count++;
                    }

                    # otherwise, submit a single MessageBody param
                } else {
                    $param_string .= "&MessageBody" . "=" . $param_hash_ref->{$field_name};
                }
            } else {
                # Balance of the fields can just come in as single params
                $param_string .= "&" . $field_name . "=" . $param_hash_ref->{$field_name};
            }
        }

        my $query_string = "/?Action=SendMessage&Version=2006-04-01" . $security_params . $param_string;

        # make request. Results come back as an XPath object
        my $rest_query_results = $rest_client->make_query(
                                                          $service_url,
                                                          $query_string,
                                                          );
        unless ($rest_query_results) {
            return 0;
        } else {
            return $rest_query_results;
        }

    } elsif ($rest_or_query =~ /REST/i) {
        require Amazon::RestAccessXinoXPath;
        my $rest_client = Amazon::RestAccessXinoXPath->new();

        # REST target for posts
        $service_url .= '/back/';

        # get security headers ('PUT' = SendMessage)
        my $security_params = get_security_params($rest_or_query, 'PUT', 'EXPIRES', $service_url, $param_hash_ref);

	# define request body that contains one or more messages
	my $body_string;
	for my $field_name (keys %{$param_hash_ref}) {
	    # MessageBodies is a compound field, need to break
	    # it down into single params
	    if ($field_name =~ /MessageBody/) {
		# if the contents of this field are in an array,
		# parse the array values into separate parameters
		if (ref($param_hash_ref->{$field_name}) =~ /ARRAY/) {
		    for my $message_body (@{$param_hash_ref->{$field_name}}) {
			$body_string .=  $message_body;
		    }
		# otherwise, submit a single MessageBody param
		} else {
		    $body_string .= $param_hash_ref->{$field_name};
		}
	    }
	}

        my $rest_results = $rest_client->make_query(
                                                    $service_url,
                                                    '',
                                                    'PUT',
                                                    $param_hash_ref,
                                                    $security_params,
						    $body_string
                                                    );

        unless ($rest_results) {
            return 0;
        } else {
            return $rest_results;
        }
    }
}


# receiveMessage(string $service_url, string $rest_or_query, hash_ref $params)
# returns Messages/Message array (each of which contains MessageId/MessageBody combo)
sub receiveMessage {
    my $service_url = shift;
    my $rest_or_query = shift;
    my $param_hash_ref = shift;

    if ((!$service_url) || (!$rest_or_query)) {
        return 0;
    }

    if ($rest_or_query =~ /QUERY/i) {
        my $rest_client = QueryAccessXinoXPath->new();

        # build query string
        my $security_params = get_security_params($rest_or_query, 'ReceiveMessage', 'EXPIRES');

        my $param_string;
        for my $field_name (keys %{$param_hash_ref}) {
            $param_string .= "&" . $field_name . "=" . $param_hash_ref->{$field_name};
        }


        my $query_string = "/?Action=ReceiveMessage&Version=2006-04-01" . $security_params . $param_string;

        # make request. Results come back as an XPath object
        my $rest_query_results = $rest_client->make_query(
                                                          $service_url,
                                                          $query_string,
                                                          );
        unless ($rest_query_results) {
            return 0;
        } else {
            return $rest_query_results;
        }

    } elsif ($rest_or_query =~ /REST/i) {
        require Amazon::RestAccessXinoXPath;
        my $rest_client = Amazon::RestAccessXinoXPath->new();

        # REST target for posts
        $service_url .= '/front/';

        # get security headers ('GET' = ReceiveMessage)
        my $security_params = get_security_params($rest_or_query, 'GET', 'EXPIRES', $service_url, $param_hash_ref);

        # define query_string
        my ($query_string, $param_string, @param_string_array);
        for my $param (keys(%{$param_hash_ref})) {
            push(@param_string_array, $param . '=' . $param_hash_ref->{$param});
        }

        if (@param_string_array) {
            $query_string .= '/?';
            $param_string = join('&', @param_string_array);
            $query_string .= $param_string;
        }

        my $rest_results = $rest_client->make_query(
                                                    $service_url,
                                                    $query_string,
                                                    'GET',
                                                    $param_hash_ref,
                                                    $security_params
                                                    );

        unless ($rest_results) {
            return 0;
        } else {
            return $rest_results;
        }
    }
}

# peekMessage(string $service_url, string $rest_or_query, hash_ref $params)
# returns Messages/Message array (each of which contains MessageId/MessageBody combo)
sub peekMessage {
    my $service_url = shift;
    my $rest_or_query = shift;
    my $param_hash_ref = shift;

    if ((!$service_url) || (!$rest_or_query)) {
        return 0;
    }

    if ($rest_or_query =~ /QUERY/i) {
        my $rest_client = QueryAccessXinoXPath->new();

        # build query string
        my $security_params = get_security_params($rest_or_query, 'PeekMessage', 'Expires');

        my $param_string;
        for my $field_name (keys %{$param_hash_ref}) {
            my $message_body_count = 1;

            # MessageIds is a compound field, need to break
            # it down into single params
            if ($field_name =~ /MessageId/) {
                # if the contents of this field are in an array,
                # parse the array values into separate parameters
                if (ref($param_hash_ref->{$field_name}) =~ /ARRAY/) {
                    for my $message_body (@{$param_hash_ref->$field_name}) {
                        $param_string .= "&MessageId." . $message_body_count . "=" . $message_body;
                        $message_body_count++;
                    }

                }
            }

            # Balance of the fields can just come in as single params
            $param_string .= "&" . $field_name . "=" . $param_hash_ref->{$field_name};
        }

        my $query_string = "/?Action=PeekMessage&Version=2006-04-01" . $security_params . $param_string;

        # make request. Results come back as an XPath object
        my $rest_query_results = $rest_client->make_query(
                                                          $service_url,
                                                          $query_string,
                                                          );
        unless ($rest_query_results) {
            return 0;
        } else {
            return $rest_query_results;
        }

    } elsif ($rest_or_query =~ /REST/i) {
        require Amazon::RestAccessXinoXPath;
        my $rest_client = Amazon::RestAccessXinoXPath->new();

        # REST target for posts
        $service_url .= '/' . $param_hash_ref->{'MessageId'} . '/';

        # get security headers ('GET' = PeekMessage)
        my $security_params = get_security_params($rest_or_query, 'GET', 'EXPIRES', $service_url, $param_hash_ref);

        # define query_string
        my ($query_string, $param_string, @param_string_array);
        for my $param (keys(%{$param_hash_ref})) {
            push(@param_string_array, $param . '=' . $param_hash_ref->{$param});
        }

        my $rest_results = $rest_client->make_query(
                                                    $service_url,
                                                    $query_string,
                                                    'GET',
                                                    $param_hash_ref,
                                                    $security_params
                                                    );

        unless ($rest_results) {
            return 0;
        } else {
            return $rest_results;
        }
    }
}

# deleteMessage(string $service_url, string $rest_or_query, hash_ref $params)
# returns success/failure
sub deleteMessage {
    my $service_url = shift;
    my $rest_or_query = shift;
    my $param_hash_ref = shift;

    if ((!$service_url) || (!$rest_or_query)) {
        return 0;
    }

    if ($rest_or_query =~ /QUERY/i) {
        my $rest_client = QueryAccessXinoXPath->new();

        # build query string
        my $security_params = get_security_params($rest_or_query, 'DeleteMessage', 'EXPIRES');

        my $param_string;
        for my $field_name (keys %{$param_hash_ref}) {
            my $message_body_count = 1;

            # MessageIds is a compound field, need to break
            # it down into single params
            if ($field_name =~ /MessageId/) {
                # if the contents of this field are in an array,
                # parse the array values into separate parameters
                if (ref($param_hash_ref->{$field_name}) =~ /ARRAY/) {
                    for my $message_body (@{$param_hash_ref->{$field_name}}) {
                        $param_string .= "&MessageId." . $message_body_count . "=" . $message_body;
                        $message_body_count++;
                    }

                    # otherwise, submit a single MessageBody param
                } else {
                    $param_string .= "&MessageId" . "=" . $param_hash_ref->{$field_name};
                }
            }

            # Balance of the fields can just come in as single params
            $param_string .= "&" . $field_name . "=" . $param_hash_ref->{$field_name};
        }

        my $query_string = "/?Action=DeleteMessage&Version=2006-04-01" . $security_params . $param_string;

        # make request. Results come back as an XPath object
        my $rest_query_results = $rest_client->make_query(
                                                          $service_url,
                                                          $query_string,
                                                          );
        unless ($rest_query_results) {
            return 0;
        } else {
            return $rest_query_results;
        }

    } elsif ($rest_or_query =~ /REST/i) {
        require Amazon::RestAccessXinoXPath;
        my $rest_client = Amazon::RestAccessXinoXPath->new();

        # REST target for posts
        $service_url .= '/' . $param_hash_ref->{'MessageId'} . '/';

        # get security headers ('GET' = PeekMessage)
        my $security_params = get_security_params($rest_or_query, 'DELETE', 'EXPIRES', $service_url, $param_hash_ref);

        # define query_string
        my ($query_string, $param_string, @param_string_array);
        for my $param (keys(%{$param_hash_ref})) {
            push(@param_string_array, $param . '=' . $param_hash_ref->{$param});
        }

        my $rest_results = $rest_client->make_query(
                                                    $service_url,
                                                    $query_string,
                                                    'DELETE',
                                                    $param_hash_ref,
                                                    $security_params
                                                    );

        unless ($rest_results) {
            return 0;
        } else {
            return $rest_results;
        }
    }
}

sub deleteQueue {
    my $service_url = shift;
    my $rest_or_query = shift;

    if ((!$service_url) || (!$rest_or_query)) {
        return 0;
    }

    if ($rest_or_query =~ /QUERY/i) {
        my $rest_client = QueryAccessXinoXPath->new();

        # build query string
        my $security_params = get_security_params($rest_or_query, 'DeleteQueue', 'EXPIRES');


        my $query_string = "/?Action=DeleteQueue&Version=2006-04-01" . $security_params;

        # make request. Results come back as an XPath object
        my $rest_query_results = $rest_client->make_query(
                                                          $service_url,
                                                          $query_string,
                                                          );
        unless ($rest_query_results) {
            return 0;
        } else {
            return $rest_query_results;
        }

    } elsif ($rest_or_query =~ /REST/i) {
        require Amazon::RestAccessXinoXPath;
        my $rest_client = Amazon::RestAccessXinoXPath->new();
        my $param_hash_ref;

        # get security headers ('DELETE' = DeleteQueue)
        my $security_params = get_security_params($rest_or_query, 'DELETE', 'EXPIRES', $service_url, $param_hash_ref);

        # define query_string
        my ($query_string, $param_string, @param_string_array);

        # need to add a slash
        $service_url .= '/';

        my $rest_results = $rest_client->make_query(
                                                    $service_url,
                                                    $query_string,
                                                    'DELETE',
                                                    $param_hash_ref,
                                                    $security_params
                                                    );

        unless ($rest_results) {
            return 0;
        } else {
            return $rest_results;
        }
    }
}


# get_security_params(string $rest_or_query, string $action, string $now_or_expires, string $service_url)
# returns REST or SOAP formatted params for signature, AKID, and Timestamp
sub get_security_params {
    my $rest_or_query = shift;
    my $action = shift;
    my $now_or_expires = shift;
    my $service_url = shift;
    my $param_hash_ref = shift;

    my $timestamp = get_timestamp($now_or_expires);

    my ($ACCESS_KEY_ID, $SECRET_ACCESS_KEY_ID) = get_secrets();

    my $signature_key = $action . $timestamp;
    my $signature = get_hmac_signature($signature_key, $SECRET_ACCESS_KEY_ID, $rest_or_query);

    my $security_params;
    if ($rest_or_query =~ /QUERY/i) {
        my $timestamp = get_timestamp($now_or_expires);

        my $signature_key = $action . $timestamp;
        my $signature = get_hmac_signature($signature_key, $SECRET_ACCESS_KEY_ID, $rest_or_query);
        $security_params .= "&AWSAccessKeyId=" . $ACCESS_KEY_ID;
        $security_params .= ("&Timestamp=" . $timestamp)  if ($now_or_expires =~ /NOW/i);
        $security_params .= ("&Expires=" . $timestamp)  if ($now_or_expires =~ /EXPIRES/i);
        $security_params .= "&Signature=" . $signature;
    }

    # REST signature
    elsif ($rest_or_query =~ /REST/i) {
        # timestamp needs to look like 'Thu, 17 Nov 2005 18:49:58 GMT'
        my $time_in_seconds = time;
        my $expires_time = $time_in_seconds;
        my $preformatted_timestamp = scalar(gmtime($expires_time));

        # timestamp parse
        # $1 = day of week
        # $2 = month
        # $3 = mday
        # $4 = time
        # $5 = year
	$preformatted_timestamp =~ /^(\w+)\s+(\w+)\s+(\d+)\s+(\d+\:\d+\:\d+)\s+(\d+)$/;
	my $timestamp = sprintf("%3s, %02d %3s %8s %4s GMT", $1, $3, $2, $5, $4);

        # store params in a hash, if they're passed in, convert to string for md5
        my $param_string;
        my $md5_signature;

        # start string to be hmac'ed with the action
        my $canonical_string = $action . "\n";

        # add a '\n' to cover the absence of the md5
        $canonical_string .= "\n";

        # add the content type
        my $content_type = 'text/plain';
        $canonical_string .= $content_type . "\n";

        # add the date
        $canonical_string .= $timestamp. "\n";

        # truncate and add the service resource
        chomp $service_url;
        if ($service_url =~ /^http:\/\/.*?(\/.*?)\/?\??$/) {
            $canonical_string .= $1;
        }

        $canonical_string .= '/';


        # sign the canonical string
        # print "Signing string: $canonical_string\n";
        my $signed_canonical_string = get_hmac_signature($canonical_string, $SECRET_ACCESS_KEY_ID, $rest_or_query);

        $security_params->{'md5_signature'} = $md5_signature;
        $security_params->{'signed_canonical_string'} = $signed_canonical_string;
        $security_params->{'date'} = $timestamp;
        $security_params->{'content_type'} = $content_type;
        $security_params->{'access_key_id'} = $ACCESS_KEY_ID;
        $security_params->{'secret_access_key_id'} = $SECRET_ACCESS_KEY_ID;

        # use in 'Authorization' header
        $security_params->{'auth_string'} = "AWS $ACCESS_KEY_ID" . ':' . $signed_canonical_string;
    }

    return $security_params;
}


# get_timestamp()
# returns string of timestamp
sub get_timestamp {
    my $now_or_expires = shift;

    my $time_string;
    if ($now_or_expires =~ /NOW/i) {
        my @time = (gmtime(time));
        my $time_string = sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ",
                                  $time[5] + 1900,
                                  $time[4] + 1,
                                  $time[3],
                                  $time[2],
                                  $time[1],
                                  $time[0]
                                  );

        return $time_string;

    } elsif ($now_or_expires =~ /EXPIRES/i) {
        my @time = (gmtime(time + 900));
        my $time_string = sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ",
                                  $time[5] + 1900,
                                  $time[4] + 1,
                                  $time[3],
                                  $time[2],
                                  $time[1],
                                  $time[0]
                                  );

        return $time_string;
    }
}

# get_hmac_signature(string $data, string $key)
# returns hmac sig for key
sub get_hmac_signature {
    use Digest::HMAC_SHA1 qw(hmac_sha1);
    use MIME::Base64 qw(encode_base64);

    my $data = shift;
    my $key = shift;
    my $rest_or_query = shift;

    my $hmac = hmac_sha1($data, $key);
    chomp $hmac;

    my $encoded_hmac = encode_base64($hmac);
    chomp $encoded_hmac;

    # it turns out that the Query sig needs to be encoded, but the Rest fails if it is
    if ($rest_or_query =~ /QUERY/i) {
        my $url_encoded_hmac = url_encode($encoded_hmac);
        chomp $url_encoded_hmac;

        return $url_encoded_hmac;
    } else {
        return $encoded_hmac;
    }
}

sub get_md5_signature {
    use Digest::MD5 qw(md5_base64);

    my $data = shift;
    return md5_base64($data);
}

sub url_encode {
    my $url = shift;
    $url =~ s/([\W])/"%" . uc(sprintf("%2.2x",ord($1)))/eg;
    return $url;
}


1;
