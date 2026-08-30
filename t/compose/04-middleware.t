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
use PAGI::Pages;
use PAGI::Response::Text ();
use PAGI::Routing qw(route middleware router);

{
    package ComposeDirectMiddleware;
    sub new { return bless { wraps => 0 }, $_[0] }
    sub wraps { return $_[0]->{wraps} }
    sub wrap {
        my ($self, $inner) = @_;
        ++$self->{wraps};
        return $inner;
    }
}

{
    package ComposeOwnedPages;
    our @ISA = ('PAGI::Pages');
    sub render_text {
        my ($self, $page) = @_;
        return "owned:$page->{status}:$page->{title}\n";
    }
}

sub tracing_factory {
    my ($name, $trace) = @_;
    return sub {
        my ($inner) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            push @$trace, "$name before " . ($scope->{type} // '');
            my $wrapped_send = sub {
                my ($event) = @_;
                push @$trace, "$name send " . ($event->{type} // '');
                return $send->($event);
            };
            await Future->wrap($inner->($scope, $receive, $wrapped_send));
            push @$trace, "$name after " . ($scope->{type} // '');
            return;
        };
    };
}

sub entry_wrapper {
    my ($name, $trace, $app) = @_;
    return async sub {
        push @$trace, $name;
        await Future->wrap($app->(@_));
        return;
    };
}

subtest 'HTTP enters the exact root safety and declared wrapper order' => sub {
    require PAGI::Compose::ResponseGuard;
    require PAGI::Middleware::ErrorHandler;
    require PAGI::Routing::HeadBoundary;

    my @trace;
    my %wraps;
    my $head_prepare = \&PAGI::Routing::HeadBoundary::prepare;
    my $error_wrap = \&PAGI::Middleware::ErrorHandler::wrap;
    my $guard_wrap = \&PAGI::Compose::ResponseGuard::wrap;

    no warnings qw(redefine once);
    local *PAGI::Routing::HeadBoundary::prepare = sub {
        push @trace, 'HEAD';
        return $head_prepare->(@_);
    };
    local *PAGI::Middleware::ErrorHandler::wrap = sub {
        ++$wraps{ErrorHandler};
        my $wrapped = $error_wrap->(@_);
        return entry_wrapper('ErrorHandler', \@trace, $wrapped);
    };
    local *PAGI::Compose::ResponseGuard::wrap = sub {
        ++$wraps{ResponseGuard};
        my $wrapped = $guard_wrap->(@_);
        return entry_wrapper('ResponseGuard', \@trace, $wrapped);
    };

    my $author_entry = sub {
        my ($name) = @_;
        return sub {
            my ($inner) = @_;
            ++$wraps{$name};
            return entry_wrapper($name, \@trace, $inner);
        };
    };
    my $app = compose(
        app => sub {
            my ($scope, $receive, $send) = @_;
            push @trace, 'target';
            $send->({
                type => 'http.response.start', status => 200, headers => [],
            })->get;
            return $send->({
                type => 'http.response.body', body => 'ok', more => 0,
            });
        },
        middleware => [
            $author_entry->('author outer'),
            $author_entry->('author inner'),
        ],
    )->to_app;
    is(\%wraps, {
        ErrorHandler => 1,
        ResponseGuard => 1,
        'author outer' => 1,
        'author inner' => 1,
    }, 'each safety and author wrapper compiles exactly once');
    run_scope($app, scope(method => 'HEAD'));
    is(\@trace, [
        'HEAD',
        'ErrorHandler',
        'ResponseGuard',
        'author outer',
        'author inner',
        'target',
    ], 'HEAD, ErrorHandler, guard, authors, and target enter in exact order');
    is(\%wraps, {
        ErrorHandler => 1,
        ResponseGuard => 1,
        'author outer' => 1,
        'author inner' => 1,
    }, 'requests do not rebuild the compiled wrappers');
};

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
            tracing_factory('outer', \@trace),
            middleware(tracing_factory('inner', \@trace)),
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

subtest 'application middleware sees delegated protocols and Router outcomes' => sub {
    my @scope_types;
    my @target_types;
    my $observer = sub {
        my ($inner) = @_;
        return sub {
            my ($scope, $receive, $send) = @_;
            push @scope_types, $scope->{type};
            return $inner->($scope, $receive, $send);
        };
    };
    my $app = compose(
        app => sub {
            my ($scope, $receive, $send) = @_;
            push @target_types, $scope->{type};
            return unless $scope->{type} eq 'http';
            $send->({
                type => 'http.response.start', status => 204, headers => [],
            })->get;
            return $send->({
                type => 'http.response.body', body => '', more => 0,
            });
        },
        middleware => [$observer],
    )->to_app;
    run_scope($app, scope(type => $_)) for qw(http websocket sse example.extension);
    is(\@scope_types, [qw(http websocket sse example.extension)],
        'one application wrapper sees every delegated scope type');
    is(\@target_types, \@scope_types, 'middleware passes every type to the target');

    my @statuses;
    my $outcome_observer = sub {
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
    };
    my $routing_app = compose(
        routes => [route('/present' => sub {
            return PAGI::Response::Text->new('present');
        })],
        middleware => [$outcome_observer],
    )->to_app;
    my $events = run_scope($routing_app, scope(type => 'http', path => '/missing'));
    is(\@statuses, [404],
        'the Router-owned 404 travels outward through author middleware');
    is($events->[0]{status}, 404, 'the Router emits its own default 404');
};

subtest 'Router-owned 404 and 405 cross the complete author stack' => sub {
    my @trace;
    my $app = compose(
        routes => [
            route('/items' => sub {
                return PAGI::Response::Text->new('item');
            }, methods => 'GET'),
        ],
        middleware => [
            tracing_factory('author outer', \@trace),
            tracing_factory('author inner', \@trace),
        ],
    )->to_app;

    for my $case (
        ['404', scope(path => '/missing'), 404],
        ['405', scope(path => '/items', method => 'DELETE'), 405],
    ) {
        my ($label, $request_scope, $status) = @$case;
        @trace = ();
        my $events = run_scope($app, $request_scope);
        is(\@trace, [
            'author outer before http',
            'author inner before http',
            'author inner send http.response.start',
            'author outer send http.response.start',
            'author inner send http.response.body',
            'author outer send http.response.body',
            'author inner after http',
            'author outer after http',
        ], "Router $label unwinds through both author wrappers");
        is($events->[0]{status}, $status, "Router owns the $label response");
    }
};

subtest 'author ErrorHandler response crosses only earlier middleware' => sub {
    local $ENV{PAGI_ENV} = 'production';
    my @trace;
    my $app = compose(
        routes => [route('/explode' => sub {
            push @trace, 'target throw';
            die "author target failed\n";
        })],
        middleware => [
            tracing_factory('author outer', \@trace),
            middleware('ErrorHandler',
                on_error => sub {
                    push @trace, 'author ErrorHandler report';
                    return;
                },
                handler => sub {
                    my ($request) = @_;
                    push @trace, 'author ErrorHandler render';
                    return PAGI::Response::Text->new('author 500');
                },
            ),
            middleware(tracing_factory('author inner', \@trace)),
        ],
    )->to_app;

    my $events = run_scope($app, scope(path => '/explode'));
    is([grep { /ErrorHandler/ } @trace], [
        'author ErrorHandler report', 'author ErrorHandler render',
    ], 'author ErrorHandler reports before rendering');
    is([grep { / send / } @trace], [
        'author outer send http.response.start',
        'author outer send http.response.body',
    ], 'author error response crosses only the earlier outer wrapper');
    is($events->[0]{status}, 500, 'author ErrorHandler retains status 500');
    is($events->[1]{body}, 'author 500', 'author renderer owns the body');
};

subtest 'a retained Router owns its configured HTTP default inside Compose safety' => sub {
    my $pages = ComposeOwnedPages->new(as => 'text');
    my $routing = router(
        routes => [],
        http_default => $pages->not_found,
    );
    my $events = run_scope(compose(app => $routing)->to_app,
        scope(path => '/missing'));
    is($events->[0]{status}, 404, 'custom Router default retains status 404');
    is($events->[1]{body}, "owned:404:Not Found\n",
        'custom Router default owns the response body');
};

subtest 'ordinary shallow cloning preserves state proof and changes visible scope' => sub {
    my $state = {};
    my @seen;
    my $clone = sub {
        my ($inner) = @_;
        return sub {
            my ($scope, $receive, $send) = @_;
            return $inner->({ %$scope, worker => 'wrapped' }, $receive, $send);
        };
    };
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

subtest 'each to_app builds fresh bare middleware instances' => sub {
    my $factory_calls = 0;
    my $factory = sub {
        my ($inner) = @_;
        ++$factory_calls;
        return $inner;
    };
    my $object = ComposeDirectMiddleware->new;
    my $composition = compose(app => sub { return }, middleware => [$factory, $object]);
    is($object->wraps, 0, 'direct object is not wrapped during normalization');
    my $one = $composition->to_app;
    my $two = $composition->to_app;
    is($factory_calls, 2, 'factory runs once for each compiled graph');
    is($object->wraps, 2, 'direct object wraps once for each compiled graph');
    run_scope($one, scope(type => 'example'));
    run_scope($two, scope(type => 'example'));
    is($object->wraps, 2, 'requests do not rerun direct object wrapping');

    my $throwing = compose(
        app => sub { return },
        middleware => [sub { die "factory exploded\n" }],
    );
    like(dies { $throwing->to_app }, qr/factory exploded/,
        'bare factory failure aborts to_app synchronously');

    my $invalid = compose(
        app => sub { return },
        middleware => [sub { return 'not an app' }],
    );
    like(dies { $invalid->to_app }, qr/must return PAGI app coderef/,
        'invalid bare wrapper result aborts compilation');

    my $async = compose(
        app => sub { return },
        middleware => [sub { return Future->done(sub { }) }],
    );
    like(dies { $async->to_app }, qr/must return PAGI app coderef.*Future/,
        'an accidentally async bare factory remains invalid');
};

done_testing;
