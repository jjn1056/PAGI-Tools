use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);
use FindBin qw($Bin);
use lib "$Bin/lib";
use ComposeTest qw(scope run_scope);
use PAGI::Compose qw(compose);
use PAGI::Routing qw(route middleware);

sub tracing_middleware {
    my ($name, $trace) = @_;
    return middleware(sub {
        my ($inner) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            push @$trace, "$name before " . ($scope->{type} // '');
            my $wrapped_send = sub {
                my ($event) = @_;
                push @$trace, "$name send " . ($event->{type} // '');
                return $send->($event);
            };
            my $returned = $inner->($scope, $receive, $wrapped_send);
            await Future->wrap($returned);
            push @$trace, "$name after " . ($scope->{type} // '');
            return;
        };
    });
}

subtest 'first listed middleware is outermost for requests and lifespan' => sub {
    my @trace;
    my $target = sub {
        my ($scope, $receive, $send) = @_;
        push @trace, 'target ' . $scope->{type};
        return $send->({ type => 'example.response' });
    };
    my $app = compose(
        app => $target,
        middleware => [
            tracing_middleware('outer', \@trace),
            tracing_middleware('inner', \@trace),
        ],
    )->to_app;

    run_scope($app, scope(type => 'example'));
    is(\@trace, [
        'outer before example', 'inner before example', 'target example',
        'inner send example.response', 'outer send example.response',
        'inner after example', 'outer after example',
    ], 'request call and send order are inverse');

    @trace = ();
    run_scope($app, scope(type => 'lifespan'), [
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    ]);
    is(\@trace, [
        'outer before lifespan', 'inner before lifespan',
        'inner send lifespan.startup.complete', 'outer send lifespan.startup.complete',
        'inner send lifespan.shutdown.complete', 'outer send lifespan.shutdown.complete',
        'inner after lifespan', 'outer after lifespan',
    ], 'same middleware stack surrounds the complete lifecycle loop');
};

subtest 'application middleware sees every delegated protocol and generated routing outcomes' => sub {
    my @scope_types;
    my @target_types;
    my $observer = middleware(sub {
        my ($inner) = @_;
        return sub {
            my ($scope, $receive, $send) = @_;
            push @scope_types, $scope->{type};
            return $inner->($scope, $receive, $send);
        };
    });
    my $app = compose(
        app => sub { push @target_types, $_[0]->{type}; return },
        middleware => [$observer],
    )->to_app;
    run_scope($app, scope(type => $_)) for qw(http websocket sse example.extension);
    is(\@scope_types, [qw(http websocket sse example.extension)],
        'one application wrapper sees every delegated scope type');
    is(\@target_types, \@scope_types, 'middleware passes every type to the target');

    my @statuses;
    my $outcome_observer = middleware(sub {
        my ($inner) = @_;
        return sub {
            my ($scope, $receive, $send) = @_;
            my $wrapped_send = sub {
                my ($event) = @_;
                push @statuses, $event->{status}
                    if ($event->{type} // '') eq 'http.response.start';
                return $send->($event);
            };
            return $inner->($scope, $receive, $wrapped_send);
        };
    });
    my $routing_app = compose(
        routes => [route('/present' => sub { return $_[0]->text('present') })],
        middleware => [$outcome_observer],
    )->to_app;
    run_scope($routing_app, scope(type => 'http', path => '/missing'));
    is(\@statuses, [404], 'application middleware sees router-generated 404');
};

subtest 'ordinary shallow cloning preserves state proof and changes visible scope' => sub {
    my $state = {};
    my @seen;
    my $clone = middleware(sub {
        my ($inner) = @_;
        return sub {
            my ($scope, $receive, $send) = @_;
            return $inner->({ %$scope, worker => 'wrapped' }, $receive, $send);
        };
    });
    my $app = compose(
        app => sub {
            my ($scope) = @_;
            push @seen, ['target', $scope->{worker}];
            return;
        },
        middleware => [$clone],
        lifespan => {
            startup => sub {
                my ($callback_state, $callback_scope) = @_;
                push @seen, [
                    'startup', $callback_scope->{worker},
                    refaddr($callback_state),
                ];
                return;
            },
        },
    )->to_app;
    run_scope($app, scope(type => 'example.extension'));
    my $events = run_scope($app, scope(type => 'lifespan', state => $state), [
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    ]);
    is(\@seen, [
        ['target', 'wrapped'],
        ['startup', 'wrapped', refaddr($state)],
    ], 'target and callback see the transformed shallow clone');
    is($events->[0], { type => 'lifespan.startup.complete' },
        'preserved proof accepts the original state');
};

my @tampering = (
    ['fabricated missing state',
        sub { my ($scope) = @_; return { %$scope, state => {} } },
        scope(type => 'lifespan')],
    ['replaced original state',
        sub { my ($scope) = @_; return { %$scope, state => {} } },
        scope(type => 'lifespan', state => {})],
    ['dropped provenance marker',
        sub {
            my ($scope) = @_;
            return { type => $scope->{type}, state => $scope->{state} };
        },
        scope(type => 'lifespan', state => {})],
);

for my $case (@tampering) {
    my ($label, $transform, $initial_scope) = @$case;
    my $callback_count = 0;
    my $descriptor = middleware(sub {
        my ($inner) = @_;
        return sub {
            my ($scope, $receive, $send) = @_;
            return $inner->($transform->($scope), $receive, $send);
        };
    });
    my $app = compose(
        app => sub { die "target received lifespan\n" },
        middleware => [$descriptor],
        lifespan => { startup => sub { ++$callback_count } },
    )->to_app;
    my $events = run_scope($app, $initial_scope, [
        { type => 'lifespan.startup' },
    ]);
    is($events, [{
        type => 'lifespan.startup.failed',
        message => 'PAGI::Compose lifespan requires server state support',
    }], "$label is rejected");
    is($callback_count, 0, "$label does not invoke callbacks");
}

subtest 'short-circuit middleware owns lifespan completely' => sub {
    my $callback_count = 0;
    my $owner = middleware(sub {
        my ($inner) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            my $startup = await Future->wrap($receive->());
            await Future->wrap($send->({ type => 'lifespan.startup.complete' }));
            my $shutdown = await Future->wrap($receive->());
            await Future->wrap($send->({ type => 'lifespan.shutdown.complete' }));
        };
    });
    my $app = compose(
        app => sub { die "target received lifespan\n" },
        middleware => [$owner],
        lifespan => { startup => sub { ++$callback_count } },
    )->to_app;
    my $events = run_scope($app, scope(type => 'lifespan'), [
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    ]);
    is($events, [
        { type => 'lifespan.startup.complete' },
        { type => 'lifespan.shutdown.complete' },
    ], 'owner emits its own lifecycle result');
    is($callback_count, 0, 'inner lifecycle never runs');
};

subtest 'middleware exception is not converted into startup.failed' => sub {
    my $throwing = middleware(sub {
        return sub { die "middleware exploded\n" };
    });
    my $app = compose(
        app => sub { die "target received lifespan\n" },
        middleware => [$throwing],
        lifespan => { startup => sub { return } },
    )->to_app;
    my @events;
    like(dies {
        $app->(
            scope(type => 'lifespan', state => {}),
            sub { return Future->done({ type => 'lifespan.startup' }) },
            sub { push @events, $_[0]; return Future->done },
        )->get;
    }, qr/middleware exploded/, 'middleware error propagates');
    is(\@events, [], 'Compose emits no callback failure event');
};

subtest 'each to_app builds fresh middleware instances' => sub {
    my $factory_calls = 0;
    my $descriptor = middleware(sub {
        my ($inner) = @_;
        ++$factory_calls;
        return $inner;
    });
    my $composition = compose(app => sub { return }, middleware => [$descriptor]);
    my $one = $composition->to_app;
    my $two = $composition->to_app;
    is($factory_calls, 2, 'factory runs once for each compiled graph');

    my $throwing = compose(
        app => sub { return },
        middleware => [middleware(sub { die "factory exploded\n" })],
    );
    like(dies { $throwing->to_app }, qr/factory exploded/,
        'factory failure aborts to_app synchronously');

    my $invalid = compose(
        app => sub { return },
        middleware => [middleware(sub { return 'not an app' })],
    );
    like(dies { $invalid->to_app }, qr/must return PAGI app coderef/,
        'invalid wrapper result aborts compilation');
};

done_testing;
