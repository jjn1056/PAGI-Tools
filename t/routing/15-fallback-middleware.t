#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Encode qw(decode FB_CROAK);
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);

use PAGI::Middleware::Routing::NotFound;
use PAGI::Middleware::Routing::MethodNotAllowed;
use PAGI::Response;
use PAGI::Routing qw(router route mount middleware);
use PAGI::Routing::Trace;

{
    package Local::RespondOnly;

    sub new {
        my ($class, %args) = @_;
        return bless \%args, $class;
    }

    sub respond {
        my ($self, $send) = @_;
        return Future->needs_all(
            Future->wrap($send->({
                type    => 'http.response.start',
                status  => $self->{status},
                headers => [map { [@$_] } @{$self->{headers} || []}],
            })),
            Future->wrap($send->({
                type => 'http.response.body',
                body => $self->{body} // '',
                more => 0,
            })),
        );
    }
}

sub scope {
    my (%changes) = @_;
    return {
        type        => 'http',
        method      => 'GET',
        path        => '/',
        root_path   => '',
        raw_path    => '/',
        path_params => {},
        headers     => [],
        %changes,
    };
}

sub receive {
    return Future->done({
        type => 'http.request',
        body => '',
        more => 0,
    });
}

sub run_app {
    my ($app, $request_scope) = @_;
    my @events;
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    Future->wrap($app->($request_scope, \&receive, $send))->get;
    return \@events;
}

