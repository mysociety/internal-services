package BBCParl::SQS;

use strict;

use Amazon::QueueServiceMethods;

sub new {
    my ($class) = @_;

    my $self = {};
    bless $self, $class;

    $self->{'constants'}{'amazon-sqs-url'} = 'http://queue.amazonaws.com';

    return $self;

}

sub send {
    my ($self, $queue_name, $message) = @_;

    my $rest_or_query = 'REST';
    my $url = $self->{'constants'}{'amazon-sqs-url'};
	
    my $param_hash_ref = {'QueueName' => $queue_name};

    # Creating a queue named $queue_name; it it already exists, it's
    # fine too.

    my $create_queue_response = createQueue($url, $rest_or_query, $param_hash_ref);
    my $create_queue_response_status = $create_queue_response->findvalue($Amazon::QueueServiceMethods::create_queue_status_xpath);

    if (!Amazon::QueueServiceMethods::checkStatus($create_queue_response,
						  $Amazon::QueueServiceMethods::create_queue_status_xpath)) {
	warn "ERROR: Could not create queue $queue_name";
	return undef;
    }
    
    my $queue_url = $create_queue_response->findvalue($Amazon::QueueServiceMethods::queue_url_xpath);

    my %message_param_hash = ('MessageBody' => $message);
    my $send_message_response = sendMessage($queue_url, $rest_or_query, \%message_param_hash);
    
    if (!Amazon::QueueServiceMethods::checkStatus($send_message_response,
						  $Amazon::QueueServiceMethods::send_message_status_xpath)) {
	warn "ERROR: Could not send message to queue $queue_url";
	return undef;
    }
    
    return $send_message_response->findvalue($Amazon::QueueServiceMethods::send_message_id_xpath);

}

sub receive {
    my ($self, $queue_name) = @_;

    my $rest_or_query = 'REST';
    my $url = $self->{'constants'}{'amazon-sqs-url'};
	
    my $param_hash_ref = {'QueueName' => $queue_name};

    my $list_queues_response = listQueues($url, $rest_or_query, $queue_name);

    if (!Amazon::QueueServiceMethods::checkStatus($list_queues_response,
						  $Amazon::QueueServiceMethods::list_queues_status_xpath)) {
	warn "ERROR: Could not run listQueues on queue $queue_name";
	return undef;
    }

    my $queue_url_nodeset = $list_queues_response->find($Amazon::QueueServiceMethods::list_queues_url_xpath);
    if (!$queue_url_nodeset->isa('XML::XPath::NodeSet')) {
	warn "ERROR: Error when calling listQueues";
	return undef;
    }

    if (!$queue_url_nodeset->size()) {
	#warn "DEBUG: No message found";
	return undef;
    }

    my $queue_url = $queue_url_nodeset->get_node(1)->string_value();
    foreach my $node ($queue_url_nodeset->get_nodelist) {   
	my $current_queue_url = $node->string_value();
	if ($queue_url eq $current_queue_url) {
	    $queue_url = $current_queue_url;
	    last;
	}
    }
    
    if (!$queue_url) {
	warn "ERROR: Didn't find any matching queue name";
	return undef;
    }

    my $receive_message_response = Amazon::QueueServiceMethods::receiveMessage($queue_url, $rest_or_query);
    if (!Amazon::QueueServiceMethods::checkStatus($receive_message_response, $Amazon::QueueServiceMethods::receive_message_status_xpath)) {
        warn "ERROR: Error calling receiveMessage";
	return undef;
    }
    
    # Retrieving the message id and message body from the response
    my $message_id = $receive_message_response->findvalue($Amazon::QueueServiceMethods::receive_message_id_xpath);
    my $message_body = $receive_message_response->findvalue($Amazon::QueueServiceMethods::receive_message_body_xpath);

    if ($message_id) {

	return ($message_body->value(), $queue_url, $message_id->value());

    } else {

	return undef;

    }

}

sub delete {
    my ($self, $queue_url, $message_id) = @_;

#    warn ($queue_url, $message_id);

    unless ($message_id && $queue_url) {
	warn "ERROR: Not enough parameters for BBCParl::SQS::delete";
	return undef;
    }

    my $rest_or_query = 'REST';

    # delete the message from the queue
    my %delete_param_hash = ('MessageId' => $message_id);
    my $delete_message_response = deleteMessage($queue_url, $rest_or_query, \%delete_param_hash);
    if (!checkStatus($delete_message_response, $Amazon::QueueServiceMethods::delete_message_status_xpath)) {
	warn "ERROR Could not delete message id " . $message_id . " from queue " . $queue_url;
	return undef;
    }

}


1;
