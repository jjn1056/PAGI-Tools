#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use PAGI::Middleware::Helpers qw(clone_scope wrap_send wrap_receive);

subtest 'exports are explicit' => sub {
    package NoHelperImports {
        use PAGI::Middleware::Helpers;
    }

    ok(!NoHelperImports->can('clone_scope'), 'clone_scope is not exported by default');
    ok(!NoHelperImports->can('wrap_send'), 'wrap_send is not exported by default');
    ok(!NoHelperImports->can('wrap_receive'), 'wrap_receive is not exported by default');
    ok(__PACKAGE__->can('clone_scope'), 'clone_scope can be imported explicitly');
    ok(__PACKAGE__->can('wrap_send'), 'wrap_send can be imported explicitly');
    ok(__PACKAGE__->can('wrap_receive'), 'wrap_receive can be imported explicitly');
};

subtest 'clone_scope makes a defensive shallow top-level copy' => sub {
    my $shared = { count => 1 };
    my $scope = { type => 'http', shared => $shared, replaced => 'outer' };
    my $changes = { added => 1, replaced => 'inner' };

    my $clone = clone_scope($scope, $changes);

    is($clone, {
        type     => 'http',
        shared   => $shared,
        replaced => 'inner',
        added    => 1,
    }, 'changes override top-level scope keys');
    isnt($clone, $scope, 'scope hash itself is copied');
    isnt($clone, $changes, 'changes hash itself is not reused');
    is($clone->{shared}, $shared, 'referenced values remain shared');

    $clone->{new_key} = 1;
    ok(!exists $scope->{new_key}, 'editing clone does not add keys to original');
};

subtest 'helpers validate arguments' => sub {
    like(dies { clone_scope([], {}) }, qr/clone_scope.*scope.*hash reference/i,
        'clone_scope rejects a non-hash scope');
    like(dies { clone_scope({}, []) }, qr/clone_scope.*changes.*hash reference/i,
        'clone_scope rejects non-hash changes');
    like(dies { wrap_send([], sub { }) }, qr/wrap_send.*send.*coderef/i,
        'wrap_send rejects a non-coderef downstream');
    like(dies { wrap_send(sub { }, []) }, qr/wrap_send.*interceptor.*coderef/i,
        'wrap_send rejects a non-coderef interceptor');
    like(dies { wrap_receive([], sub { }) }, qr/wrap_receive.*receive.*coderef/i,
        'wrap_receive rejects a non-coderef downstream');
    like(dies { wrap_receive(sub { }, []) }, qr/wrap_receive.*interceptor.*coderef/i,
        'wrap_receive rejects a non-coderef interceptor');
};

subtest 'wrappers are inert until their callbacks run' => sub {
    my ($send_calls, $send_intercepts, $receive_calls, $receive_intercepts) = (0, 0, 0, 0);
    my $wrapped_send = wrap_send(
        sub { ++$send_calls; Future->done },
        sub { ++$send_intercepts; Future->done },
    );
    my $wrapped_receive = wrap_receive(
        sub { ++$receive_calls; Future->done({ type => 'http.request' }) },
        sub { ++$receive_intercepts; Future->done({ type => 'http.request' }) },
    );

    is(ref($wrapped_send), 'CODE', 'wrap_send constructs a callback');
    is(ref($wrapped_receive), 'CODE', 'wrap_receive constructs a callback');
    is([$send_calls, $send_intercepts, $receive_calls, $receive_intercepts], [0, 0, 0, 0],
        'construction performs no downstream I/O or interception');
};

subtest 'wrap_send leaves replacement, drop, and expansion to the interceptor' => sub {
    my @sent;
    my $send = sub {
        my ($event) = @_;
        push @sent, $event;
        return Future->done;
    };
    my $wrapped = wrap_send($send, async sub {
        my ($event, $downstream) = @_;
        return if $event->{type} eq 'app.drop';
        if ($event->{type} eq 'app.expand') {
            await $downstream->({ type => 'app.first' });
            await $downstream->({ type => 'app.second' });
            return;
        }
        await $downstream->({ %$event, inspected => 1 });
    });

    $wrapped->({ type => 'app.replace' })->get;
    $wrapped->({ type => 'app.drop' })->get;
    $wrapped->({ type => 'app.expand' })->get;

    is(
        \@sent,
        [
            { type => 'app.replace', inspected => 1 },
            { type => 'app.first' },
            { type => 'app.second' },
        ],
        'interceptor controls every downstream send',
    );
};

subtest 'wrap_receive can repeatedly pull until an accepted event' => sub {
    my @events = (
        { type => 'app.ignore', value => 1 },
        { type => 'app.ignore', value => 2 },
        { type => 'app.accept', value => 3 },
        { type => 'app.accept', value => 4 },
    );
    my $pulls = 0;
    my $receive = sub {
        ++$pulls;
        return Future->done(shift @events);
    };
    my $wrapped = wrap_receive($receive, async sub {
        my ($downstream) = @_;
        while (1) {
            my $event = await $downstream->();
            return $event unless $event->{type} eq 'app.ignore';
        }
    });

    is($wrapped->()->get, { type => 'app.accept', value => 3 },
        'first call filters repeated unwanted events');
    is($wrapped->()->get, { type => 'app.accept', value => 4 },
        'wrapped receive can be called repeatedly');
    is($pulls, 4, 'downstream is pulled only by interceptor decisions');
};

subtest 'immediate and Future interceptor results are normalized' => sub {
    my $send_immediate = wrap_send(sub { die 'unused send' }, sub { return 'sent-now' });
    my $send_future = wrap_send(sub { die 'unused send' }, sub { return Future->done('sent-later') });
    my $receive_immediate = wrap_receive(sub { die 'unused receive' }, sub { return { value => 'now' } });
    my $receive_future = wrap_receive(sub { die 'unused receive' }, sub { return Future->done({ value => 'later' }) });

    is($send_immediate->({ type => 'app.test' })->get, 'sent-now',
        'wrap_send preserves an immediate scalar result');
    is($send_future->({ type => 'app.test' })->get, 'sent-later',
        'wrap_send awaits a Future result');
    is($receive_immediate->()->get, { value => 'now' },
        'wrap_receive preserves an immediate scalar result');
    is($receive_future->()->get, { value => 'later' },
        'wrap_receive awaits a Future result');
};

subtest 'synchronous interceptor exceptions propagate through callbacks' => sub {
    my $send = wrap_send(sub { Future->done }, sub { die "send exploded\n" });
    my $receive = wrap_receive(sub { Future->done }, sub { die "receive exploded\n" });

    like(dies { $send->({ type => 'app.test' })->get }, qr/send exploded/,
        'wrap_send propagates an interceptor exception');
    like(dies { $receive->()->get }, qr/receive exploded/,
        'wrap_receive propagates an interceptor exception');
};

done_testing;
