#!/usr/bin/perl
#
# EvEl.pm:
# Implementation of EvEl.
#
# Copyright (c) 2005 Chris Lightfoot. All rights reserved.
# Email: chris@ex-parrot.com; WWW: http://www.ex-parrot.com/~chris/
#
# $Id: EvEl.pm,v 1.1 2005-03-22 17:23:03 chris Exp $
#

package EvEl::Error;

@EvEl::Error::ISA = qw(Error::Simple);

package EvEl;

use strict;

use Digest::SHA1;
use Net::SMTP;

use mySociety::DBHandle qw(dbh);
use mySociety::Util qw(random_bytes);

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
    my ($smtp, $result, $what);
    if ($result) {
        $! = undef;
        return;
    }
    throw EvEl::Error("SMTP server: command $what: $!") if ($!);
    # Distinguish permanent/temporary failures?
    throw EvEl::Error("SMTP server: command $what: " . $smtp->code() . " " . $smtp->message());
}

# run_queue
# Run the queue of outgoing messages.
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
    my $nsent = 0;
    
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
                    ', {}, $msg, $recip);
        next unless ($d);

        # Get a connection to the SMTP server, if needed.
        if (!$smtp || $nsent > 10) {
            $smtp->quit() if ($smtp);
            my $smtpserver = mySociety::Config::get('EVEL_MAIL_HOST', 'localhost');
            $smtp = new Net::SMTP(Host => $smtpserver, Timeout => 10) or
                throw EvEl::Error("unable to connect to $smtpserver: $!");
            $nsent = 0;
        }

        # Split message text into lines.
        my @lines;
        if ($d->{data} =~ m#\r\n#s) {
            @lines = split(m#\r\n#, $d->{data});
        } else {
            @lines = split(m#\n#, $d->{data});
        }

        # Construct a unique return-path for this address, so that we can do
        # bounce detection. Ignore the VERP/XVERP ESMTP stuff, for the moment.
        my $verp = verp_address($msg, $recip);
        try {
            do_smtp($smtp, $smtp->mail($verp), 'MAIL FROM');
            do_smtp($smtp, $smtp->recipient($d->{address}), 'RCPT TO');
            do_smtp($smtp, $smtp->data(\@lines), 'DATA');
        } catch EvEl::Error with {
            my $E = shift;
            $smtp->quit();
            $smtp = undef;
            # For the moment just treat all errors the same way: abort the
            # queue run and hold off for a bit.
            dbh()->do('
                    update message_recipient
                    set numattempts = numattempts + 1,
                        lastattempt = ?
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
}

# process_bounce RECIPIENT LINES
# Process a received bounce message. RECIPIENT is the address for which it was
# received, and LINES is a reference to a list of the lines of the message
# received (with line-endings stripped).
sub process_bounce ($$) {
    my ($addr, $lines) = @_;
    # Try to extract message and recipient IDs. If we fail, ignore this bounce.
    my ($msg, $recip) = parse_verp_address($addr)
        or return;
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
}

=head1 NAME

EvEl

=head1 DESCRIPTION

Generic email sending and mailing list functionality, with bounce detection
etc.

=head1 FUNCTIONS

=head1 Individual Mails

=over 4

=item send MESSAGE RECIPIENT ...

=cut
sub send ($@) {
    my ($msg, @recips) = @_;
}

=item is_address_bouncing

=back

=head1 Mailing Lists

=over 4

=item list_create

=item list_destroy

=item list_subscribe

=item list_unsubscribe

=item list_attribute

=item list_send

=item list_members

=back

=cut

1;