sub event_body {
    my ($events) = @_;
    return join '', map {
        ($_->{type} // '') eq 'http.response.body' ? ($_->{body} // '') : ''
    } @$events;
}

sub start_event {
    my ($events) = @_;
    return (grep { ($_->{type} // '') eq 'http.response.start' } @$events)[0];
}

sub header_values {
    my ($start, $wanted) = @_;
    my $folded = lc $wanted;
    return [map { $_->[1] } grep { lc($_->[0]) eq $folded }
        @{$start->{headers} || []}];
}

sub not_found_router {
    return router(routes => [
        route('/known' => sub { return $_[0]->text('known') }),
    ])->to_app;
}

sub method_router {
    return router(routes => [
        route('/items' => sub { return $_[0]->text('get') },
            methods => 'GET', name => 'get-items', desc => 'GET items'),
        route('/items' => sub { return $_[0]->text('post') },
            methods => 'POST', name => 'post-items', desc => 'POST items'),
    ])->to_app;
}

# Transitional Task 4 adapter. The real Router still renders its old decline;
# send it to a private sink while preserving the compiler's trusted Trace.
sub without_generated_decline {
    my ($router_app) = @_;
    return async sub {
        my ($request_scope, $request_receive, $outer_send) = @_;
        my $private_send = sub { return Future->done };
        await Future->wrap(
            $router_app->($request_scope, $request_receive, $private_send)
        );
    };
}

sub transitional_sink_factory {
    return sub {
        my ($inner) = @_;
        return without_generated_decline($inner);
    };
}

sub decline_app {
    my ($class, $router_app, @options) = @_;
    return $class->new(@options)->wrap(without_generated_decline($router_app));
}

subtest 'public constructors accept only an optional CODE handler' => sub {
    for my $class (
        'PAGI::Middleware::Routing::NotFound',
        'PAGI::Middleware::Routing::MethodNotAllowed',
    ) {
        isa_ok($class->new, ['PAGI::Middleware'], "$class uses the middleware base");
        isa_ok($class->new(handler => sub { }), [$class],
            "$class accepts a CODE handler");
        like(
            dies { $class->new('handler') },
            qr/options must be an even-length list/,
            "$class rejects an odd option list",
        );
        like(
            dies { $class->new(unknown => 1) },
            qr/unknown .* option 'unknown'/i,
            "$class rejects an unknown option",
        );
        like(
            dies { $class->new(handler => 'render') },
            qr/handler must be a code reference/i,
            "$class rejects a non-CODE handler",
        );
    }
};

subtest 'NotFound renders trusted no-path declines and supports both completion forms' => sub {
    my @seen;
    my @cases = (
        ['immediate', sub {
            my ($context, $snapshot) = @_;
            push @seen, [$context, $snapshot];
            return $context->text('immediate');
        }],
        ['Future', sub {
            my ($context, $snapshot) = @_;
            push @seen, [$context, $snapshot];
            return Future->done($context->text('future'));
        }],
    );

    for my $case (@cases) {
        my ($label, $handler) = @$case;
        my $events = run_app(
            decline_app('PAGI::Middleware::Routing::NotFound',
                not_found_router(), handler => $handler),
            scope(path => '/missing', raw_path => '/missing'),
        );
        is(start_event($events)->{status}, 404, "$label handler inherits status 404");
        is(event_body($events), $label eq 'Future' ? 'future' : 'immediate',
            "$label handler response is emitted");
    }

    is(scalar @seen, 2, 'each matching decline invokes its renderer once');
    isa_ok($seen[0][0], ['PAGI::Context::HTTP'], 'renderer receives an HTTP Context');
    isa_ok($seen[0][1], ['PAGI::Routing::Trace::Snapshot'],
        'renderer receives a public Snapshot');
    ok($seen[0][1]->routing_declined, 'snapshot retains trusted decline evidence');
    ok(!$seen[0][1]->path_matched, 'NotFound sees no complete path candidate');
};

subtest 'NotFound seeds cached status but preserves explicit renderer policy' => sub {
    my $seed;
    my $events = run_app(
        decline_app('PAGI::Middleware::Routing::NotFound', not_found_router(),
            handler => sub {
                my ($context) = @_;
                $seed = $context->response->status;
                return $context->text('concealed', status => 401,
                    headers => ['X-Policy' => 'custom']);
            }),
        scope(path => '/missing', raw_path => '/missing'),
    );
    my $start = start_event($events);
    is($seed, 404, 'cached Context response is seeded to 404');
    is($start->{status}, 401, 'an explicit renderer status wins');
    is(header_values($start, 'X-Policy'), ['custom'],
        'custom renderer headers pass through');
};

subtest 'NotFound constructs its Context with original request channels' => sub {
    my ($seen_receive, $seen_send);
    my @events;
    my $request_receive = sub { return receive() };
    my $outer_send = sub {
        push @events, $_[0];
        return Future->done;
    };
    my $app = decline_app('PAGI::Middleware::Routing::NotFound',
        not_found_router(), handler => sub {
            my ($context) = @_;
            $seen_receive = $context->receive;
            $seen_send = $context->raw_send;
            return $context->text('channels');
        });
    $app->(scope(path => '/missing'), $request_receive, $outer_send)->get;

    is(refaddr($seen_receive), refaddr($request_receive),
        'renderer Context keeps the original receive channel');
    is(refaddr($seen_send), refaddr($outer_send),
        'renderer Context keeps the outer send channel');
};

subtest 'NotFound built-in responses are safe UTF-8 no-store failsafes' => sub {
    local $ENV{PAGI_ENV} = 'production';
    my $production = run_app(
        decline_app('PAGI::Middleware::Routing::NotFound', not_found_router()),
        scope(path => '/missing', raw_path => '/missing'),
    );
    my $start = start_event($production);
    is($start->{status}, 404, 'production fallback status is 404');
    is(event_body($production), 'Not Found', 'production body is exact');
    is(header_values($start, 'Content-Type'), ['text/plain; charset=utf-8'],
        'production body declares UTF-8 text');
    is(header_values($start, 'Cache-Control'), ['no-store'],
        'production fallback is not cacheable');

    local $ENV{PAGI_ENV} = 'development';
    my $development = run_app(
        decline_app('PAGI::Middleware::Routing::NotFound', not_found_router()),
        scope(method => "G\x{c9}T", path => "/caf\x{e9}", raw_path => "/caf\x{e9}"),
    );
    my $decoded = decode('UTF-8', event_body($development), FB_CROAK);
    like($decoded, qr/PAGI automatic routing fallback/i,
        'development identifies the automatic failsafe');
    like($decoded, qr/no application fallback/i,
        'development explains that application policy did not handle the route');
    like($decoded, qr/G\x{c9}T/, 'development includes the safely encoded method');
    like($decoded, qr{/caf\x{e9}}, 'development includes the safely encoded path');
    like($decoded, qr{/known}, 'development includes safe attempted route metadata');
    unlike($decoded, qr/path_params|headers|cookies|body/i,
        'development does not expose forbidden request state');
    is(header_values(start_event($development), 'Cache-Control'), ['no-store'],
        'development fallback is also no-store');
};

subtest 'NotFound is inert for responses, exceptions, and missing evidence' => sub {
    my $selected = PAGI::Middleware::Routing::NotFound->new->wrap(
        router(routes => [
            route('/known' => sub { return $_[0]->text('selected', status => 202) }),
        ])->to_app,
    );
    my $events = run_app($selected, scope(path => '/known', raw_path => '/known'));
    is(start_event($events)->{status}, 202, 'a selected response passes through');
    is(event_body($events), 'selected', 'selected body is unchanged');

    my $after_decline = PAGI::Middleware::Routing::NotFound->new->wrap(async sub {
        my ($request_scope, $request_receive, $send) = @_;
        await Future->wrap(without_generated_decline(not_found_router())->(
            $request_scope, $request_receive, $send,
        ));
        await Future->wrap($send->({
            type => 'http.response.start', status => 418, headers => [],
        }));
        await Future->wrap($send->({
            type => 'http.response.body', body => 'started', more => 0,
        }));
    });
    $events = run_app($after_decline, scope(path => '/missing'));
    is(start_event($events)->{status}, 418,
        'a locally started response wins even when trusted decline evidence exists');
    is(scalar(grep { ($_->{type} // '') eq 'http.response.start' } @$events), 1,
        'started response is not duplicated');

    my $error = bless {}, 'Local::FallbackError';
    my $throwing = PAGI::Middleware::Routing::NotFound->new->wrap(sub { die $error });
    my $caught = dies {
        $throwing->(scope(), \&receive, sub { return Future->done })->get;
    };
    is(refaddr($caught), refaddr($error), 'the exact exception value is rethrown');

    my $silent = PAGI::Middleware::Routing::NotFound->new->wrap(
        sub { return Future->done }
    );
    is(run_app($silent, scope()), [], 'silent native app without evidence stays silent');
};

subtest 'NotFound rejects invalid renderer response values' => sub {
    for my $returned (undef, 'not a response', Future->done({})) {
        my $app = decline_app('PAGI::Middleware::Routing::NotFound',
            not_found_router(), handler => sub { return $returned });
        like(
            dies { run_app($app, scope(path => '/missing')) },
            qr/handler did not return a response/,
            'a renderer must satisfy the shared response contract',
        );
    }
};

subtest 'MethodNotAllowed renders only trusted method partials' => sub {
    my ($seed, $snapshot_seen);
    my $events = run_app(
        decline_app('PAGI::Middleware::Routing::MethodNotAllowed', method_router(),
            handler => sub {
                my ($context, $snapshot) = @_;
                $seed = $context->response->status;
                $snapshot_seen = $snapshot;
                return Future->done($context->text('custom 405'));
            }),
        scope(method => 'DELETE', path => '/items', raw_path => '/items'),
    );
    my $start = start_event($events);
    is($seed, 405, 'cached Context response is seeded to 405');
    is($start->{status}, 405, 'Future renderer retains seeded 405');
    is(header_values($start, 'Allow'), ['GET, HEAD, POST'],
        'missing Allow is supplied from the deterministic union');
    ok($snapshot_seen->path_matched, 'renderer snapshot records a path candidate');
    ok(!$snapshot_seen->method_matched, 'renderer snapshot records method rejection');
    is($snapshot_seen->allowed_methods, [qw(GET HEAD POST)],
        'renderer receives a defensive allowed-method union');

    my $not_found = decline_app('PAGI::Middleware::Routing::MethodNotAllowed',
        not_found_router(), handler => sub { die 'must not render' });
    is(run_app($not_found, scope(path => '/missing')), [],
        'no-path decline does not become method-not-allowed');
};

subtest 'MethodNotAllowed makes Allow authoritative without mutating renderers' => sub {
    my @cases = (
        ['missing', []],
        ['duplicate lowercase conflicting', [
            ['allow' => 'DELETE'],
            ['Allow' => 'PATCH'],
            ['ALLOW' => 'OPTIONS'],
            ['X-Policy' => 'kept'],
        ]],
    );

    for my $case (@cases) {
        my ($label, $pairs) = @$case;
        my $response = PAGI::Response->text('method policy', status => 405,
            headers => [map { @$_ } @$pairs]);
        my $before = $response->header_all('Allow');
        my $events = run_app(
            decline_app('PAGI::Middleware::Routing::MethodNotAllowed',
                method_router(), handler => sub { return $response }),
            scope(method => 'DELETE', path => '/items'),
        );
        my $start = start_event($events);
        is(header_values($start, 'Allow'), ['GET, HEAD, POST'],
            "$label Allow is replaced by one authoritative field");
        is($response->header_all('Allow'), $before,
            "$label renderer object is not mutated");
        if ($label ne 'missing') {
            is(header_values($start, 'X-Policy'), ['kept'],
                'unrelated renderer headers remain');
        }
    }
};

subtest 'MethodNotAllowed normalizes at the event boundary for respond-only objects' => sub {
    my $response = Local::RespondOnly->new(
        status => 405,
        headers => [
            ['allow' => 'DELETE'],
            ['Allow' => 'PATCH'],
            ['X-Object' => 'respond-only'],
        ],
        body => 'object',
    );
    my $events = run_app(
        decline_app('PAGI::Middleware::Routing::MethodNotAllowed', method_router(),
            handler => sub { return Future->done($response) }),
        scope(method => 'DELETE', path => '/items'),
    );
    my $start = start_event($events);
    is(header_values($start, 'Allow'), ['GET, HEAD, POST'],
        'respond-only object receives one authoritative Allow');
    is(header_values($start, 'X-Object'), ['respond-only'],
        'respond-only unrelated headers remain');
    is($response->{headers}, [
        ['allow' => 'DELETE'],
        ['Allow' => 'PATCH'],
        ['X-Object' => 'respond-only'],
    ], 'respond-only renderer object is unchanged');
};

subtest 'MethodNotAllowed leaves Allow untouched when renderer changes status' => sub {
    my $response = PAGI::Response->text('concealed', status => 404,
        headers => ['allow' => 'PRIVATE', 'X-Policy' => 'kept']);
    my $events = run_app(
        decline_app('PAGI::Middleware::Routing::MethodNotAllowed', method_router(),
            handler => sub { return $response }),
        scope(method => 'DELETE', path => '/items'),
    );
    my $start = start_event($events);
    is($start->{status}, 404, 'explicit non-405 status wins');
    is(header_values($start, 'Allow'), ['PRIVATE'],
        'non-405 response keeps its renderer-provided Allow unchanged');
    is(header_values($start, 'X-Policy'), ['kept'],
        'non-405 response keeps unrelated headers');
};

subtest 'MethodNotAllowed built-in responses are safe UTF-8 no-store failsafes' => sub {
    local $ENV{PAGI_ENV} = 'production';
    my $production = run_app(
        decline_app('PAGI::Middleware::Routing::MethodNotAllowed', method_router()),
        scope(method => 'DELETE', path => '/items'),
    );
    my $start = start_event($production);
    is($start->{status}, 405, 'production fallback status is 405');
    is(event_body($production), 'Method Not Allowed', 'production body is exact');
    is(header_values($start, 'Allow'), ['GET, HEAD, POST'],
        'production Allow is authoritative');
    is(header_values($start, 'Content-Type'), ['text/plain; charset=utf-8'],
        'production body declares UTF-8 text');
    is(header_values($start, 'Cache-Control'), ['no-store'],
        'production fallback is not cacheable');

    local $ENV{PAGI_ENV} = 'development';
    my $development = run_app(
        decline_app('PAGI::Middleware::Routing::MethodNotAllowed', method_router()),
        scope(method => "D\x{c9}LETE", path => '/items'),
    );
    my $decoded = decode('UTF-8', event_body($development), FB_CROAK);
    like($decoded, qr/PAGI automatic routing fallback/i,
        'development identifies the automatic failsafe');
    like($decoded, qr/D\x{c9}LETE/, 'development includes the safely encoded method');
    like($decoded, qr{/items}, 'development includes safe attempted route metadata');
    unlike($decoded, qr/path_params|headers|cookies|body/i,
        'development does not expose forbidden request state');
};

subtest 'MethodNotAllowed is inert for responses, exceptions, and missing evidence' => sub {
    my $explicit = PAGI::Middleware::Routing::MethodNotAllowed->new->wrap(
        router(routes => [
            route('/explicit' => sub {
                return $_[0]->text('explicit', status => 405);
            }),
        ])->to_app,
    );
    my $events = run_app($explicit, scope(path => '/explicit'));
    is(start_event($events)->{status}, 405, 'explicit selected 405 passes through');
    is(header_values(start_event($events), 'Allow'), [],
        'explicit selected 405 is not repaired');

    my $after_decline = PAGI::Middleware::Routing::MethodNotAllowed->new->wrap(async sub {
        my ($request_scope, $request_receive, $send) = @_;
        await Future->wrap(without_generated_decline(method_router())->(
            $request_scope, $request_receive, $send,
        ));
        await Future->wrap($send->({
            type => 'http.response.start', status => 204, headers => [],
        }));
        await Future->wrap($send->({
            type => 'http.response.body', body => '', more => 0,
        }));
    });
    $events = run_app($after_decline,
        scope(method => 'DELETE', path => '/items'));
    is(start_event($events)->{status}, 204,
        'a locally started response wins over method-partial evidence');
    is(scalar(grep { ($_->{type} // '') eq 'http.response.start' } @$events), 1,
        'started response is not duplicated');

    my $error = bless {}, 'Local::MethodFallbackError';
    my $throwing = PAGI::Middleware::Routing::MethodNotAllowed->new->wrap(
        sub { die $error }
    );
    my $caught = dies {
        $throwing->(scope(), \&receive, sub { return Future->done })->get;
    };
    is(refaddr($caught), refaddr($error), 'the exact exception value is rethrown');

    my $silent = PAGI::Middleware::Routing::MethodNotAllowed->new->wrap(
        sub { return Future->done }
    );
    is(run_app($silent, scope()), [], 'silent native app without evidence stays silent');
};

subtest 'routing fallback never installs or transforms non-HTTP scopes' => sub {
    for my $class (
        'PAGI::Middleware::Routing::NotFound',
        'PAGI::Middleware::Routing::MethodNotAllowed',
    ) {
        for my $type (qw(websocket sse lifespan extension)) {
            my ($seen_scope, $seen_receive, $seen_send);
            my $native = sub {
                ($seen_scope, $seen_receive, $seen_send) = @_;
                return Future->done;
            };
            my $wrapped = $class->new(handler => sub { die 'must not render' })
                ->wrap($native);
            my $request_scope = { type => $type, marker => {} };
            my $request_receive = sub { return Future->done };
            my $request_send = sub { return Future->done };
            Future->wrap($wrapped->(
                $request_scope, $request_receive, $request_send,
            ))->get;

            is(refaddr($seen_scope), refaddr($request_scope),
                "$class preserves $type scope identity");
            is(refaddr($seen_receive), refaddr($request_receive),
                "$class preserves $type receive identity");
            is(refaddr($seen_send), refaddr($request_send),
                "$class preserves $type send identity");
            ok(!exists $request_scope->{'pagi.routing.trace'},
                "$class installs no $type routing trace");
        }
    }
};

subtest 'nested fallbacks emit once and preserve append-only evidence' => sub {
    for my $case (
        ['PAGI::Middleware::Routing::NotFound', not_found_router(),
            scope(path => '/missing')],
        ['PAGI::Middleware::Routing::MethodNotAllowed', method_router(),
            scope(method => 'DELETE', path => '/items')],
    ) {
        my ($class, $router_app, $request_scope) = @$case;
        my $inner_calls = 0;
        my $inner = $class->new(handler => sub {
            my ($context) = @_;
            ++$inner_calls;
            return $context->text('inner policy');
        })->wrap(without_generated_decline($router_app));
        my $nested = $class->new->wrap($inner);
        my ($trace_scope, $trace) = PAGI::Routing::Trace->_ensure_http_scope(
            $request_scope,
        );
        my $checkpoint = $trace->checkpoint;
        my $events = run_app($nested, $trace_scope);

        is($inner_calls, 1, "$class inner custom fallback renders once");
        is(scalar(grep { ($_->{type} // '') eq 'http.response.start' } @$events), 1,
            "$class nested default observes the inner start and stays inert");
        ok($trace->snapshot($checkpoint)->routing_declined,
            "$class does not consume or clear routing records");
    }
};

subtest 'short names work at Router and routing-aware Mount boundaries' => sub {
    my $router_not_found = router(
        middleware => [
            middleware('Routing::NotFound', handler => sub {
                return $_[0]->text('router not found');
            }),
            transitional_sink_factory(),
        ],
        routes => [route('/known' => sub { return $_[0]->text('known') })],
    )->to_app;
    is(event_body(run_app($router_not_found, scope(path => '/missing'))),
        'router not found', 'Router middleware observes its local exhaustion');

    my $router_method = router(
        middleware => [
            middleware('Routing::MethodNotAllowed', handler => sub {
                return $_[0]->text('router method');
            }),
            transitional_sink_factory(),
        ],
        routes => [route('/items' => sub { return $_[0]->text('items') },
            methods => 'GET')],
    )->to_app;
    my $method_events = run_app($router_method,
        scope(method => 'POST', path => '/items'));
    is(event_body($method_events), 'router method',
        'Router MethodNotAllowed observes its local exhaustion');
    is(header_values(start_event($method_events), 'Allow'), ['GET, HEAD'],
        'Router boundary publishes its local method union');

    my $child = router(routes => [
        route('/known' => sub { return $_[0]->text('known') }),
    ]);
    my $mounted = router(routes => [
        mount('/api', router => $child, name => 'api', middleware => [
            middleware('Routing::NotFound', handler => sub {
                return $_[0]->text('mount not found');
            }),
            transitional_sink_factory(),
        ]),
    ])->to_app;
    is(event_body(run_app($mounted,
        scope(path => '/api/missing', raw_path => '/api/missing'))),
        'mount not found', 'routing-aware Mount owns its selected child decline');
};

subtest 'Route placement is valid but cannot observe route exhaustion' => sub {
    my ($not_found_calls, $method_calls) = (0, 0);
    my $app = router(routes => [
        route('/present' => sub { return $_[0]->text('present') },
            middleware => [
                middleware('Routing::NotFound', handler => sub {
                    ++$not_found_calls;
                    return $_[0]->text('wrong 404');
                }),
                middleware('Routing::MethodNotAllowed', handler => sub {
                    ++$method_calls;
                    return $_[0]->text('wrong 405');
                }),
            ]),
    ])->to_app;

    is(event_body(run_app($app, scope(path => '/present'))), 'present',
        'selected Route response passes through both legal wrappers');
    is(start_event(run_app($app, scope(path => '/missing')))->{status}, 404,
        'Router owns exhaustion before Route middleware is entered');
    is([$not_found_calls, $method_calls], [0, 0],
        'Route-level fallback renderers never observe exhaustion');
};

done_testing;
