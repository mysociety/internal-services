#!/usr/bin/perl
#
# Queue.pm:
# Implementation of queuing service.
#
# Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: Queue.pm,v 1.1 2005-02-16 23:43:58 chris Exp $
#

package Queue::Error;

use Error;

@Queue::Error::ISA = qw(Error::Simple);

package Queue;

use strict;

use IO::String;
use RABX;
use Regexp::Common;

use mySociety::Config;
use mySociety::DBHandle qw(dbh);

mySociety::DBHandle::configure(
        Name => mySociety::Config::get('QUEUE_DB_NAME'),
        User => mySociety::Config::get('QUEUE_DB_USER'),
        Password => mySociety::Config::get('QUEUE_DB_PASS'),
        Host => mySociety::Config::get('QUEUE_DB_HOST'),
        Port => mySociety::Config::get('QUEUE_DB_PORT')
    );

# serialise REFERENCE
# Return a serialised version of REFERENCE.
sub serialise ($) {
    my ($ref) = @_;
    my $i = new IO::String();
    RABX::wire_wr($ref, $i);
    return ${$i->string_ref()};
}

# unserialise DATA
# Unserialise DATA (returned by serialise) and return it.
sub unserialise ($) {
    my $i = new IO::String($_[0]);
    return RABX::wire_rd($i);
}

# frame_set_state ID STATE
# Record the STATE in the given FRAME.
sub frame_set_state ($$) {
    my ($frame, $state) = @_;
    throw Queue::Error("STATE must be reference-to-hash") unless (ref($state) eq 'HASH');
    my $s = dbh()->prepare('update frame set state = ? where id = ?');
    $s->bind_param(1, serialise($state), { pg_type => DBD::Pg::PG_BYTEA });
    $s->bind_param(2, $frame);
    $s->execute();
}

# frame_get_state FRAME
# Return the state of the given FRAME.
sub frame_get_state ($) {
    my ($frame) = @_;
    my $x = unserialise(scalar(dbh()->selectrow_array('select state from frame where id = ?', {}, $frame)));
    throw Queue::Error("State for frame $frame is not a reference-to-hash")
        if (ref($x) ne 'HASH');
    return $x;
}

