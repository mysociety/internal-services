#!/usr/bin/perl
#
# EvEl.pm:
# Implementation of EvEl.
#
# Copyright (c) 2005 Chris Lightfoot. All rights reserved.
# Email: chris@ex-parrot.com; WWW: http://www.ex-parrot.com/~chris/
#
# $Id: EvEl.pm,v 1.12 2005-04-01 10:40:06 francis Exp $
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
use MIME::Entity;
use MIME::Words;
use Net::SMTP;
use Text::Wrap ();
use Data::Dumper;
use utf8;

use mySociety::Config;
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

# is_valid_address ADDRESS
# Restricted syntax-check for ADDRESS. We check for what RFC2821 calls a
# "mailbox", which is "local-part@domain", with the restriction of no
# address-literal domains (e.g "[127.0.0.1]"). We also don't do bang paths.
sub is_valid_address ($) {
    my $addr = shift;
    our $is_valid_address_re;

    if (!defined($is_valid_address_re)) {
        # mailbox = local-part "@" domain
        # local-part = dot-string | quoted-string
        # dot-string = atom ("." atom)*
        # atom = atext+
        # atext = any character other than space, specials or controls
        # quoted-string = '"' (qtext|quoted-pair)* '"'
        # qtext = any character other than '"', '\', or CR
        # quoted-pair = "\" any character
        # domain = sub-domain ("." sub-domain)* | address-literal
        # sub-domain = [A-Za-z0-9][A-Za-z0-9-]*
        # XXX ignore address-literal because nobody uses those...

        my $specials = '()<>@,;:\\\\".\\[\\]';
        my $controls = '\\000-\\037\\177';
        my $highbit = '\\200-\\377';
        my $atext = "[^$specials $controls$highbit]";
        my $atom = "$atext+";
        my $dot_string = "$atom(\\s*\\.\\s*$atom)*";
        my $qtext = "[^\"\\\\\\r\\n$highbit]";
        my $quoted_pair = '\\.';
        my $quoted_string = "\"($qtext|$quoted_pair)*\"";
        my $local_part = "($dot_string|$quoted_string)";
        my $sub_domain = '[A-Za-z0-9][A-Za-z0-9-]*';
        my $domain = "$sub_domain(\\s*\\.\\s*$sub_domain)*";

        $is_valid_address_re = "^$local_part\\s*@\\s*$domain\$";
    }
 
    if ($addr =~ m#$is_valid_address_re#) {
        return 1;
    } else {
        return 0;
    }
}

