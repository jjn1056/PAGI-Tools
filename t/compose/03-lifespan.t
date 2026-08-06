use strict;
use warnings;
use Test2::V0;
use Future;
use Scalar::Util qw(refaddr);
use FindBin qw($Bin);
use lib "$Bin/lib";
use ComposeTest qw(scope run_scope capture_send channel);
use PAGI::Compose qw(compose);

my $never_target = sub { die "request target received lifespan\n" };

subtest 'plain and Future-backed callbacks receive the exact state and scope' => sub {
    my $state = {};
    my @seen;
    my $app = compose(
        app => $never_target,
        lifespan => {
            startup => sub {
                my ($callback_state, $callback_scope) = @_;
                push @seen, ['startup', refaddr($callback_state), refaddr($callback_scope)];
                $callback_state->{ready} = 1;
                return;
            },
            shutdown => sub {
                my ($callback_state, $callback_scope) = @_;
                push @seen, ['shutdown', refaddr($callback_state), refaddr($callback_scope)];
                return Future->done('ignored callback value');
            },
        },
    )->to_app;
    my $lifespan_scope = scope(type => 'lifespan', state => $state);
    my $events = run_scope($app, $lifespan_scope, [
        { type => 'ignored.extension' },
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    ]);

    is($events, [
        { type => 'lifespan.startup.complete' },
        { type => 'lifespan.shutdown.complete' },
    ], 'unknown events are ignored and both phases complete');
    is($state, { ready => 1 }, 'callbacks mutate the server hash directly');
    is([map { [$_->[0], $_->[1]] } @seen], [
        ['startup', refaddr($state)],
        ['shutdown', refaddr($state)],
    ], 'both callbacks receive the original state identity');
    is($seen[0][2], $seen[1][2], 'both callbacks receive one middleware-facing scope identity');
    ok(!(grep { index($_, "\0") == 0 } keys %$lifespan_scope),
        'private provenance does not mutate the server-owned scope');
};

subtest 'configured lifespan fails startup without valid original server state' => sub {
    my @cases = (
        ['missing', {}],
        ['array', { state => [] }],
        ['blessed hash', { state => bless({}, 'Local::BlessedState') }],
    );
    for my $case (@cases) {
        my ($label, $changes) = @$case;
        my $called = 0;
        my $app = compose(
            app => $never_target,
            lifespan => {
                startup => sub { ++$called },
                shutdown => sub { ++$called },
            },
        )->to_app;
        my $events = run_scope($app, scope(type => 'lifespan', %$changes), [
            { type => 'lifespan.startup' },
        ]);
        is($events, [{
            type => 'lifespan.startup.failed',
            message => 'PAGI::Compose lifespan requires server state support',
        }], "$label state fails explicitly");
        is($called, 0, "$label state runs neither callback");
    }
};

subtest 'startup failure is reported once and prevents shutdown' => sub {
    my $shutdown = 0;
    my $app = compose(
        app => $never_target,
        lifespan => {
            startup => sub { die "startup exploded\n" },
            shutdown => sub { ++$shutdown },
        },
    )->to_app;
    my $events = run_scope($app, scope(type => 'lifespan', state => {}), [
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    ]);
    is(scalar @$events, 1, 'startup failure emits no later completion');
    is($events->[0]{type}, 'lifespan.startup.failed', 'startup uses startup.failed');
    like($events->[0]{message}, qr/startup exploded/, 'startup exception text is retained');
    is($shutdown, 0, 'shutdown callback does not run after startup failure');
};

subtest 'failed shutdown Future becomes shutdown.failed' => sub {
    my $app = compose(
        app => $never_target,
        lifespan => { shutdown => sub { return Future->fail("shutdown exploded\n") } },
    )->to_app;
    my $events = run_scope($app, scope(type => 'lifespan', state => {}), [
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    ]);
    is($events->[0], { type => 'lifespan.startup.complete' }, 'startup without callback completes');
    is($events->[1]{type}, 'lifespan.shutdown.failed', 'shutdown uses shutdown.failed');
    like($events->[1]{message}, qr/shutdown exploded/, 'failed Future text is retained');
};

subtest 'receive and send failures propagate without a compensating event' => sub {
    my $app = compose(
        app => $never_target,
        lifespan => { startup => sub { return } },
    )->to_app;
    my ($capture, $events) = capture_send();
    like(dies {
        $app->(
            scope(type => 'lifespan', state => {}),
            sub { return Future->fail("receive channel failed\n") },
            $capture,
        )->get;
    }, qr/receive channel failed/, 'receive failure propagates');
    is($events, [], 'receive failure produces no response');

    my $receive_count = 0;
    my $send_count = 0;
    like(dies {
        $app->(
            scope(type => 'lifespan', state => {}),
            sub {
                ++$receive_count;
                return Future->done({ type => 'lifespan.startup' });
            },
            sub {
                ++$send_count;
                return Future->fail("send channel failed\n");
            },
        )->get;
    }, qr/send channel failed/, 'send failure propagates');
    is($receive_count, 1, 'driver does not read again after failed send');
    is($send_count, 1, 'driver does not try a second send');
};

subtest 'callback completion and lifecycle phase are awaited per scope' => sub {
    my %startup_future = (one => Future->new, two => Future->new);
    my $app = compose(
        app => $never_target,
        lifespan => {
            startup => sub {
                my ($state) = @_;
                return $startup_future{$state->{id}};
            },
        },
    )->to_app;

    my @runs;
    for my $id (qw(one two)) {
        my ($receive, $push) = channel();
        my ($send, $events) = capture_send();
        my $future = $app->(
            scope(type => 'lifespan', state => { id => $id }),
            $receive,
            $send,
        );
        $push->({ type => 'lifespan.startup' });
        push @runs, { id => $id, push => $push, future => $future, events => $events };
    }

    ok(!$_->{future}->is_ready, "$_->{id} waits for its startup Future") for @runs;
    $startup_future{two}->done;
    is($runs[1]{events}, [{ type => 'lifespan.startup.complete' }], 'second scope advances independently');
    is($runs[0]{events}, [], 'first scope remains parked');
    $startup_future{one}->done;
    $runs[0]{push}->({ type => 'lifespan.shutdown' });
    $runs[1]{push}->({ type => 'lifespan.shutdown' });
    $_->{future}->get for @runs;
    is($_->{events}[-1], { type => 'lifespan.shutdown.complete' },
        "$_->{id} shuts down independently") for @runs;
};

done_testing;
