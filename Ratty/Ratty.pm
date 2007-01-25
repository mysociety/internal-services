#!/usr/bin/perl
#
# Ratty.pm:
# Programmable rate limiting.
#
# Copyright (c) 2004 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: Ratty.pm,v 1.28 2007-01-25 15:07:30 louise Exp $
#

package Ratty::Error;

use RABX;

@Ratty::Error::ISA = qw(RABX::Error::User);

package Ratty;

use strict;

use DBI;
use Digest::SHA1;
use Error qw(:try);
use Net::Netmask;
use Time::HiRes;

use mySociety::DBHandle qw(dbh);

mySociety::DBHandle::configure(
        Name => mySociety::Config::get('RATTY_DB_NAME'),
        User => mySociety::Config::get('RATTY_DB_USER'),
        Password => mySociety::Config::get('RATTY_DB_PASS'),
        Host => mySociety::Config::get('RATTY_DB_HOST', undef),
        Port => mySociety::Config::get('RATTY_DB_PORT', undef)
    );

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

sub get_conditions ($) {
    my ($rule) = @_;
    return dbh()->selectall_arrayref('select id, field, condition, value, invert from condition where rule_id = ? order by id', {}, $rule);
}

=item new

I<Class method.> Return a new Ratty testing object.

=cut
sub new ($) {
    my ($class) = @_;
    my $self = { };
    ($self->{generation}, $self->{tester}) = compile_rules();
    return bless($self, $class);
}

=item test SCOPE VARS

I<Instance method.> Test whether the request described by VARS should be
permitted or not. VARS is a reference to a hash, each key of which is the name
of a value, and each value of which is a reference to an array giving the value
itself (or undef if a possible field is not present) and a textual description
of the meaning of the field. Returns true if the request should be permitted,
or an array of [rule number, message, rule description] it it should not. The
message may be blank ('') and the description undefined.

