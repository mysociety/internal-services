#!/usr/bin/perl
#
# Ratty.pm:
# Programmable rate limiting.
#
# Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: Ratty.pm,v 1.1 2004-11-10 13:08:00 francis Exp $
#

package Ratty;

use strict;

use DBI;
use Digest::SHA1;
use Error qw(:try);
use Net::Netmask;

use Data::Dumper;

=head1 NAME

Ratty

=head1 SYNOPSIS

    my $r = new Ratty();
    while (my $var = get_request_from_somewhere()) {
        if ($r->test($var)) {
            # request should go ahead
        } else {
            # request should be rate-limited
        }
    }

=head1 DESCRIPTION

Implementation of rate-limiting.

=head1 FUNCTIONS

=over 4

=cut

my $dbh;
sub dbh() {
    $dbh ||= DBI->connect('dbi:Pg:dbname=ratty', 'ratty', '', { AutoCommit => 0, RaiseError => 1 });
    return $dbh;
}

sub get_conditions ($) {
    my ($rule) = @_;
    return dbh()->selectall_arrayref('select id, field, condition, value from condition where rule_id = ? order by id', {}, $rule);
}

=item new

I<Class method.> Return a new Ratty testing object.

=cut
sub new ($) {
    my ($class) = @_;
    my $self = {
            lastcommit => time(),
            numsincelastcommit => 0,
            lastrebuild => time(),
            tester => compile_rules()
        };
    return bless($self, $class);
}

=item test VARS

I<Instance method.> Test whether the request described by VARS should be
permitted or not. Returns true if it should, or false if it should not.

=cut
sub test ($$) {
    my ($self, $V) = @_;
    my $result = undef;
    if (defined(my $r = $self->{tester}->($V))) {
        # have a hit on rule $r
        # XXX log this
        warn "rule #$r triggered\n";
        $result = 0;
    } else {
        # No rule hits, carry on.
        $result = 1;
    }
    ++$self->{numsincelastcommit};
    if ($self->{numsincelastcommit} > 50 || $self->{lastcommit} < time() - 10) {
        dbh()->commit();
        $self->{numsincelastcommit} = 0;
        $self->{lastcommit} = time();
    }
    # XXX should check for updates properly, with a trigger which updates a
    # counter whenever the conditions or rule tables are modified.
    if ($self->{lastrebuild} < time() - 60) {
        $self->{tester} = compile_rules();
        $self->{lastrebuild} = time();
    }
    return $result;
}

# compile_rules
# Return a code reference for testing requests against rate-limiting rules. The
# returned code ref returns a rule ID when a request exceeds the rate limit, or
# undef if it does not.
sub compile_rules () {
    my @code = ('sub ($$) {',
                'my ($V, $data) = @_;',
                'my $dbh = Ratty::dbh();',
                'my $result = undef;');

    # We stow all literal strings etc. in the array @data, which is then passed
    # to the constructed function. The point of this is to avoid having to
    # stick literals into the constructed source code (which would involve
    # deciding how to quote them, etc.). Doing it this way means that we don't
    # need to quote our input or even trust it (modulo bugs in perl).
    my @data = ();

    foreach my $rule (@{dbh()->selectall_arrayref('select id, requests, interval from rule order by sequence')}) {
        my ($ruleid, $requests, $interval) = @$rule;

        push(@code, 'if (1');
        my $conditions = get_conditions($ruleid);
        
        # Do local matches.
        foreach (grep { $_->[2] !~ m#[SD]# } @$conditions) {
            my ($id, $field, $condition, $value) = @$_;
            push(@data, $field);
            my $fi = $#data;
            push(@code, sprintf('&& defined($V->{$data->[%d]}) &&', $fi));
            if ($condition eq 'E') {
                push(@data, $value);
                my $vi = $#data;
                push (@code, sprintf('$V->{$data->[%d]} eq $data->[%d]', $fi, $vi));
            } elsif ($condition eq 'R') {
                # Construct a regexp from the value.
                my $re = eval(sprintf('qr#%s#', $value));
                if (defined($re)) {
                    push(@data, $re);
                    my $vi = $#data;
                    push(@code, sprintf('$V->{$data->[%d]} =~ m#$data->[%d]#i', $fi, $vi));
                } else {
                    push(@code, '0');
                }
            } elsif ($condition eq 'I') {
                my $ipnet = new2 Net::Netmask($value);
                if (defined($ipnet)) {
                    push(@data, $ipnet);
                    my $vi = $#data;
                    push(@code, sprintf('$data->[%d]->match($V->{$data->[%d]})', $vi, $fi));
                } else {
                    push(@code, '0');
                }
            }
        }
        push(@code, ') {',
                    sprintf('my ($num, $requests, $interval) = (0, %d, %d);', $requests, $interval));

        my @sdconds = grep { $_->[2] =~ m#^[SD]$# } @$conditions;
        my @sconds = grep { $_->[2] eq 'S' } @sdconds;
        my @dconds = grep { $_->[2] eq 'D' } @sdconds;

        if (@sdconds) {
            # Now assemble all the single/distinct matches.
            push(@code, 'my $S = new Digest::SHA1();') if (@sconds);
            push(@code, 'my $D = new Digest::SHA1();') if (@dconds);
            foreach (@sdconds) {
                my ($id, $field, $condition, $value) = @$_;
                push(@data, $field);
                my $fi = $#data;
                push(@code, sprintf('$%s->add($V->{$data->[%d]}) if (defined($V->{$data->[%d]}));', $condition, $fi, $fi));
            }
        }

        # Construct statement to retrieve number of hits from database.
        my $expr = '$num = Ratty::dbh()->selectrow_array(q#select count(hit) from rule_hit where rule_id = ? and hit >= ?';
        $expr .= ' and shash = ?' if (@sconds);
        $expr .= ' and dhash <> ?' if (@dconds);
        $expr .= sprintf('#, {}, %d, time() - $interval', $ruleid);
        # need clone() as *digest methods are destructive.
        $expr .= sprintf(', $S->clone()->b64digest()') if (@sconds);
        $expr .= sprintf(', $D->clone()->b64digest()') if (@dconds);
        $expr .= ');';
        push(@code, $expr);

        # Record this hit.
        push(@code,
            sprintf('$dbh->do(q#insert into rule_hit (rule_id, hit, shash, dhash) values (?, ?, ?, ?)#, {}, %d, time(), %s, %s);',
                    $ruleid, (@sconds ? '$S->b64digest()' : 'undef'), (@dconds ? '$D->b64digest()' : 'undef')));

        # Nuke old hits (XXX do this elsewhere?)
        push(@code, sprintf('$dbh->do(q#delete from rule_hit where rule_id = ? and hit < ?#, {}, %d, time() - $interval);', $ruleid));

        # If we've got here, and the number of requests over the last interval
        # exceeds the limit, record the matching rule if it's the first which
        # matches.
        push(@code, sprintf('$result ||= %d if ($num > $requests);', $ruleid),
                    '}');
    }

    push(@code, 'return $result;',
                '}');

    my $subr = eval(join("\n", @code));
    die "evaled code: $@" if ($@);
    my $D = \@data;

    return sub ($) {
            return &$subr($_[0], $D);
        };
}


1;
