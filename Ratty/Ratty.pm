#!/usr/bin/perl
#
# Ratty.pm:
# Programmable rate limiting.
#
# Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: Ratty.pm,v 1.11 2005-01-11 23:30:38 chris Exp $
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
    $dbh ||= DBI->connect('dbi:Pg:dbname=' .  mySociety::Config::get('RATTY_DB_NAME'),
                        mySociety::Config::get('RATTY_DB_USER'),
                        mySociety::Config::get('RATTY_DB_PASS'),
                        { RaiseError => 1, AutoCommit => 0 });

#    DBI->trace(1);
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
permitted or not. Returns true if it should not, or an array of
[rule_number, message] ift it should.

=cut
sub test ($$) {
    my ($self, $V) = @_;
    my $result = undef;
    if (defined(my $r = $self->{tester}->($V))) {
        # have a hit on rule $r
        # XXX log this
        warn "ratty rule #$r triggered\n";
        my $message = dbh()->selectrow_array('select message from rule where id = ?', {}, $r);
        $message = "" if (!defined($message));
        $result = [$r, $message];
    } else {
        # No rule hits, carry on.
        $result = undef;
    }
#    ++$self->{numsincelastcommit};
#    if ($self->{numsincelastcommit} > 50 || $self->{lastcommit} < time() - 10) {
        dbh()->commit();
#        $self->{numsincelastcommit} = 0;
#        $self->{lastcommit} = time();
#    }
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
                'while(my($key, $value) = each(%$V)) {',
                '   my $num = dbh()->selectrow_array("select count(*) from available_fields where field = ?", {}, "$key");',
                '   $dbh->do("insert into available_fields (field, example) values (?,?)", {}, "$key", "$value") if $num == 0;',
                '}',
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


    my $codejoined = join("\n", @code);
    #warn $codejoined;
    my $subr = eval($codejoined);
    die "evaled code: $@" if ($@);
    my $D = \@data;

    return sub ($) {
            return &$subr($_[0], $D);
        };
}

=item admin_available_fields

I<Instance method.> Returns all the fields Ratty has seen so far, and an
example value of that field.  Structure is an array of pairs of (field,
example).

=cut
sub admin_available_fields ($) {
    my ($self) = @_;
    dbh()->commit();
    my $result = dbh()->selectall_arrayref('select field, example from available_fields');
    return $result;
}

=item admin_update_rule VALS CONDS

I<Instance method.> Either creates a new rule or updates an existing
one.  VALS is a hashref containing id, requests, interval, sequence and
note (see schema.sql).  CONDS is an arrayref of conditions, each a hash
containing field, condition and value.

=cut
sub admin_update_rule ($$$) {
    my ($self, $vals, $conds) = @_;
    dbh()->commit();

    my $return = undef;

    my $result = 0;
    if ($vals->{'rule_id'}) {
        $result = dbh()->selectrow_arrayref('select id from rule where id = ? for update', {}, $vals->{'rule_id'});
    }

    if ($result) {
        dbh()->do('update rule set requests = ?,
            interval = ?, sequence = ?, note = ?, message = ? where id = ?', {}, $vals->{'requests'},
            $vals->{'interval'}, $vals->{'sequence'}, $vals->{'note'}, $vals->{'message'},
            $vals->{'rule_id'});
    } else {
        dbh()->do('insert into rule (requests, interval, sequence, note, message)
            values (?, ?, ?, ?, ?)', {}, $vals->{'requests'},
            $vals->{'interval'}, $vals->{'sequence'}, $vals->{'note'}, $vals->{'message'});
        $return = dbh()->selectrow_array("select currval('rule_id_seq')");
        $vals->{'rule_id'} = $return;
    }

    #warn(Dumper($conds));
    dbh()->do('delete from condition where rule_id = ?', {}, $vals->{'rule_id'});
    foreach my $cond (@$conds) {
        dbh()->do('insert into condition (rule_id, field, condition, value) values (?,?,?,?)',
            {}, $vals->{'rule_id'}, $cond->{'field'},
            $cond->{'condition'}, $cond->{'value'});
    }
    
    dbh()->commit();
    return $return;
}

=item admin_delete_rule ID

I<Instance method.> Deletes the rule of the specified ID.

=cut
sub admin_delete_rule ($$$) {
    my ($self, $id) = @_;
    dbh()->commit();

    my $return = undef;

    dbh()->do('delete from rule_hit where rule_id = ?', {}, $id);
    dbh()->do('delete from condition where rule_id = ?', {}, $id);
    dbh()->do('delete from rule where id = ?', {}, $id);
    dbh()->commit();

    return $return;
}

=item admin_get_rules

I<Instance method.> Returns array of hashes of data about all rules.

=cut
sub admin_get_rules ($) {
    my ($self) = @_;
    
    my $sth = dbh()->prepare('select * from rule order by sequence, note');
    $sth->execute();
    my @ret;
    while (my $hash_ref = $sth->fetchrow_hashref()) {
        my $hits = dbh()->selectrow_array('select count(*) from rule_hit where rule_id = ' .  $hash_ref->{'id'});
        $hash_ref->{'hits'} = $hits;
        push @ret, $hash_ref;
    }

    return \@ret;
}

=item admin_get_rule RULE_ID

I<Instance method.> Returns hash of data about a rule.

=cut
sub admin_get_rule ($$) {
    my ($self, $id) = @_;
    
    my $return = dbh()->selectall_hashref('select * from rule
        where id = ?', 'id', {}, $id);
    return $return->{$id};
}
 
=item admin_get_conditions RULE_ID

I<Instance method.> Returns array of hashes of conditions for one rule.

=cut
sub admin_get_conditions ($$) {
    my ($self, $id) = @_;
    
    my $sth = dbh()->prepare('select * from condition where rule_id = ?');
    $sth->execute($id);
    my @ret;
    while (my $hash_ref = $sth->fetchrow_hashref()) {
        push @ret, $hash_ref;
    }

    return \@ret;
}
  1;