# frame_create TASK [STATE]
# Create a new frame for the given TASK, optionally initialising it with the
# given STATE. Return the ID of the new frame.
sub frame_create ($;$) {
    my ($task, $state) = @_;
    $state ||= { };
    $state->{__id} = $task;
    ($state->{__scope}, $state->{__tag}) = dbh()->selectrow_array('select scope, tag from task where id = ?', {}, $task);
    my $frame = dbh()->selectrow_array(q#select nextval('frame_id_idx')#);
    dbh()->do(q#insert into frame (id, task_id, state) values (?, ?, '')#, {}, $frame, $task);
    frame_set_state($frame, $state);
}

# task_set_event_handlers TASK EVENTS
# Set up notifiable EVENTS for a TASK, replacing any already-defined events.
# EVENTS is a reference to a list in which each element describes an event, and
# the action to be taken when that event occurs. Each element is a reference to
# a hash containing keys,
#
#   type
#       "timed" or "labelled", indicating whether this event occurs on/after a
#       specified time, or when a labelled event occurs;
#
#   deadline
#       for a timed event, the earliest time at which it may occur, expressed
#       as seconds since the epoch;
#
#   label
#       for a labelled event, the label;
#
#   url
#       RABX call URL for the action to take when the event occurs;
#
#   function
#       name of function to call on event;
#
#   arguments
#       optional list of arguments to be passed to function.
#
# You can leave url unset in EVENTS if at least one of the events gives a value
# for that element, and all such values are the same.
sub task_set_event_handlers ($$) {
    my ($task, $handlers) = @_;
    throw Queue::Error("TASK must be defined")
        unless (defined($task));
    throw Queue::Error("task '$task' does not exist")
        unless (defined(scalar(dbh()->selectrow_array('select id from task where id = ? for update of event_handler', {}, $task))));
    throw Queue::Error("EVENTS must be a reference to a list")
        unless (ref($handlers) eq 'ARRAY');
    throw Queue::Error("each element in EVENTS must be a reference to a hash")
        if (grep { ref($_) ne 'HASH' } @$handlers);

    my %uu = grep { exists($_->{url}) ? ($_->{url} => 1) : () } @$handlers;
    my $url;
    ($url) = keys(%uu) if (1 == keys(%uu));

    dbh()->do('delete from event_handler where task_id = ?', {}, $task);

    my $s = dbh()->prepare('
                insert into event_handler
                    (task_id, label, deadline, url, functionname, arguments)
                    values (?, ?, ?, ?, ?, ?)');
    $s->bind_param(1, $task);

    foreach my $h (@$handlers) {
        throw Queue::Error("handler must contain element 'type' being 'timed' or 'labelled'")
            unless (exists($h->{type}) && $h->{type} =~ m#^(labelled|timed)$#);
        throw Queue::Error("no label for labelled-event handler")
            if ($h->{type} eq 'labelled' and !exists($h->{label}));
        throw Queue::Error("no time for timed-event handler")
            if ($h->{type} eq 'timed' and !exists($h->{time}));
        throw Queue::Error("not a valid time for timed event")
            if ($h->{type} eq 'timed' and $h->{time} =~ /[^\d]/);
        throw Queue::Error("both time and label given for $h->{type} event")
            if (exists($h->{label}) and exists($h->{time}));
        throw Queue::Error("function must be supplied")
            unless (exists($h->{function}));

        $h->{url} ||= $url;
        throw Queue::Error("no URL in event handler and no unambiguous guess available")
            unless (defined($url));
        throw Queue::Error("'$h->{url}' is not a valid URL")
            unless ($h->{url} =~ m#^$RE{URI}{HTTP}{-scheme => 'https?'}$#);

        my $args = undef;
        if (exists($h->{arguments})) {
            throw Queue::Error("if present, arguments to function must be a list")
                unless (ref($h->{arguments}) eq 'ARRAY');
            $args = serialise($h->{arguments});
        }

        my $i = 2;
        foreach (qw(label deadline url function)) {
            $s->bind_param($i++, $h->{$_});
        }

        $s->bind_param($i, $args, { pg_type => DBD::Pg::PG_BYTEA })
            if (defined($args));

        $s->execute();
    }
}

=item task_create SCOPE TAG EVENTS [STATE]

Create a new task. SCOPE is the creating subsystem; TAG is a unique opaque name
which can be used by that subsystem to identify the task; EVENTS is a hash
describing which events take effect on the task, and STATE is an optional hash
containing the task's initial state.

=cut
sub task_create ($$$;$) {
    my ($scope, $tag, $events, $state) = @_;

    throw Queue::Error("SCOPE must be defined and non-empty")
        unless (defined($scope) && $scope ne '');
    throw Queue::Error("TAG must be defined and non-empty")
        unless (defined($tag) && $tag ne '');
    throw Queue::Error("If specified, STATE must be a reference to a hash")
        unless (!defined($state) || ref($state) eq 'HASH');
    
    $state ||= { };
    my $task = dbh()->selectrow_array(q#select nextval('task_id_idx')#);

    dbh()->do('insert into task (id, scope, tag) values (?, ?, ?)', {}, $task, $scope, $tag);
    task_set_events($task, $events);
    task_create_frame($task, $state);

    dbh()->commit();
}

=item event_notify SCOPE TAG LABEL [ARGUMENTS]

Issue notification that a labelled event has occured. SCOPE, TAG and LABEL
identify the event; optional ARGUMENTS may be passed to the event handler.

=cut
sub event_notify ($$$;$) {
    my ($scope, $tag, $label, $args) = @_;
    throw Queue::Error("SCOPE must be defined")
        unless (defined($scope));
    throw Queue::Error("TAG must be defined")
        unless (defined($tag));
    throw Queue::Error("LABEL must be defined")
        unless (defined($label));

    my $task = dbh()->selectrow_array('select id from task where scope = ? and tag = ?', {}, $scope, $tag);
    throw Queue::Error("No task found for scope '$scope' and tag '$tag'")
        unless (defined($task));

    # Test that there is actually an event handler defined for this event.
    my $id = dbh()->selectrow_array('select id from event_handler where task_id = ? and label = ?', {}, $task, $label);
    throw Queue::Error("No event-handler for scope '$scope', tag '$tag' with label '$label' ")
        unless (defined($id));

    my $s = dbh()->prepare('insert into event (task_id, label, arguments) values (?, ?, ?)');
    $s->bind_param(1, $task);
    $s->bind_param(2, $label);
    if (defined($args)) {
        throw Queue::Error("if defined, ARGUMENTS must be a reference to a list")
            unless (ref($args) eq 'ARRAY');
        $args = serialise($args);
    }
    $s->bind_param(3, $args, { pg_type => DBD::Pg::PG_BYTEA });

    $s->execute();
}

# process_function_result TASK RESULT
# 
sub process_function_result ($$) {
    my ($task, $res) = @_;
    throw Queue::Error("RESULT must be a list with two or more elements")
        unless (ref($res) eq 'ARRAY' and @$res > 1);
    my $what = shift @$res;
    throw Queue::Error("first element of result list must be CALL, RETURN or WAIT")
        unless ($what =~ m#^(CALL|RETURN|WAIT)$#);
    if ($what eq 'CALL') {
        throw Queue::Error("CALL must be followed by function to call, and function to handle return values")
            unless (@$res == 2);
    } elsif ($what eq 'RETURN') {
        throw Queue::Error("RETURN must be followed by return value")
            unless (@$res == 1);
    } else {
        throw Queue::Error("WAIT must be followed by event handler map")
            unless (@$res == 1);
    }
}

# handle_event HANDLER
# Perform the action associated with the given HANDLER (ID in the event_handler
# table). We attempt to execute the given function with the proper parameters,
# and process any return value or error raised. The return value of the
# function tells us what to do next. This should be called only with the task
# locked.
sub handle_event ($) {
    my ($id) = @_;
    my @funcargs = ( );
    our $rabx;
    if (!$rabx) {
        $rabx = new RABX::Client('http://x.invalid/');
        $rabx->usepost(1);
    }

    my $h = dbh()->selectrow_hashref('select * from event_handler where id = ?', {}, $id);
    throw Queue::Error("no event handler '$id'");
        if (!exists($h->{id}));

    push(@funcargs, @{unserialise($h->{arguments})})
        if (defined($h->{arguments}));
    
    # If this is a labelled event, we need to pick up any extra arguments.
    if (defined($ev->{label})) {
        my $ev = dbh()->selectrow_hashref('select * from event where task_id = ? and label = ?', {}, $h->{task_id}, $h->{label});
        throw Queue::Error("no event '$ev->{label}' pending on task '$ev->{task_id}'")
            if (!exists($ev->{task_id}));
        push(@funcargs, @{unserialise($ev->{arguments})})
            if (defined($ev->{arguments}));
    }

    $rabx->url($h->{url});
    try {
        my $result = $rabx->call($ev->{functionname}, @funcargs);
        process_function_result($h->{task_id}, $result);
    } catch RABX::Error with {
        my $E = shift;
        # XXX for the moment, let's treat all errors as temporary....
        warn "$E";
    };
}

my %rabx_client;

sub do_call ($$$) {
    my ($task, $url, $function, $params) = @_;
    if (!exists($rabx_client{$url})) {
        $rabx_client{$url} = new RABX::Client($url);
        $rabx_client{$url}->usepost(1);
    }
   
    
    # The function is passed the current task state and any parameters.
    $rabx_client{$url}->call($function, @$params);
}


1;
