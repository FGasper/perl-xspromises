#!/usr/bin/perl

package t::unhandled_rejection;

use strict;
use warnings;

use Test::More;
use Test::Deep;
use Test::FailWarnings;

use Promise::XS;

# should not warn because catch() silences
{
    my $d = Promise::XS::deferred();

    my $p = $d->promise()->catch( sub { } );

    $d->reject("nonono");
}

{
    my @w;
    local $SIG{'__WARN__'} = sub { push @w, @_ };

    {
        my $d = Promise::XS::deferred();

        my $p = $d->promise();

        $p->then( sub { die "nonono" } );

        $d->resolve(234);
    }

    cmp_deeply(
        \@w,
        [ re( qr<nonono> ) ],
        'die() in then() triggers warning when promise is already GCed',
    );
}

# should warn because finally() rejects
{
    my @w;
    local $SIG{'__WARN__'} = sub { push @w, @_ };

    {
        my $d = Promise::XS::deferred();

        my $p = $d->promise()->finally( sub { } );

        $d->reject("nonono");
    }

    cmp_deeply(
        \@w,
        [ re( qr<nonono> ) ],
        'rejection with no catch triggers warning',
    );
}

# should warn because finally() rejects
{
    my @w;
    local $SIG{'__WARN__'} = sub { push @w, @_ };

    {
        my $d = Promise::XS::deferred();

        my $p = $d->promise();

        my $f = $p->finally( sub { } );

        $p->catch( sub { } );

        $d->reject("nonono");
    }

    cmp_deeply(
        \@w,
        [ re( qr<nonono> ) ],
        'rejected finally is uncaught',
    );
}

# should warn because finally() rejection is caught
{
    my @w;
    local $SIG{'__WARN__'} = sub { push @w, @_ };

    {
        my $d = Promise::XS::deferred();

        my $p = $d->promise();

        my $f = $p->finally( sub { } )->catch( sub { } );

        $p->catch( sub { } );

        $d->reject("nonono");
    }

    cmp_deeply(
        \@w,
        [],
        'when finally passthrough rejection is caught',
    );
}

#----------------------------------------------------------------------

{
    my $d = Promise::XS::deferred();

    my $p = $d->resolve(123)->promise()->then( sub {
        my ($value) = @_;

        return Promise::XS::rejected( { message => 'oh my god', value => $value } );
    })->catch(sub {
        my ($reason) = @_;
        return $reason;
    });

    my $got;

    $p->then( sub { $got = shift } );

    is_deeply $got, { message => 'oh my god', value => 123 }, 'got expected';
}

#----------------------------------------------------------------------

{
    my $d = Promise::XS::deferred();

    my $p = $d->resolve(123)->promise()->then( sub {
        my ($value) = @_;

        return bless [], 'ForeignRejectedPromise';
    })->catch(sub {
        my ($reason) = @_;
        return $reason;
    });

    my $got;

    $p->then( sub { $got = shift } );

    is_deeply $got, 'ForeignRejectedPromise', 'got expected from foreign rejected';
}

#----------------------------------------------------------------------

done_testing();

#----------------------------------------------------------------------

package ForeignRejectedPromise;

sub then {
    my ($self, $on_res, $on_rej) = @_;

    $on_rej->(ref $self);

    return $self;
}

1;
