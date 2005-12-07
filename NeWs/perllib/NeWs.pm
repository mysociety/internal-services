#!/usr/bin/perl
#
# NeWs.pm:
# Infrastructure for the Newspaper Whereabouts Service.
#
# Copyright (c) 2005 UK Citizens Online Democracy. All rights reserved.
# Email: chris@mysociety.org; WWW: http://www.mysociety.org/
#
# $Id: NeWs.pm,v 1.1 2005-12-07 22:18:33 chris Exp $
#

package NeWs;

use strict;

package NeWs::Paper;

# Object representing an individual newspaper.

use strict;
use fields qw(nsid name editor address postcode website isweekly isevening isfree email fax lat lon coverage);

use IO::String;
use RABX;

use mySociety::MaPit;
use mySociety::Util;

mySociety::Util::create_accessor_methods();

# new FIELD VALUE ...
# Constructor.
sub new ($%) {
    my ($class, %f) = @_;
    my $self = fields::new($class);
    %$self= %f;
    return bless($self, $class);
}

# publish
# Publish the record to the database as the current record for this newspaper.
sub publish ($) {
    my $self = shift;
    dbh()->do('delete from coverage where nsid = ?', {}, $self->nsid());
    dbh()->do('delete from newspaper where nsid = ?', {}, $self->nsid());
    return if ($self->deleted());
    my $stmt = "insert into newspaper ("
                    . join(", ", sort grep { $_ ne 'circulation' } keys %$self)
                    . ") values ("
                    . join(", ", map { dbh()->quote($self->{$_}) } sort grep { $_ ne 'circulation' } keys %$self)
                    . ")";
    dbh()->do($stmt);
    foreach (@{$self->{coverage}) {
        dbh()->do('
                insert into coverage (
                    nsid, name, population, circulation, lat, lon
                ) values (?, ?, ?, ?, ?, ?)',
                {},
                $self->nsid(), $_->name(), $_->population(),
                    $_->circulation(), $_->lat(), $_->lon());
    }
}

# save EDITOR
# Save a copy of the record in the database edit history, as from EDITOR; if
# EDITOR is undef, this means "changes from the scraper".
sub save_db ($$) {
    my ($self, $editor) = @_;

    my $buf = '';
    my $h = new IO::String($buf);
    RABX::wire_wr($self, $h);
    
    my $s = dbh()->prepare('insert into newspaper_edit_history (nsid, source, data, isdeleted) values (?, ?, ?, ?)');
    $s->bind_param(1, $self->nsid());
    $s->bind_param(2, $editor);
    $s->bind_param(3, $buf, { pg_type => DBD::Pg::PG_BYTEA });
    $s->bind_param(4, $self->deleted() ? 't' : 'f');
    $s->execute();
}

sub diff_one ($$) {
    my ($a, $b) = @_;
    if (defined($a) && !defined($b)) {
        return -1;
    } elsif (!defined($a) && defined($b)) {
        return +1;
    } elsif (!defined($a) && !defined($b)) {
        return undef;   # shouldn't happen
    } elsif ($a ne $b) {
        return 1;
    } else {
        return undef;
    }
}

# diff A B
# Return a reference to a hash indicating differences between papers A and B.
# For each field, and each named circulation entry, the hash value is -1 if it
# is present in A but not in B, +1 vice versa, or 0 if it is present in both
# but different.
sub diff ($$) {
    my ($A, $B) = @_;
    my %r = ( );
    foreach (grep { $_ ne 'circulation' } keys %$A) {
        my $d = diff_one($A->{$_}, $B->{$_});
        $r{$_} = $d if (defined($d));
    }

    $r{coverage} = { };
 
    my %Acirc = map { $_[0] => [@{$_}[1 .. 3]] } @{$A->coverage()};
    my %Bcirc = map { $_[0] => [@{$_}[1 .. 3]] } @{$A->coverage()};

    foreach (keys(%Acirc), keys(%Bcirc)) {
        my $d = diff_one($Acirc->{$_}, $Bcirc->{$_});
        $r{coverage}->{$_} = $d if (defined($d));
    }
    
    return \%r;
}

package NeWs::Paper::Coverage;

# Object representing the circulation of an individual newspaper in an
# individual location.

use strict;
use fields qw(name households circulation lat lon);

mySociety::Util::create_accessor_methods();

1;
