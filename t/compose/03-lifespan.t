use strict;
use warnings;
use Test2::V0;
use Future;
use Scalar::Util qw(refaddr);
use FindBin qw($Bin);
use lib "$Bin/lib";
use ComposeTest qw(scope run_scope capture_send channel);
use PAGI::Compose qw(compose);
use PAGI::Routing qw(mount middleware route router);
use PAGI::Test::Client;
use PAGI::Utils qw(as_app);

my $lifespan_router = router(routes => [
    route('/' => as_app(sub { die "request endpoint received lifespan\n" })),
]);

subtest 'plain and Future-backed callbacks receive the exact state and scope' => sub {
    my $state = {};
    my @seen;
    my $app = compose(
        router => $lifespan_router,
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
            router => $lifespan_router,
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
        router => $lifespan_router,
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
        router => $lifespan_router,
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
        router => $lifespan_router,
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
        router => $lifespan_router,
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

subtest 'only the deployed root owns lifespan across Router and Mount boundaries' => sub {
    my ($root_startup, $root_shutdown) = (0, 0);
    my ($nested_startup, $nested_shutdown, $nested_requests) = (0, 0, 0);
    my (@outer_router_types, @inner_router_types, @plain_router_types);
    my $nested = compose(
        router => router(
            routes => [route('/*path' => as_app(sub {
            my ($request_scope, $receive, $send) = @_;
            ++$nested_requests;
            $send->({
                type => 'http.response.start', status => 200, headers => [],
            })->get;
            return $send->({
                type => 'http.response.body', body => 'nested', more => 0,
            });
            }))],
            middleware => [middleware(sub {
                my ($inner) = @_;
                return sub {
                    my ($request_scope) = @_;
                    push @inner_router_types, $request_scope->{type};
                    return $inner->(@_);
                };
            })],
        ),
        lifespan => {
            startup  => sub { ++$nested_startup; return },
            shutdown => sub { ++$nested_shutdown; return },
        },
    );
    my $plain = router(
        routes => [route('/*path' => as_app(sub {
            my ($request_scope, $receive, $send) = @_;
            $send->({ type => 'http.response.start', status => 204, headers => [] })->get;
            return $send->({ type => 'http.response.body', body => '', more => 0 });
        }))],
        middleware => [middleware(sub {
            my ($inner) = @_;
            return sub {
                my ($request_scope) = @_;
                push @plain_router_types, $request_scope->{type};
                return $inner->(@_);
            };
        })],
    );
    my $routing = router(
        routes => [
            mount('/nested', app => $nested),
            mount('/plain', app => $plain),
        ],
        middleware => [middleware(sub {
            my ($inner) = @_;
            return sub {
                my ($request_scope) = @_;
                push @outer_router_types, $request_scope->{type};
                return $inner->(@_);
            };
        })],
    );
    my $state = {};
    my $app = compose(
        router => $routing,
        lifespan => {
            startup => sub {
                my ($callback_state) = @_;
                ++$root_startup;
                $callback_state->{started} = 1;
                return;
            },
            shutdown => sub {
                my ($callback_state) = @_;
                ++$root_shutdown;
                $callback_state->{stopped} = 1;
                return;
            },
        },
    )->to_app;

    my $events = run_scope($app, scope(type => 'lifespan', state => $state), [
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    ]);
    is($events, [
        { type => 'lifespan.startup.complete' },
        { type => 'lifespan.shutdown.complete' },
    ], 'root completes one startup and shutdown cycle');
    is([$root_startup, $root_shutdown], [1, 1],
        'root callbacks run exactly once');
    is($state, { started => 1, stopped => 1 },
        'root callbacks update the server-owned state');
    is(\@outer_router_types, [], 'the outer Router never receives lifespan');
    is(\@inner_router_types, [], 'the mounted inner Router never receives lifespan');
    is(\@plain_router_types, [], 'the mounted plain Router never receives lifespan');
    is([$nested_startup, $nested_shutdown], [0, 0],
        'mounted Compose callbacks do not run during root lifespan');

    my $response = run_scope($app, scope(path => '/nested/child'));
    is($response->[0]{status}, 200, 'mounted Compose remains a request app');
    is($response->[1]{body}, 'nested', 'mounted request reaches its target');
    is($nested_requests, 1, 'mounted target runs once for the request');
    is(\@outer_router_types, ['http'],
        'outer Router receives the delegated request scope');
    is(\@inner_router_types, ['http'],
        'mounted inner Router receives its HTTP request only');
    is([$nested_startup, $nested_shutdown], [0, 0],
        'request dispatch does not synthesize nested lifespan');

    my $plain_response = run_scope($app, scope(path => '/plain/child'));
    is($plain_response->[0]{status}, 204, 'mounted plain Router receives HTTP');
    is(\@plain_router_types, ['http'],
        'mounted plain Router receives HTTP but no lifespan');
};

subtest 'a bare Router rejects strict root lifespan while Compose completes it' => sub {
    my $bare = router(routes => [])->to_app;
    my $client = PAGI::Test::Client->new(app => $bare, lifespan => 1);
    like dies { $client->start },
        qr/lifespan.*returned without sending.*startup/s,
        'bare Router is not a strict-lifespan root';

    my $root = compose(router => router(routes => []))->to_app;
    my $root_client = PAGI::Test::Client->new(app => $root, lifespan => 1);
    ok(lives { $root_client->start; $root_client->stop },
        'Compose owns a callback-free root lifespan');
};

done_testing;