=cut
sub test ($$) {
    my ($self, $scope, $V) = @_;
    my $result = undef;

    # Sanity checks.
    throw Ratty::Error('SCOPE must be specified') unless (defined($scope));
    throw Ratty::Error('VARS must be a reference to a hash') if (!ref($V) or ref($V) ne 'HASH');
    foreach my $k (keys %$V) {
        my $v = $V->{$k};
        throw Ratty::Error("Value for '$k' must be list of two elements")
            unless (ref($v) and ref($v) eq 'ARRAY' and @$v == 2);
        throw Ratty::Error("No description supplied for field '$k'")
            unless (defined($v->[1]));
    }

    # Always check the generation number. Otherwise we can get a referential
    # integrity violation if a rule is deleted.
    my $gen = dbh()->selectrow_array('select number from generation');
    ($self->{generation}, $self->{tester}) = compile_rules()
        if ($gen != $self->{generation});

    if (defined(my $r = $self->{tester}->($scope, $V))) {
        # have a hit on rule $r
        # XXX log this properly
#        warn "ratty rule #$r triggered\n";
        my ($message, $note) = dbh()->selectrow_array('select message, note from rule where id = ?', {}, $r);
        $message = "" if (!defined($message));
        $result = [$r, $message, $note];
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
    dbh()->commit();

    return $result;
}

# canonicalise TEXT
# Return TEXT stripped of whitespace and punctuation.
sub canonicalise ($) {
    my $text = lc($_[0]);
    $text =~ s#[[:punct:]]##g;
    $text =~ s#\p{IsSpace}##g;
    return $text;
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
            'my ($scope, $V, $data, $seen_fields) = @_;',
            'my $dbh = dbh();',

            # Update the available fields table if there are fields we
            # haven't seen before.
            'my $af = 0;',
            'while (my ($field, $vv) = each(%$V)) {',
            '   next if (exists($seen_fields->{$scope}->{$field}));',
            '   my ($example, $description) = @$vv;',
            '   my $f = 0;',
                # Save up to three distinct examples of each field.
            '   if (defined($example)',
            '       and scalar(dbh()->selectrow_array(q#select count(*) from field_example where scope = ? and field = ?#, {}, $scope, $field)) < 3',
            '       and !defined(dbh()->selectrow_array(q#select example from field_example where scope = ? and field = ? and example = ? for update#, {}, $scope, $field, $example))) {',
            '       dbh()->do(q#insert into field_example (scope, field, example) values (?, ?, ?)#, {}, $scope, $field, $example);',
            '       ++$f;',
            '   }',
                # Save the field description too.
            '   if (!defined(scalar(dbh()->selectrow_array(q#select description from field_description where scope = ? and field = ? for update#, {}, $scope, $field)))) {',
            '       dbh()->do(q#insert into field_description (scope, field, description) values (?, ?, ?)#, {}, $scope, $field, $description);',
            '       ++$f;',
            '   }',
            '   if (!$f) {',
            '       $seen_fields->{$scope}->{$field} = 1;',
            '   } else {',
            '       ++$af;',
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
            push(@code, sprintf('    && defined($V->{$data->[%d]}->[0]) &&', $fi));
            if ($condition eq 'E') {
                push(@data, $value);
                my $vi = $#data;
                push (@code, sprintf('        $V->{$data->[%d]}->[0] %s $data->[%d]', $fi, $invert ? 'ne' : 'eq', $vi));
            } elsif ($condition eq 'R') {
                # Construct a regexp from the value. Note that we MUST use qr'
                # as the delimiters, since we must not allow variable
                # interpolation. Otherwise a regex like (say) "@mysociety\.org"
                # would have the value of @mysociety (presumably empty)
                # interpolated into it.
                my $re = eval(sprintf(q#qr'%s'i#, $value));
                if (defined($re)) {
                    push(@data, $re);
                    my $vi = $#data;
                    push(@code, sprintf('        $V->{$data->[%d]}->[0] %s $data->[%d]', $fi, $invert ? '!~' : '=~', $vi));
                } else {
                    push(@code, '        0');
                }
            } elsif ($condition eq 'T') {
                # Loose text match. Do this like in FYR::SubstringHash -- see
                # canonicalise() above -- and then use a regex match.
                push(@data, $value);
                my $vi = $#data;
                push(@code, sprintf('        index($V->{$data->[%d]}->[0], $data->[%d]) %s -1', $fi, $vi, $invert ? '==' : '!='));
            } elsif ($condition eq 'I') {
                # Matches IP net/mask.
                my $ipnet = new2 Net::Netmask($value);
                if (defined($ipnet)) {
                    push(@data, $ipnet);
                    my $vi = $#data;
                    push(@code, sprintf('        %s$data->[%d]->match($V->{$data->[%d]}->[0])', $invert ? '!' : '', $vi, $fi));
                } else {
                    push(@code, '0');
                }
            } elsif ($condition eq '<' or $condition eq '>') {
                # Less/greater than.
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
                push(@code, sprintf('        $V->{$data->[%d]}->[0] %s $data->[%d]', $fi, $condition, $vi));
            } elsif ($condition eq 'P') {
                # Value is present -- we've already tested this.
                push(@code, '        1');
            }
        }
        push(@code, '    ) {',
                sprintf('    my ($num, $requests, $interval) = (0, %d, %d);', $requests, $interval));

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
                push(@code, sprintf('$%s->add($V->{$data->[%d]}->[0]) if (defined($V->{$data->[%d]}->[0]));', $condition, $fi, $fi));
            }
        }

        # Construct statement to retrieve number of hits from database.
        my $expr;
        if (@dconds) {
            $expr = '$num = Ratty::dbh()->selectrow_array(q#select count(distinct dhash)'
        } else {
            $expr = '$num = Ratty::dbh()->selectrow_array(q#select count(hit)';
        }
        $expr .= ' from rule_hit where rule_id = ? and hit >= ?';
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
        # matches. >= to take account of this request (that matters because we
        # want to be able to give a hit limit of 0 for any interval to mean
        # that requests should be completely denied).
        push(@code, sprintf('$result ||= %d if ($num >= $requests);', $ruleid),
                    '}');
    }

    push(@code, 
                'return $result;',
            '}'
        );


    my $codejoined = join("\n", @code);

    my $subr;
    {
        # Don't print warnings/errors from the eval'd code, but accumulate them
        # for display.
        local $SIG{__WARN__} = sub () { };
        $subr = eval($codejoined);
    }
    if ($@) {
        # Something went wrong in the eval'd code. That's really bad, so dump
        # a great big error message.
        my ($ln) = ($@ =~ m#line (\d+)#);
        --$ln;
        my $errmsg = "error in generated code: $@\n";
        for (my $i = $ln - 5; $i <= $ln + 5; ++$i) {
            next if ($i < 0 || $i > $#code);
            $errmsg .= sprintf("% 4d%s> %s\n", $i + 1, $i == $ln ? '*' : ' ', $code[$i]);
        }
        die $errmsg;
    }
    
    my $D = \@data;
    
    # Construct hash of seen fields
    my $S = { };
    
    foreach my $row (@{dbh()->selectall_arrayref('
            select scope, field from field_description
                where (select count(*) from field_example
                        where field_example.scope = field_description.scope
                          and field_example.field = field_description.field) >= 3
        ')}) {
        my ($scope, $field) = @$row;
        $S->{$scope}->{$field} = 1;
    }

    # Finish up the transaction.
    dbh()->commit();

    return (
            $generation,
            sub ($$) {
                my ($scope, $vals) = @_;
                return &$subr($scope, $vals, $D, $S);
            }
        );
}

# DESTROY
# Destructor (effectively). Commit any hanging database transactions.
sub DESTROY ($) {
    my ($self) = @_;
    dbh()->commit();
}

=item admin_available_fields SCOPE

I<Instance method.> Returns all the fields Ratty has seen so far in the given
SCOPE, a description of each, and (if available) a few example values of the
field. Structure is an array of [field, description, [example, ...]] tuples.

=cut
sub admin_available_fields ($$) {
    my ($self, $scope) = @_;
    return [
            map {
                [@$_,
                    [@{dbh->selectcol_arrayref('select example from field_example where scope = ? and field = ?', {}, $scope, $_->[0])}]
                ]
            } @{dbh->selectall_arrayref('select field, description from field_description where scope = ?', {}, $scope)}
        ];
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
        $result = dbh()->selectrow_hashref('select id, scope from rule where id = ? for update', {}, $rule->{'rule_id'});
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
        dbh()->do('insert into condition (rule_id, field, condition, value, invert)
                    values (?, ?, ?, ?, ?)',
            {}, $rule->{'rule_id'}, $cond->{'field'}, $cond->{'condition'}, $cond->{'value'}, $cond->{invert} ? 't' : 'f');
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

=item admin_delete_rules SCOPE

I<Instance method.> Deletes all rules in the specified SCOPE. 

=cut
sub admin_delete_rules($$){
    my ($self, $scope) = @_;
    die "All database rules for scope will be deleted so for safety must have name ending '_testharness' or '-testharness'" if (mySociety::Config::get('RATTY_DB_NAME') !~ m/[_-]testharness$/);
    my $return = undef;
    my $rules = dbh()->selectcol_arrayref("select id from rule where scope = ?", {}, $scope);
    my $rule;
    foreach $rule (@$rules){
        $self->admin_delete_rule($scope, $rule);
    }
    return $return;
}

=item admin_get_rules SCOPE

I<Instance method.> Returns array of hashes of data about all rules.

=cut
sub admin_get_rules ($$) {
    my ($self, $scope) = @_;
    
    my $sth = dbh()->prepare('select * from rule where scope = ? order by sequence, note');
    $sth->execute($scope);
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
sub admin_get_rule ($$$) {
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
   
    return [values(%{dbh()->selectall_hashref(
                    'select * from condition where rule_id = ?',
                    'id', {}, $id)})];
}

1;
