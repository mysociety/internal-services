#!/usr/bin/perl
#
# EvEl.pm:
# Implementation of EvEl.
#
# Copyright (c) 2005 Chris Lightfoot. All rights reserved.
# Email: chris@ex-parrot.com; WWW: http://www.ex-parrot.com/~chris/
#
# $Id: EvEl.pm,v 1.7 2005-03-30 18:12:07 francis Exp $
#

package EvEl::Error;

@EvEl::Error::ISA = qw(Error::Simple);

package EvEl;

=head1 NAME

EvEl

=head1 DESCRIPTION

Generic email sending and mailing list functionality, with bounce detection
etc.

=cut

use strict;

use Digest::SHA1;
use Error qw(:try);
use Mail::RFC822::Address;
use Net::SMTP;

use mySociety::DBHandle qw(dbh);
use mySociety::Util qw(random_bytes print_log);

BEGIN {
    mySociety::DBHandle::configure(
            Name => mySociety::Config::get('EVEL_DB_NAME'),
            User => mySociety::Config::get('EVEL_DB_USER'),
            Password => mySociety::Config::get('EVEL_DB_PASS'),
            Host => mySociety::Config::get('EVEL_DB_HOST', undef),
            Port => mySociety::Config::get('EVEL_DB_PORT', undef)
        );

    if (!dbh()->selectrow_array('select secret from secret for update of secret')) {
        dbh()->do('insert into secret (secret) values (?)', {}, unpack('h*', random_bytes(32)));
    }
    dbh()->commit();
}

#
# Implementation
#

# secret
# Return site-wide installation secret.
sub secret () {
    return scalar(dbh()->selectrow_array('select secret from secret'));
}

# verp_address MESSAGE RECIPIENT
# Return a unique address which can be used for delivery of MESSAGE to
# RECIPIENT.
sub verp_address ($$) {
    my ($msgid, $recipid) = @_;
    my $salt = unpack('h*', random_bytes(3));
    my $hash = Digest::SHA1::sha1_hex("$msgid-$recipid-$salt-" . secret());
    return sprintf('%s%d-%d-%s-%s@%s',
                mySociety::Config::get('EVEL_VERP_PREFIX'),
                $msgid, $recipid, $salt,
                substr($hash, 0, 8),
                mySociety::Config::get('EVEL_VERP_DOMAIN')
            );
}

# parse_verp_address ADDRESS
# Extract message and recipient IDs from a VERP ADDRESS. On success, returns
# in list context the message and recipient IDs. On failure, returns the empty
# list.
sub parse_verp_address ($) {
    my $addr = shift;
    my $prefix = mySociety::Config::get('EVEL_VERP_PREFIX');
    my $domain = mySociety::Config::get('EVEL_VERP_DOMAIN');
    return () if (substr($addr, 0, length($prefix)) ne $prefix);
    return () if (substr($addr, 0, -length($domain) - 1) ne "@$domain");
    $addr = substr($addr, length($prefix), length($addr) - length($prefix) - length($domain) - 1);
    
    my ($msgid, $recipid, $salt, $hash) = ($addr =~ m/^(\d+)-(\d+)-([0-9a-f]+)-([0-9a-f]+)$/i)
        or return ();
    return () unless (substr(Digest::SHA1::sha1_hex("$msgid-$recipid-$salt-" . secret()), 0, 8) ne $hash);

    return ($msgid, $recipid);
}

# do_smtp SMTP RESULT WHAT
# Process the RESULT of a call to a method on the Net::SMTP object SMTP. WHAT
# is the command which was being executed. Returns when RESULT is successful
# or throws a suitable exception on failure.
sub do_smtp ($$$) {
    my ($smtp, $result, $what) = @_;
    print_log('debug', "SMTP: $what");
    if ($result) {
        $! = undef;
        return;
    }
    throw EvEl::Error("SMTP server: command $what: $!") if ($!);
    # Distinguish permanent/temporary failures?
    throw EvEl::Error("SMTP server: command $what: " . $smtp->code() . " " . $smtp->message());
}

