#!/usr/bin/perl
#
# Ratty.pm:
# Programmable rate limiting.
#
# Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: Ratty.pm,v 1.13 2005-01-12 16:32:56 chris Exp $
#

package Ratty;

use strict;

use DBI;
use Digest::SHA1;
use Error qw(:try);
use Net::Netmask;
use Time::HiRes;

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
    $dbh = undef if (defined($dbh) && defined($dbh->err()));
    $dbh ||= DBI->connect('dbi:Pg:dbname=' .  mySociety::Config::get('RATTY_DB_NAME'),
                        mySociety::Config::get('RATTY_DB_USER'),
                        mySociety::Config::get('RATTY_DB_PASS'),
                        { RaiseError => 1, AutoCommit => 0 });

#    DBI->trace(1);
    return $dbh;
}

sub get_conditions ($) {
    my ($rule) = @_;
    return dbh()->selectall_arrayref('select id, field, condition, value, invert from condition where rule_id = ? order by id', {}, $rule);
}

=item new

I<Class method.> Return a new Ratty testing object.

=cut
sub new ($) {
    my ($class) = @_;
    my $self = { lastrebuild => time() };
    ($self->{lastrebuildgeneration}, $self->{tester}) = compile_rules();
    return bless($self, $class);
}

=item test SCOPE VARS

I<Instance method.> Test whether the request described by VARS should be
permitted or not. Returns true if it should not, or an array of
[rule_number, message] ift it should.