# recipient_id ADDRESS
# Get/create a recipient ID for ADDRESS, and return it.
sub recipient_id ($) {
    my $addr = shift;

    throw EvEl::Error("'$addr' is not a valid email-address")
        if (!is_valid_address($addr));
    
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


# XXX next two functions copied from FYR::Queue...

# format_mimewords STRING
# Return STRING, formatted for inclusion in an email header.
sub format_mimewords ($) {
    my ($text) = @_;
    my $out = '';
    foreach my $s (split(/(\s+)/, $text)) {
        utf8::encode($s); # turn to string of bytes
        if ($s =~ m#[\x00-\x1f\x80-\xff]#) {
            $s = MIME::Words::encode_mimeword($s, 'Q', 'utf-8');
        }
        utf8::decode($s);
        $out .= $s;
    }
    return $out;
}

# format_email_address NAME ADDRESS
# Return a suitably MIME-encoded version of "NAME <ADDRESS>" suitable for use
# in an email From:/To: header.
sub format_email_address ($$) {
    my ($name, $addr) = @_;
    return sprintf('%s <%s>', format_mimewords($name), $addr);
}

sub do_one_substitution ($$) {
    my ($p, $n) = @_;
    throw EvEl::Error("Substitution parameter '$n' is not present")
        unless (exists($p->{$n}));
    return $p->{$n};
}

# do_template_substitution TEMPLATE PARAMETERS
#
sub do_template_substitution ($$) {
    my ($body, $params) = @_;
    $body =~ s#<\?=\$values\['([^']+)'\]\?>#do_one_substitution($params, $1)#ges;

    my $subject;
    if ($body =~ m#^Subject: ([^\n]*)\n\n#s) {
        $subject = $1;
        $body =~ s#^Subject: ([^\n]*)\n\n##s;
    }

    # Only treat paragraph breaks as significant.
    $body =~ s#(?<!\n)\s*\n\s*(?!\n)# #gs;

    # Wrap text to 72-column lines.
    local($Text::Wrap::columns = 72);
    local($Text::Wrap::huge = 'overflow');

    return ($subject, Text::Wrap::wrap('', '', $body));
}

#
# Interface
#

=head1 FUNCTIONS

=head2 Formatting mails

=over 4

=item construct_email SPEC

Construct a wire-format (RFC2822) email message according to SPEC, which is an
associative array containing elements as follows:

=over 4

=item _body_

Text of the message to send, as a UTF-8 string with "\n" line-endings.

=item _template_, _parameters_

Templated body text and an associative array of template parameters containing
optional substititutions <?=$values['name']?>, each of which is replaced by the
value of the corresponding named value in _parameters_. It is an error to use a
substitution when the corresponding parameter is not present or undefined. The
first line of the template will be interpreted as contents of the Subject:
header of the mail if it begins with the literal string 'Subject: ' followed by
a blank line. The templated text will be word-wrapped to produce lines of
appropriate length.

=item To

Contents of the To: header, as a literal UTF-8 string or an array of addresses
or [address, name] pairs.

=item From

Contents of the From: header, as an email address or an [address, name] pair.

=item Cc

Contents of the Cc: header, as for To.

=item Subject

Contents of the Subject: header, as a UTF-8 string.

=item Message-ID

Contents of the Message-ID: header, as a US-ASCII string.

=item I<any other element>

interpreted as the literal value of a header with the same name.

=back

If no Message-ID is given, one is generated. If no To is given, then the string
"Undisclosed-Recipients: ;" is used. If no From is given, a generic no-reply
address is used. It is an error to fail to give a body, templated body, or
Subject.

=cut
sub construct_email ($) {
    my $p = shift;
    throw EvEl::Error("missing field 'Subject' in MESSAGE") if (!exists($p->{Subject}));

    if (!exists($p->{_body_}) && (!exists($p->{_template_}) || !exists($p->{_parameters_}))) {
        throw EvEl::Error("Must specify field '_body_' or both '_template_' and '_parameters_'");
    }

    if (exists($p->{_template_})) {
        throw EvEl::Error("Template parameters '_parameters_' must be an associative array")
            if (ref($p->{_parameters_}) ne 'HASH');
        
        (my $subject, $p->{_body_}) = do_template_substitution($p->{_template_}, $p->{_parameters_});
        delete($p->{_template_});
        delete($p->{_parameters_});

        $p->{Subject} = $subject if (defined($subject));
    }

    my %hdr;
    # To: and Cc: are address-lists.
    foreach (qw(To Cc)) {
        next unless (exists($p->{$_}));

        if (ref($p->{$_}) eq '') {
            # Interpret as a literal string in UTF-8, so all we need to do is
            # escape it.
            $hdr{$_} = format_mimewords($p->{$_});
        } elsif (ref($p->{$_}) eq 'ARRAY') {
            # Array of addresses or [address, name] pairs.
            my @a = ( );
            foreach (@{$p->{$_}}) {
                if (ref($_) eq '') {
                    push(@a, $_);
                } elsif (ref($_) ne 'ARRAY' || @$_ != 2) {
                    throw EvEl::Error("Element of '$_' field should be string or 2-element array");
                } else {
                    push(@a, format_email_address($_->[1], $_->[0]));
                }
            }
            $hdr{$_} = join(', ', @a);
        } else {
            throw EvEl::Error("Field '$_' in MESSAGE should be single value or an array");
        }
    }

    if (exists($p->{From})) {
        if (ref($p->{From}) eq '') {
            $hdr{From} = $p->{From}; # XXX check syntax?
        } elsif (ref($p->{From}) ne 'ARRAY' || @{$p->{From}} != 2) {
            throw EvEl::Error("'From' field should be string or 2-element array");
        } else {
            $hdr{From} = format_email_address($p->{From}->[1], $p->{From}->[0]);
        }
    }

    # Some defaults
    $hdr{To} ||= 'Undisclosed-recipients: ;';
    $hdr{From} ||= sprintf('%sno-reply@%s',
                            mySociety::Config::get('EVEL_VERP_PREFIX'),
                            mySociety::Config::get('EVEL_VERP_DOMAIN')
                        );
    $hdr{'Message-ID'} ||= sprintf('<%s%s@%s>',
                            mySociety::Config::get('EVEL_VERP_PREFIX'),
                            unpack('h*', random_bytes(5)),
                            mySociety::Config::get('EVEL_VERP_DOMAIN')
                        );

    foreach (keys(%$p)) {
        $hdr{$_} = $p->{$_} if ($_ ne '_data_' && !exists($hdr{$_}));
    }

    return MIME::Entity->build(
                    %hdr,
                    Data => $p->{_body_},
                    Type => 'text/plain; charset="utf-8"',
                    Encoding => 'quoted-printable'
                )->stringify();
}

=back

=head2 Individual Mails

=over 4

=item send MESSAGE RECIPIENTS

Send a MESSAGE to the given RECIPIENTS.  MESSAGE is either the full text of a
message (in its RFC2822, on-the-wire format) or an associative array as passed
to construct_email.  RECIPIENTS is either one email address string, or an 
array of them for multiple recipients.

=cut
sub send ($@) {
    my ($data, $recips) = @_;

    if (ref($data) eq 'HASH') {
        $data = construct_email($data);
    } elsif (ref($data) ne '') {
        throw EvEl::Error("MESSAGE should be a string or an associative array");
    }
    
    if (ref($recips) eq '') {
        $recips = [$recips];
    } elsif (ref($recips) ne 'ARRAY') {
        throw EvEl::Error("RECIPIENTS should be a string or an array");
    }

    my $msg = dbh()->selectrow_array("select nextval('message_id_seq')");
    my $s = dbh()->prepare('
                    insert into message (id, data, whensubmitted)
                    values (?, ?, ?)');
    $s->bind_param(1, $msg);
    $s->bind_param(2, $data);
    $s->bind_param(3, time());
    $s->execute();
    
    foreach (@$recips) {
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