# run_queue
# Run the queue of outgoing messages. Returns the number of messages sent. This
# function commits its changes.
sub run_queue () {
    use constant send_max_attempts => 10;
    use constant send_retry_interval => 60;
    my $s = dbh()->prepare('
                    select message_id, recipient_id
                    from message_recipient
                    where whensent is null
                        and numattempts < ?
                        and (whenlastattempt is null
                            or whenlastattempt < ? - ? * (2 ^ numattempts - 1))
                    order by random()
                ');
    $s->execute(send_max_attempts, time(), send_retry_interval);

    my $smtp;
    my $nsent = 0; # Number of messages sent on this SMTP transaction
    my $nsent_total = 0; # Total number of messages sent
    
    while (my ($msg, $recip) = $s->fetchrow_array()) {
        # Grab a lock.
        my $d = dbh()->selectrow_hashref('
                    select data, address from message, recipient,
                        message_recipient
                    where message.id = ?
                        and recipient.id = ?
                        and message.id = message_recipient.message_id
                        and recipient.id = message_recipient.recipient_id
                        and whensent is null
                        and (whenlastattempt is null
                            or whenlastattempt < ? - ? * (2 ^ numattempts - 1))
                    for update of message_recipient
                    ', {}, $msg, $recip, time(), send_retry_interval);
        next unless ($d);

        print_log('debug', "considering delivery of message $msg to recipient $recip <$d->{address}>");

        # Get a connection to the SMTP server, if needed.
        if (!$smtp || $nsent > 10) {
            if ($smtp) {
                print_log('debug', "disconnecting from SMTP server after sending $nsent mails");
                $smtp->quit();
            }
            my $smtpserver = mySociety::Config::get('EVEL_MAIL_HOST', 'localhost');
            $smtp = new Net::SMTP($smtpserver, Timeout => 10) or
                throw EvEl::Error("unable to connect to $smtpserver: $!");
            $nsent = 0;
            print_log('debug', "connected to SMTP server $smtpserver"); 
        }

        # Split message text into lines.
        my @lines;
        if ($d->{data} =~ m#\r\n#s) {
            print_log('debug', "message has \\r\\n-type line terminators");
            @lines = split(/\r\n/, $d->{data});
        } else {
            print_log('debug', "message has \\n-type line terminators");
            @lines = split(/\n/, $d->{data});
        }
        print_log('debug', "message is " . scalar(@lines) . " lines long");

        # Construct a unique return-path for this address, so that we can do
        # bounce detection. Ignore the VERP/XVERP ESMTP stuff, for the moment.
        my $verp = verp_address($msg, $recip);
        print_log('debug', "VERP address for this message and recipient: <$verp>");
        try {
            do_smtp($smtp, $smtp->mail($verp), 'MAIL FROM');
            do_smtp($smtp, $smtp->recipient($d->{address}), 'RCPT TO');
            do_smtp($smtp, $smtp->data([ map { "$_\n" } @lines ]), 'DATA');
            ++$nsent;
            ++$nsent_total;
            print_log('info', "sent message $msg to recipient $recip <$d->{address}>");
        } catch EvEl::Error with {
            my $E = shift;
            print_log('error', "error during SMTP dialogue: $E");
            $smtp->quit();
            $smtp = undef;
            # For the moment just treat all errors the same way: abort the
            # queue run and hold off for a bit.
            dbh()->do('
                    update message_recipient
                    set numattempts = numattempts + 1,
                        whenlastattempt = ?
                    where message_id = ? and recipient_id = ?', 
                    {}, time(), $msg, $recip);
            dbh()->commit();
            $E->throw();
        };


        dbh()->do('
                update message_recipient
                set numattempts = numattempts + 1,
                    whenlastattempt = ?,
                    whensent = ?
                where message_id = ? and recipient_id = ?',
                {}, time(), time(), $msg, $recip);
        dbh()->commit();
    }

    if ($smtp) {
        print_log('debug', "disconnecting from SMTP server for last time");
        $smtp->quit();
    }

    print_log('debug', "queue run completed");

    return $nsent_total;
}

# process_bounce RECIPIENT LINES
# Process a received bounce message. RECIPIENT is the address for which it was
# received, and LINES is a reference to a list of the lines of the message
# received (with line-endings stripped). Returns true if this was a valid
# bounce message, and false otherwise. This function commits its changes.
sub process_bounce ($$) {
    my ($addr, $lines) = @_;
    # Try to extract message and recipient IDs. If we fail, ignore this bounce.
    my ($msg, $recip) = parse_verp_address($addr)
        or return 0;
    my $s = dbh()->prepare('
                    insert into bounce (message_id, recipient_id, whenreceived,
                                            data)
                    values (?, ?, ?, ?)');
    # Because data is of type bytea, we have to do a silly parameter-binding
    # dance.
    $s->bind_param(1, $msg);
    $s->bind_param(2, $recip);
    $s->bind_param(3, time());
    $s->bind_param(4, join("\n", @$lines), { pg_type => DBD::Pg::PG_BYTEA });
    $s->execute();

    dbh()->commit();

    return 1;
}

# recipient_id ADDRESS
# Get/create a recipient ID for ADDRESS, and return it.
sub recipient_id ($) {
    my $addr = shift;

    # XXX check validity of address
    
    my $id = dbh()->selectrow_array('
                        select id
                        from recipient
                        where address = ?
                        for update', {}, $addr);
    if (!defined($id)) {
        $id = dbh()->selectrow_array("select nextval('recipient_id_seq')");
        dbh()->do('insert into recipient (id, address) values (?, ?)',
                    {}, $id, $addr);
    }
    return $id;
}

#
# Interface
#

=head1 FUNCTIONS

=head2 Individual Mails

=over 4

=item send MESSAGE RECIPIENT ...

MESSAGE is the full text of a message to be sent to the given RECIPIENTS.

=cut
sub send ($@) {
    my ($data, @recips) = @_;
    my $msg = dbh()->selectrow_array("select nextval('message_id_seq')");
    my $s = dbh()->prepare('
                    insert into message (id, data, whensubmitted)
                    values (?, ?, ?)');
    $s->bind_param(1, $msg);
    $s->bind_param(2, $data);
    $s->bind_param(3, time());
    $s->execute();
    
    foreach (@recips) {
        dbh()->do('
                    insert into message_recipient (message_id, recipient_id)
                    values (?, ?)', {}, $msg, recipient_id($_));
    }

    dbh()->commit();
}

=item is_address_bouncing ADDRESS

Return true if we have received bounces for the ADDRESS.

=cut
sub is_address_bouncing ($) {
    my $addr = shift;
    my $id = dbh()->selectrow_array('
                    select id from recipient where address = ?',
                    {}, $addr);
    return undef if (!defined($id));
    
    # Regard an address as bouncing if we've received any bounces from it
    # within the last week.
    return 1 if (scalar(dbh()->selectrow_array('
                            select count(message_id) from bounce
                            where recipient_id = ?
                                and whenreceived > ?',
                            {}, $id, time() - 7 * 86400)) > 0);

    return 0;
}

=back

=head2 Mailing Lists

=over 4

=item list_create SCOPE TAG NAME MODE [LOCALPART DOMAIN]

Create a new mailing list for the given SCOPE (e.g. "pledgebank") and TAG (a
unique reference for this list within SCOPE). NAME is the human-readable name
of the list and MODE the posting-mode. Possible MODES are:

=over 4

=item any

anyone may post;

=item subscribers

only subscribers may post;

=item admins

only administrators may post; or

=item none

nobody may post, so messages can only be submitted through the EvEl API.

=back

If MODE is anything other than "none", then LOCALPART and DOMAIN must be
specified. These indicate the address for submissions to the list; if
specified, LOCALPART "@" DOMAIN must form a valid mail address.

=cut
sub list_create ($$$$;$$) {
    my ($scope, $tag, $name, $mode, $localpart, $domain) = @_;
 
    throw EvEl::Error("bad MODE '$mode'")
        if ($mode !~ /^(any|subscribers|admins|none)$/);

    throw EvEl::Error("LOCALPART and DOMAIN must be specified for MODE = '$mode'")
        if ($mode ne 'none' and !defined($localpart) || !defined($domain));
 
    throw EvEl::Error("only MODE = 'none' is currently implemented")
        unless ($mode eq 'none'); # XXX
 
    my $id = dbh()->selectrow_array('
                        select id
                        from mailinglist
                        where scope = ? and tag = ?', {}, $scope, $tag);

    # Try to make this idempotent, so assume that a call for an
    # already-existing list succeeded with the same arguments.
    return if (defined($id));

    $id = dbh()->selectrow_array("select nextval('mailinglist_id_seq')");
    dbh()->do('
            insert into mailinglist (
                id,
                scope, tag,
                name,
                localpart, domain,
                postingmode,
                whencreated
            ) values (
                ?,
                ?, ?,
                ?,
                ?, ?,
                ?,
                ?
            )', {},
            $id,
            $scope, $tag,
            $name,
            $localpart, $domain,
            $mode,
            time());

    dbh()->commit();
}

=item list_destroy SCOPE TAG

Delete the list identified by the given SCOPE and TAG.

=cut
sub list_destroy ($$) {
    my ($scope, $tag) = @_;
    my $id = dbh()->selectrow_array('
                        select id
                        from mailinglist
                        where scope = ? and tag = ?
                        for update', {}, $scope, $tag);
    return unless (defined($id));
    dbh()->do('delete from subscriber where mailinglist_id = ?', {}, $id);
    dbh()->do('delete from mailinglist where id = ?', {}, $id);

    dbh()->commit();
}

=item list_subscribe SCOPE TAG ADDRESS [ISADMIN]

Subscribe ADDRESS to the list identified by SCOPE and TAG. Make the user an
administrator if ISADMIN is true. If the ADDRESS is already on the list, then
set their administrator status according to ISADMIN.

=cut
sub list_subscribe ($$$;$) {
    my ($scope, $tag, $addr, $isadmin) = @_;
    $isadmin ||= 0;
    my $id = dbh()->selectrow_array('
                        select id
                        from mailinglist
                        where scope = ? and tag = ?
                        for update', {}, $scope, $tag);

    throw EvEl::Error("no mailing list $scope.$tag")
        unless (defined($id));

    my $recip = recipient_id($addr);

    if (defined(dbh()->selectrow_array('
                        select whensubscribed from subscriber
                        where mailinglist_id = ?
                            and recipient_id = ?
                        for update', {}, $id, $recip))) {
        dbh()->do('
                    update subscriber
                    set isadmin = ?
                    where mailinglist_id = ? and recipient_id = ?',
                    {}, $isadmin ? 't' : 'f', $id, $recip);
    } else {
        dbh()->do('
                    insert into subscriber
                        (mailinglist_id, recipient_id, isadmin, whensubscribed)
                    values (?, ?, ?, ?)',
                    {}, $id, $recip, $isadmin ? 't' : 'f', time());
    }

    dbh()->commit();
}

=item list_unsubscribe SCOPE TAG ADDRESS

Remove ADDRESS from the list identified by SCOPE and TAG.

=cut
sub list_unsubscribe ($$$;$) {
    my ($scope, $tag, $addr, $isadmin) = @_;
    $isadmin ||= 0;
    my $id = dbh()->selectrow_array('
                        select id
                        from mailinglist
                        where scope = ? and tag = ?
                        for update', {}, $scope, $tag);

    throw EvEl::Error("no mailing list $scope.$tag")
        unless (defined($id));

    my $recip = recipient_id($addr);

    dbh()->do('
                delete from subscriber
                where mailinglist_id = ? and recipient_id = ?',
                {}, $id, $recip);

    dbh()->commit();
}

=item list_attribute

=item list_send SCOPE TAG MESSAGE

Send MESSAGE (on-the-wire message data, including all headers) to the list
identified by SCOPE and TAG.

=cut
sub list_send ($$$) {
    my ($scope, $tag, $message) = @_;

    my $id = dbh()->selectrow_array('
                        select id
                        from mailinglist
                        where scope = ? and tag = ?
                        for update', {}, $scope, $tag);
                        
    throw EvEl::Error("no mailing list $scope.$tag")
        unless (defined($id));

    my $msg = dbh()->selectrow_array("select nextval('message_id_seq')");
    my $s = dbh()->prepare('
                    insert into message (id, data, whensubmitted)
                    values (?, ?, ?)');
    $s->bind_param(1, $msg);
    $s->bind_param(2, $message);
    $s->bind_param(3, time());
    $s->execute();

    dbh()->do('
                insert into message_recipient (message_id, recipient_id)
                    select ? as message_id, recipient_id
                    from mailinglist where id = ?',
                {}, $msg, $id);

    dbh()->commit();
}

=item list_members

=back

=cut

1;