=cut
sub test ($$) {
    my ($self, $scope, $V) = @_;
    my $result = undef;
    if (defined(my $r = $self->{tester}->($scope, $V))) {
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

    # Always commit. Otherwise we can deadlock, because of the way that
    # Postgres checks foreign keys. See
    #   http://archives.postgresql.org/pgsql-general/2004-03/msg00407.php
    # Basically we get to pick two of,
    #   - efficient
    #   - concurrent
    #   - correct
    $dbh->commit();

    if ($self->{lastrebuild} < time() - 5) {
        my $gen = dbh()->selectrow_array('select number from generation');
        ($self->{lastrebuildgeneration}, $self->{tester}) = compile_rules()
            if ($gen != $self->{lastrebuildgeneration});
        $self->{lastrebuild} = time();
    }
    return $result;
}

# compile_rules
# Return in list context the current generation number and a code reference for
# testing requests against rate-limiting rules. The returned code ref returns a
# rule ID when a request exceeds the rate limit, or undef if it does not; it
# tests all scopes.
sub compile_rules () {
    my $generation = dbh()->selectrow_array('select number from generation');
    my @code = (
        'sub ($$$$) {',
            'my ($V, $scope, $data, $seen_fields) = @_;',
            'my $dbh = Ratty::dbh();',

            # Update the available fields table if there are fields we
            # haven't seen before.
            'my $af = 0;',
            'while (my ($field, $value) = each(%$V)) {',
            '   if (!exists($seen_fields->{$scope}) or !exists($seen_fields->{$scope}->{$field})) {',
            '       $seen_fields->{$scope}->{$field} = 1;',
            '       if (!defined(scalar(dbh()->selectrow_array(q#select example from available_fields where scope = ? and field = ? for update#, {}, $scope, $field)))) {',
            '           my $example = $value;',
            '           $example = substr($value, 0, 16) . "..." if (length($example) > 16);',
            '           $dbh->do("insert into available_fields (scope, field, example) values (?, ?, ?)", {}, $scope, $field, $example);',
            '           ++$af;',
            '       }',
            '   }',
            '}',
            'dbh()->commit() if ($af > 0);',

            'my $result = undef;'
        );

    # We stow all literal strings etc. in the array @data, which is then passed
    # to the constructed function. The point of this is to avoid having to
    # stick literals into the constructed source code (which would involve
    # deciding how to quote them, etc.). Doing it this way means that we don't
    # need to quote our input or even trust it (modulo bugs in perl).
    my @data = ();

    foreach my $rule (@{dbh()->selectall_arrayref('select id, requests, interval, scope from rule order by sequence')}) {
        my ($ruleid, $requests, $interval, $scope) = @$rule;

        push(@data, $scope);
        my $si = $#data;

        push(@code, sprintf('if ($scope eq $data->[%d]', $si));
        my $conditions = get_conditions($ruleid);
        
        # Do local matches.
        foreach (grep { $_->[2] !~ m#[SD]# } @$conditions) {
            my ($id, $field, $condition, $value, $invert) = @$_;
            push(@data, $field);
            my $fi = $#data;
            push(@code, sprintf('&& defined($V->{$data->[%d]}) &&', $fi));
            if ($condition eq 'E') {
                push(@data, $value);
                my $vi = $#data;
                push (@code, sprintf('$V->{$data->[%d]} %s $data->[%d]', $fi, $invert ? 'ne' : 'eq', $vi));
            } elsif ($condition eq 'R') {
                # Construct a regexp from the value.
                my $re = eval(sprintf('qr#%s#', $value));
                if (defined($re)) {
                    push(@data, $re);
                    my $vi = $#data;
                    push(@code, sprintf('$V->{$data->[%d]} %s m#$data->[%d]#i', $fi, $invert ? '!~' : '=~', $vi));
                } else {
                    push(@code, '0');
                }
            } elsif ($condition eq 'I') {
                my $ipnet = new2 Net::Netmask($value);
                if (defined($ipnet)) {
                    push(@data, $ipnet);
                    my $vi = $#data;
                    push(@code, sprintf('%s$data->[%d]->match($V->{$data->[%d]})', $invert ? '!' : '', $vi, $fi));
                } else {
                    push(@code, '0');
                }
            } elsif ($condition eq '<' or $condition eq '>') {
                my $number = $value + 0.0;   # XXX should check that value is a number
                if ($invert) {
                    if ($condition eq '<') {
                        $condition = '>=';
                    } else {
                        $condition = '<=';
                    }
                }
                push(@data, $number);
                my $vi = $#data;
                push(@code, sprintf('$V->{$data->[%d]} %s $data->[%d]', $fi, $condition, $vi));
            }
        }
        push(@code, ')) {',
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
            sprintf('$dbh->do(q#insert into rule_hit (rule_id, hit, shash, dhash) values (?, ?, ?, ?)#, {}, %d, Time::HiRes::time(), %s, %s);',
                    $ruleid, (@sconds ? '$S->b64digest()' : 'undef'), (@dconds ? '$D->b64digest()' : 'undef')));

        # Nuke old hits (XXX do this elsewhere?)
        push(@code, sprintf('$dbh->do(q#delete from rule_hit where rule_id = ? and hit < ?#, {}, %d, time() - $interval);', $ruleid));

        # If we've got here, and the number of requests over the last interval
        # exceeds the limit, record the matching rule if it's the first which
        # matches.
        push(@code, sprintf('$result ||= %d if ($num > $requests);', $ruleid),
                    '}');
    }

    push(@code, 
                'return $result;',
            '}'
        );


    my $codejoined = join("\n", @code);
    #warn $codejoined;
    my $subr = eval($codejoined);
    die "evaled code: $@" if ($@);
    
    my $D = \@data;
    
    # Construct hash of seen fields
    my $S = { };
    
    foreach my $row (@{dbh()->selectall_arrayref('select scope, field from available_fields')}) {
        my ($scope, $field) = @$row;
        $S->{$scope}->{$field} = 1;
    }

    # Finish up the transaction.
    dbh()->commit();

    return (
            $generation,
            sub ($$) {
                return &$subr($_[0], $D, $S);
            }
        );
}

=item admin_available_fields SCOPE

I<Instance method.> Returns all the fields Ratty has seen so far in the given
SCOPE, and an example value of that field.  Structure is an array of pairs of
(field, example).

=cut
sub admin_available_fields ($$) {
    my ($self, $scope) = @_;
    my $result = dbh()->selectall_arrayref('select field, example from available_fields where scope = ?', {}, $scope);
    return $result;
}

=item admin_update_rule SCOPE RULE CONDITIONS

I<Instance method.> Either creates a new rule or updates an existing one. RULE
is a hashref containing requests, interval, sequence, note and an optional
rule_id (see schema.sql). CONDITIONS is an arrayref of conditions, each a hash
containing field, condition and value.

=cut
sub admin_update_rule ($$$$) {
    my ($self, $scope, $rule, $conds) = @_;

    my $return = undef;

    my $result = undef;
    if (exists($rule->{'rule_id'})) {
        $result = dbh()->selectrow_arrayref('select id from rule where id = ? for update', {}, $rule->{'rule_id'});
        die "mismatch between scope \"$scope\" and rule ID \"$rule->{rule_id}\""
            if (defined($result) and $result->{scope} ne $scope);
    }

    if (defined($result)) {
        dbh()->do('update rule set requests = ?, interval = ?, sequence = ?, note = ?, message = ? where scope = ? and id = ?', {}, $rule->{'requests'},
            $rule->{'interval'}, $rule->{'sequence'}, $rule->{'note'}, $rule->{'message'},
            $scope, $rule->{'rule_id'});
    } else {
        dbh()->do('insert into rule (scope, requests, interval, sequence, note, message)
            values (?, ?, ?, ?, ?, ?)', {}, $scope, $rule->{'requests'},
            $rule->{'interval'}, $rule->{'sequence'}, $rule->{'note'}, $rule->{'message'});
        $return = dbh()->selectrow_array("select currval('rule_id_seq')");
        $rule->{'rule_id'} = $return;
    }

    #warn(Dumper($conds));
    dbh()->do('delete from condition where rule_id = ?', {}, $rule->{'rule_id'});
    foreach my $cond (@$conds) {
        dbh()->do('insert into condition (rule_id, field, condition, value) values (?,?,?,?)',
            {}, $rule->{'rule_id'}, $cond->{'field'},
            $cond->{'condition'}, $cond->{'value'});
    }
    
    dbh()->commit();
    return $return;
}

=item admin_delete_rule SCOPE ID

I<Instance method.> Deletes the rule of the specified ID.

=cut
sub admin_delete_rule ($$$) {
    my ($self, $scope, $id) = @_;

    my $return = undef;

    my $scope2 = dbh()->selectrow_array('select scope from rule where id = ? for update', {}, $id);
    if (defined($scope)) {
        if ($scope2 eq $scope) {
            dbh()->do('delete from rule_hit where rule_id = ?', {}, $id);
            dbh()->do('delete from condition where rule_id = ?', {}, $id);
            dbh()->do('delete from rule where id = ?', {}, $id);
            dbh()->commit();
        } else {
            die "mismatch between scope \"$scope\" and rule ID \"$id\""
        }
    }

    return $return;
}

=item admin_get_rules SCOPE

I<Instance method.> Returns array of hashes of data about all rules.

=cut
sub admin_get_rules ($$) {
    my ($self, $scope) = @_;
    
    my $sth = dbh()->prepare('select * from rule where scope = ? order by sequence, note', {}, $scope);
    $sth->execute();
    my @ret;
    while (my $rule = $sth->fetchrow_hashref()) {
        my $hits = dbh()->selectrow_array('select count(*) from rule_hit where rule_id = ?', {}, $rule->{'id'});
        $rule->{'hits'} = $hits;
        push(@ret, $rule);
    }

    return \@ret;
}

=item admin_get_rule SCOPE ID

I<Instance method.> Returns hash of data about a rule.

=cut
sub admin_get_rule ($$) {
    my ($self, $scope, $id) = @_;
    
    my $rule = dbh()->selectrow_hashref('select * from rule where id = ?', {}, $id);
    die "mismatch between scope \"$scope\" and rule ID \"$id\"" unless ($rule->{scope} eq $scope);
    return $rule;
}
 
=item admin_get_conditions SCOPE ID

I<Instance method.> Returns array of hashes of conditions for one rule.

=cut
sub admin_get_conditions ($$$) {
    my ($self, $scope, $id) = @_;

    my $scope2 = dbh()->selectrow_array('select scope from rule where id = ?', {}, $id);
    die "mismatch between scope \"$scope\" and rule ID \"$id\"" unless ($scope2 eq $scope);
    
    my $sth = dbh()->prepare('select * from condition where rule_id = ?');
    $sth->execute($id);
    my @ret;
    while (my $hash_ref = $sth->fetchrow_hashref()) {
        push @ret, $hash_ref;
    }

    return \@ret;
}

1;
