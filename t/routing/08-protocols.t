#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);

use PAGI::Routing qw(router route websocket sse mount middleware);

sub ProtocolProvider { return qr/accepted/ }

{
    package Local::ProtocolPathCheck;
    sub new { return bless { expected => $_[1] }, $_[0] }
    sub check { return $_[1] eq $_[0]{expected} }
    sub get_message { return "expected $_[0]{expected}, got $_[1]" }
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

sub run_scope {
    my ($app, $request_scope, %channels) = @_;
    my @events;
    my $receive = $channels{receive} || sub { Future->done({ type => 'unused.receive' }) };
    my $send = $channels{send} || sub {
        push @events, $_[0];
        return Future->done;
    };

    $app->($request_scope, $receive, $send)->get;
    return \@events;
}

subtest 'normal WebSocket and SSE handlers use protocol Contexts and ignore completion values' => sub {
    my @seen;
    my $app = router(routes => [
        mount('/api/{tenant}', routes => [
            websocket('/socket/{room}' => async sub {
                my ($c) = @_;
                push @seen, {
                    kind        => ref($c),
                    path        => $c->path,
                    root_path   => $c->scope->{root_path},
                    raw_path    => $c->raw_path,
                    path_params => $c->path_params,
                };
                await $c->accept(subprotocol => 'chat');
                await $c->send_text('welcome');
                await $c->close(1000, 'done');
                return { this => 'is not a wire event' };
            }),
            sse('/events/{channel}' => sub {
                my ($c) = @_;
                push @seen, {
                    kind        => ref($c),
                    path        => $c->path,
                    root_path   => $c->scope->{root_path},
                    raw_path    => $c->raw_path,
                    path_params => $c->path_params,
                };
                $c->start(status => 201)->get;
                $c->send('ready')->get;
                $c->close->get;
                return 'plain synchronous completion';
            }),
        ]),
    ])->to_app;

    my $ws_events = run_scope($app, scope(
        type        => 'websocket',
        path        => '/api/acme/socket/lobby',
        root_path   => '/edge',
        raw_path    => '/edge/api/acme/socket/lobby',
        path_params => { retained => 'yes' },
    ));
    my $sse_events = run_scope($app, scope(
        type        => 'sse',
        path        => '/api/acme/events/news',
        root_path   => '/edge',
        raw_path    => '/edge/api/acme/events/news',
        path_params => { retained => 'yes' },
    ));

    is(\@seen, [
        {
            kind        => 'PAGI::Context::WebSocket',
            path        => '/socket/lobby',
            root_path   => '/edge/api/acme',
            raw_path    => '/edge/api/acme/socket/lobby',
            path_params => { retained => 'yes', tenant => 'acme', room => 'lobby' },
        },
        {
            kind        => 'PAGI::Context::SSE',
            path        => '/events/news',
            root_path   => '/edge/api/acme',
            raw_path    => '/edge/api/acme/events/news',
            path_params => { retained => 'yes', tenant => 'acme', channel => 'news' },
        },
    ], 'mounted protocol handlers receive the right Context subclass and rewritten scope');
    is($ws_events, [
        { type => 'websocket.accept', subprotocol => 'chat' },
        { type => 'websocket.send', text => 'welcome' },
        { type => 'websocket.close', code => 1000, reason => 'done' },
    ], 'Future-backed WebSocket completion adds no wire interpretation');
    is($sse_events, [
        { type => 'sse.start', status => 201 },
        { type => 'sse.send', data => 'ready' },
        { type => 'sse.close' },
    ], 'plain SSE completion adds no wire interpretation');
};

subtest 'raw HTTP, WebSocket, and SSE leaves own their exact matched channels' => sub {
    my @seen;
    my $raw = sub {
        my ($label, $event) = @_;
        return sub {
            my ($request_scope, $receive, $send) = @_;
            push @seen, {
                label      => $label,
                scope      => $request_scope,
                receive_id => refaddr($receive),
                send_id    => refaddr($send),
            };
            $send->($event)->get;
            return "$label completion" if $label ne 'sse';
            return Future->done("$label Future completion");
        };
    };
    my $app = router(routes => [
        route('/raw-http/{id}', raw => $raw->('http', {
            type => 'http.response.start', status => 204, headers => [],
        })),
        websocket('/raw-ws/{id}', raw => $raw->('websocket', {
            type => 'websocket.close', code => 1001, reason => 'raw',
        })),
        sse('/raw-sse/{id}', raw => $raw->('sse', {
            type => 'sse.close',
        })),
    ])->to_app;

    my @cases = (
        ['http', scope(path => '/raw-http/1', raw_path => '/raw-http/1')],
        ['websocket', scope(type => 'websocket', path => '/raw-ws/2', raw_path => '/raw-ws/2')],
        ['sse', scope(type => 'sse', path => '/raw-sse/3', raw_path => '/raw-sse/3')],
    );
    my @event_sets;
    for my $case (@cases) {
        my ($label, $request_scope) = @$case;
        my $receive = sub { Future->done({ type => "$label.receive" }) };
        my @events;
        my $send = sub {
            push @events, $_[0];
            return Future->done;
        };
        $app->($request_scope, $receive, $send)->get;
        push @event_sets, \@events;
        is($seen[-1]{receive_id}, refaddr($receive), "$label raw leaf receives the exact receive channel");
        is($seen[-1]{send_id}, refaddr($send), "$label raw leaf receives the exact send channel");
    }

    is(
        [map { [$_->{label}, $_->{scope}{type}, $_->{scope}{path_params}] } @seen],
        [
            ['http', 'http', { id => '1' }],
            ['websocket', 'websocket', { id => '2' }],
            ['sse', 'sse', { id => '3' }],
        ],
        'raw leaves receive matched child scopes without Context adaptation',
    );
    is($event_sets[0], [{ type => 'http.response.start', status => 204, headers => [] }],
        'raw HTTP leaf owns HTTP emission');
    is($event_sets[1], [{ type => 'websocket.close', code => 1001, reason => 'raw' }],
        'raw WebSocket leaf owns WebSocket emission');
    is($event_sets[2], [{ type => 'sse.close' }],
        'raw SSE leaf owns SSE emission and its Future result is inert');
};

subtest 'normal and raw protocols apply inline providers and explicit constraints before invocation' => sub {
    my (@normal_ws, @raw_ws, @normal_sse, @raw_sse);
    my $app = router(routes => [
        websocket('/provider-ws/{id:&ProtocolProvider}' => async sub {
            push @normal_ws, $_[0]->path_param('id');
            await $_[0]->close(1000, 'normal provider');
        }),
        websocket('/predicate-ws/{id}', raw => sub {
            my ($request_scope, $receive, $send) = @_;
            push @raw_ws, $request_scope->{path_params}{id};
            $send->({
                type => 'websocket.close', code => 1001, reason => 'raw predicate',
            })->get;
            return Future->done;
        }, name => 'predicate-ws',
            constraints => { id => Local::ProtocolPathCheck->new('accepted') }),
        sse('/predicate-sse/{id}' => async sub {
            push @normal_sse, $_[0]->path_param('id');
            await $_[0]->close;
        }, name => 'predicate-sse',
            constraints => { id => sub { return $_[0] eq 'accepted' } }),
        sse('/provider-sse/{id:&ProtocolProvider}', raw => sub {
            my ($request_scope, $receive, $send) = @_;
            push @raw_sse, $request_scope->{path_params}{id};
            $send->({ type => 'sse.close' })->get;
            return Future->done;
        }),
    ])->to_app;

    is(run_scope($app, scope(type => 'websocket', path => '/provider-ws/accepted')),
        [{ type => 'websocket.close', code => 1000, reason => 'normal provider' }],
        'normal WebSocket dispatch accepts an inline provider capture');
    is(run_scope($app, scope(type => 'websocket', path => '/predicate-ws/accepted')),
        [{ type => 'websocket.close', code => 1001, reason => 'raw predicate' }],
        'raw WebSocket dispatch accepts an explicit check object');
    is(run_scope($app, scope(type => 'sse', path => '/predicate-sse/accepted')),
        [{ type => 'sse.close' }],
        'normal SSE dispatch accepts an explicit predicate');
    is(run_scope($app, scope(type => 'sse', path => '/provider-sse/accepted')),
        [{ type => 'sse.close' }],
        'raw SSE dispatch accepts an inline provider capture');

    for my $path (qw(/provider-ws/rejected /predicate-ws/rejected)) {
        my $events = run_scope($app, scope(
            type => 'websocket', path => $path,
            extensions => { 'websocket.http.response' => {} },
        ));
        is($events->[0]{type}, 'websocket.http.response.start',
            "$path rejection uses the existing WebSocket denial family");
        is($events->[0]{status}, 404, "$path rejection is a denial 404");
    }
    for my $path (qw(/predicate-sse/rejected /provider-sse/rejected)) {
        my $events = run_scope($app, scope(type => 'sse', path => $path));
        is($events->[0]{type}, 'sse.http.response.start',
            "$path rejection uses the existing SSE decline family");
        is($events->[0]{status}, 404, "$path rejection is a decline 404");
    }

    is(\@normal_ws, ['accepted'], 'normal WebSocket handler runs only after acceptance');
    is(\@raw_ws, ['accepted'], 'raw WebSocket app runs only after acceptance');
    is(\@normal_sse, ['accepted'], 'normal SSE handler runs only after acceptance');
    is(\@raw_sse, ['accepted'], 'raw SSE app runs only after acceptance');
};

subtest 'protocol adapters await pending completion and propagate failures' => sub {
    my $normal_completion = Future->new;
    my $normal_app = websocket('/wait' => sub {
        return $normal_completion;
    })->to_app;
    my @normal_events;
    my $normal_running = $normal_app->(
        scope(type => 'websocket', path => '/wait'),
        sub { Future->done({ type => 'websocket.connect' }) },
        sub { push @normal_events, $_[0]; return Future->done },
    );
    ok(!$normal_running->is_ready, 'normal protocol dispatch waits for handler completion');
    $normal_completion->done({ ignored => 'handler value' });
    is($normal_running->get, undef, 'normal completion resolves to inert router completion');
    is(\@normal_events, [], 'normal resolved value is not interpreted as an event');

    my $raw_completion = Future->new;
    my $raw_app = sse('/wait', raw => sub {
        return $raw_completion;
    })->to_app;
    my $raw_running = $raw_app->(
        scope(type => 'sse', path => '/wait'),
        sub { Future->done({ type => 'sse.disconnect' }) },
        sub { return Future->done },
    );
    ok(!$raw_running->is_ready, 'raw protocol dispatch waits for application completion');
    $raw_completion->done('ignored raw value');
    is($raw_running->get, undef, 'raw Future result remains inert');

    my $throwing = websocket('/boom' => sub { die "synchronous protocol boom\n" })->to_app;
    like(
        dies { run_scope($throwing, scope(type => 'websocket', path => '/boom')) },
        qr/synchronous protocol boom/,
        'a synchronous handler exception propagates without becoming a decline',
    );
    my $failing = sse('/boom' => sub {
        return Future->fail("failed protocol Future\n");
    })->to_app;
    like(
        dies { run_scope($failing, scope(type => 'sse', path => '/boom')) },
        qr/failed protocol Future/,
        'a failed handler Future propagates without becoming a decline',
    );
};

subtest 'protocol selection is declaration ordered, protocol local, and mount aware' => sub {
    my @trace;
    my $route_middleware = middleware(sub {
        my ($inner) = @_;
        return async sub {
            push @trace, 'route before';
            my $returned = $inner->(@_);
            await Future->wrap($returned);
            push @trace, 'route after';
        };
    });
    my $mount_middleware = middleware(sub {
        my ($inner) = @_;
        return async sub {
            push @trace, 'mount before';
            my $returned = $inner->(@_);
            await Future->wrap($returned);
            push @trace, 'mount after';
        };
    });
    my $app = router(routes => [
        route('/shared' => sub {
            push @trace, 'http';
            return $_[0]->text('http');
        }),
        websocket('/shared' => async sub {
            push @trace, 'first websocket';
            await $_[0]->close;
        }),
        websocket('/shared' => async sub {
            push @trace, 'second websocket';
            await $_[0]->close;
        }),
        sse('/shared' => async sub {
            push @trace, 'sse';
            await $_[0]->close;
        }),
        mount('/blocked/{tenant}', routes => [
            websocket('/socket' => async sub {
                push @trace, 'blocked mount';
                await $_[0]->close;
            }),
        ], constraints => { tenant => qr/allowed/ }),
        websocket('/blocked/denied/socket' => async sub {
            push @trace, 'constraint fallback';
            await $_[0]->close;
        }, middleware => [$route_middleware]),
        mount('/nested', routes => [
            sse('/events' => async sub {
                push @trace, 'nested sse';
                await $_[0]->close;
            }, middleware => [$route_middleware]),
        ], middleware => [$mount_middleware]),
    ])->to_app;

    run_scope($app, scope(type => 'websocket', path => '/shared'));
    run_scope($app, scope(type => 'sse', path => '/shared'));
    run_scope($app, scope(type => 'websocket', path => '/blocked/denied/socket'));
    run_scope($app, scope(type => 'sse', path => '/nested/events'));

    is(\@trace, [
        'first websocket',
        'sse',
        'route before', 'constraint fallback', 'route after',
        'mount before', 'route before', 'nested sse', 'route after', 'mount after',
    ], 'only matching protocol leaves run; failed mount constraints continue and middleware surrounds selected leaves');

    my @mounted;
    my $component = router(routes => [
        mount('/component' => sub {
            my ($request_scope) = @_;
            push @mounted, [
                $request_scope->{type} // 'http',
                $request_scope->{method},
                $request_scope->{path},
            ];
            return 'opaque completion';
        }),
    ])->to_app;
    run_scope($component, scope(type => 'http', method => 'DELETE', path => '/component/x'));
    run_scope($component, scope(type => 'websocket', method => undef, path => '/component/x'));
    run_scope($component, scope(type => 'sse', method => undef, path => '/component/x'));
    is(\@mounted, [
        ['http', 'DELETE', '/x'],
        ['websocket', undef, '/x'],
        ['sse', undef, '/x'],
    ], 'an application mount owns every supported scope type without an HTTP method filter');
};

subtest 'HTTP selection ignores WebSocket and SSE leaves without warnings' => sub {
    my $app = router(routes => [
        websocket('/ws-only' => sub { return 'inert' }),
        sse('/sse-only' => sub { return 'inert' }),
        websocket('/shared' => sub { return 'inert' }),
        sse('/shared' => sub { return 'inert' }),
        route('/shared' => sub { return $_[0]->text('http leaf') }),
    ])->to_app;

    my @warnings;
    my ($ws_only, $sse_only, $shared);
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $ws_only = run_scope($app, scope(path => '/ws-only'));
        $sse_only = run_scope($app, scope(path => '/sse-only'));
        $shared = run_scope($app, scope(path => '/shared'));
    }

    is(\@warnings, [], 'mixed-protocol route tables do not warn during HTTP selection');
    is($ws_only->[0]{status}, 404, 'a WebSocket-only path is absent from HTTP routing');
    is($sse_only->[0]{status}, 404, 'an SSE-only path is absent from HTTP routing');
    is($shared->[0]{status}, 200, 'HTTP scanning continues to a later same-path HTTP leaf');
    is($shared->[1]{body}, 'http leaf', 'the later HTTP leaf owns the response');
};

subtest 'protocol misses, lifespan, and unknown scopes have distinct wire outcomes' => sub {
    my @http_fallback_calls;
    my $app = router(
        routes => [],
        not_found => sub {
            my ($c) = @_;
            push @http_fallback_calls, $c->type // 'http';
            return $c->text('custom HTTP missing');
        },
    )->to_app;

    my $sse_events = run_scope($app, scope(type => 'sse', path => '/missing'));
    is($sse_events, [
        {
            type    => 'sse.http.response.start',
            status  => 404,
            headers => [['content-type', 'text/plain']],
        },
        {
            type => 'sse.http.response.body',
            body => 'Not Found',
            more => 0,
        },
    ], 'an unmatched SSE scope receives the SSE decline event family');

    my $ws_denial = run_scope($app, scope(
        type       => 'websocket',
        path       => '/missing',
        extensions => { 'websocket.http.response' => {} },
    ));
    is($ws_denial, [
        {
            type    => 'websocket.http.response.start',
            status  => 404,
            headers => [['content-type', 'text/plain']],
        },
        {
            type => 'websocket.http.response.body',
            body => 'Not Found',
            more => 0,
        },
    ], 'the advertised WebSocket denial extension carries a namespaced 404');

    my $ws_close = run_scope($app, scope(
        type => 'websocket',
        path => '/missing',
    ));
    is($ws_close, [{ type => 'websocket.close' }],
        'without the denial extension an unmatched WebSocket closes before acceptance');
    is(\@http_fallback_calls, [],
        'WebSocket and SSE misses never invoke the HTTP not-found handler');

    my ($lifespan_reads, $lifespan_sends) = (0, 0);
    my $lifespan_result = $app->(
        { type => 'lifespan' },
        sub { ++$lifespan_reads; return Future->fail('must not read lifespan') },
        sub { ++$lifespan_sends; return Future->fail('must not send lifespan') },
    )->get;
    is($lifespan_result, undef, 'lifespan returns inert completion');
    is([$lifespan_reads, $lifespan_sends], [0, 0],
        'lifespan completion neither reads nor sends');

    my $missing_type_events = run_scope($app, {
        method => 'GET', path => '/missing', headers => [],
    });
    is($missing_type_events->[0]{type}, 'http.response.start',
        'a missing scope type defaults to HTTP dispatch');
    is($missing_type_events->[0]{status}, 404,
        'the normal HTTP not-found policy handles a missing type');
    my $missing_type_head = run_scope($app, {
        method => 'HEAD', path => '/missing', headers => [],
    });
    is($missing_type_head->[1], {
        type => 'http.response.body', body => '', more => 0,
    }, 'defaulting a missing type to HTTP includes the outer HEAD wire contract');
    is(\@http_fallback_calls, ['http', 'http'],
        'only missing-type HTTP requests invoke the configured fallback');

    my ($grpc_reads, $grpc_sends) = (0, 0);
    like(
        dies {
            $app->(
                { type => 'grpc', path => '/missing' },
                sub { ++$grpc_reads; return Future->done },
                sub { ++$grpc_sends; return Future->done },
            )->get;
        },
        qr/unsupported PAGI scope type 'grpc'/,
        'an unknown scope type croaks with the type in the diagnostic',
    );
    is([$grpc_reads, $grpc_sends], [0, 0],
        'unknown scope rejection does not touch either channel');
};

subtest 'scope-type gates run before short-circuiting router middleware' => sub {
    my @middleware_types;
    my $short_circuit = middleware(sub {
        my ($inner) = @_;
        return async sub {
            my ($request_scope, $receive, $send) = @_;
            push @middleware_types, $request_scope->{type} // 'http';
            await $receive->();
            await $send->({
                type => 'http.response.start', status => 200, headers => [],
            });
            await $send->({
                type => 'http.response.body', body => 'middleware', more => 0,
            });
            return;
        };
    });
    my $app = router(
        routes => [],
        middleware => [$short_circuit],
    )->to_app;

    my ($lifespan_reads, $lifespan_sends) = (0, 0);
    is(
        $app->(
            { type => 'lifespan' },
            sub { ++$lifespan_reads; return Future->done({ type => 'lifespan.startup' }) },
            sub { ++$lifespan_sends; return Future->done },
        )->get,
        undef,
        'lifespan returns before short-circuiting router middleware',
    );
    is([$lifespan_reads, $lifespan_sends], [0, 0],
        'router middleware cannot read or send on lifespan');
    is(\@middleware_types, [], 'lifespan never enters router middleware');

    my ($grpc_reads, $grpc_sends) = (0, 0);
    like(
        dies {
            $app->(
                { type => 'grpc', path => '/' },
                sub { ++$grpc_reads; return Future->done({ type => 'grpc.request' }) },
                sub { ++$grpc_sends; return Future->done },
            )->get;
        },
        qr/unsupported PAGI scope type 'grpc'/,
        'unknown scopes are rejected before short-circuiting router middleware',
    );
    is([$grpc_reads, $grpc_sends], [0, 0],
        'router middleware cannot touch unknown-scope channels');
    is(\@middleware_types, [], 'unknown scopes never enter router middleware');

    my $http_reads = 0;
    my @http_events;
    my $http_running = $app->(
        scope(method => 'HEAD', path => '/short'),
        sub { ++$http_reads; return Future->done({ type => 'http.request' }) },
        sub { push @http_events, $_[0]; return Future->done },
    );
    $http_running->get;
    is($http_reads, 1, 'supported HTTP still reaches router middleware');
    is(\@middleware_types, ['http'], 'supported type enters router middleware normally');
    is(\@http_events, [
        { type => 'http.response.start', status => 200, headers => [] },
        { type => 'http.response.body', body => '', more => 0 },
    ], 'the outer HEAD wire boundary still suppresses middleware-owned bodies');
};

subtest 'standalone protocol leaves and mounts compile as complete applications' => sub {
    my $ws_app = websocket('/socket' => async sub {
        await $_[0]->close(1000, 'standalone');
    })->to_app;
    my $sse_app = sse('/events' => async sub {
        await $_[0]->close;
    })->to_app;

    is(ref($ws_app), 'CODE', 'a standalone WebSocket node compiles to an application');
    is(ref($sse_app), 'CODE', 'a standalone SSE node compiles to an application');
    is(run_scope($ws_app, scope(type => 'websocket', path => '/socket')), [
        { type => 'websocket.close', code => 1000, reason => 'standalone' },
    ], 'the standalone WebSocket application dispatches its leaf');
    is(run_scope($ws_app, scope(type => 'sse', path => '/missing'))->[0]{type},
        'sse.http.response.start', 'a standalone WebSocket application retains SSE fallback behavior');
    is(run_scope($sse_app, scope(type => 'sse', path => '/events')), [
        { type => 'sse.close' },
    ], 'the standalone SSE application dispatches its leaf');
    is(run_scope($sse_app, scope(type => 'websocket', path => '/missing')), [
        { type => 'websocket.close' },
    ], 'a standalone SSE application retains WebSocket fallback behavior');

    my @trace;
    my $mount_wrapper = middleware(sub {
        my ($inner) = @_;
        return async sub {
            push @trace, 'mount before';
            my $returned = $inner->(@_);
            await Future->wrap($returned);
            push @trace, 'mount after';
        };
    });
    my $mount_app = mount('/api', routes => [
        websocket('/socket' => async sub { await $_[0]->close }),
    ], middleware => [$mount_wrapper])->to_app;
    is(ref($mount_app), 'CODE', 'a standalone mount compiles to an application');
    my $mounted_miss = run_scope($mount_app, scope(
        type => 'websocket', path => '/api/missing',
        extensions => { 'websocket.http.response' => {} },
    ));
    is($mounted_miss->[0]{type}, 'websocket.http.response.start',
        'the inline child owns its protocol-specific miss');
    is($mounted_miss->[0]{status}, 404, 'the inline child emits its complete 404 fallback');
    is(\@trace, ['mount before', 'mount after'],
        'mount middleware surrounds a child protocol miss');
};

subtest 'non-HTTP protocols never observe or replace routing Trace data' => sub {
    my $sentinel = { owner => 'caller', nested => ['unchanged'] };
    my @seen_values;
    my $app = router(routes => [
        websocket('/socket' => async sub {
            push @seen_values, $_[0]->scope->{'pagi.routing.trace'};
            await $_[0]->close(1000, 'matched');
        }),
        sse('/events' => async sub {
            push @seen_values, $_[0]->scope->{'pagi.routing.trace'};
            await $_[0]->close;
        }),
    ])->to_app;

    my $ws_scope = scope(
        type => 'websocket', path => '/socket', raw_path => '/socket',
        'pagi.routing.trace' => $sentinel,
    );
    is(run_scope($app, $ws_scope), [
        { type => 'websocket.close', code => 1000, reason => 'matched' },
    ], 'matched WebSocket events remain byte-for-byte unchanged');
    is($seen_values[-1], $sentinel,
        'WebSocket routing preserves preexisting Trace-key identity');
    is($ws_scope->{'pagi.routing.trace'}, {
        owner => 'caller', nested => ['unchanged'],
    }, 'WebSocket routing preserves preexisting Trace-key contents');

    my $sse_scope = scope(
        type => 'sse', path => '/events', raw_path => '/events',
        'pagi.routing.trace' => $sentinel,
    );
    is(run_scope($app, $sse_scope), [
        { type => 'sse.close' },
    ], 'matched SSE events remain byte-for-byte unchanged');
    is($seen_values[-1], $sentinel,
        'SSE routing preserves preexisting Trace-key identity');

    my $ws_close_scope = scope(
        type => 'websocket', path => '/missing', raw_path => '/missing',
        'pagi.routing.trace' => $sentinel,
    );
    is(run_scope($app, $ws_close_scope), [
        { type => 'websocket.close' },
    ], 'WebSocket close denial remains byte-for-byte unchanged');
    is($ws_close_scope->{'pagi.routing.trace'}, $sentinel,
        'a WebSocket miss preserves preexisting Trace-key identity');

    my $ws_denial_scope = scope(
        type => 'websocket', path => '/missing', raw_path => '/missing',
        extensions => { 'websocket.http.response' => {} },
        'pagi.routing.trace' => $sentinel,
    );
    is(run_scope($app, $ws_denial_scope), [
        {
            type => 'websocket.http.response.start',
            status => 404,
            headers => [['content-type', 'text/plain']],
        },
        {
            type => 'websocket.http.response.body',
            body => 'Not Found',
            more => 0,
        },
    ], 'WebSocket HTTP denial remains byte-for-byte unchanged');

    my $sse_miss_scope = scope(
        type => 'sse', path => '/missing', raw_path => '/missing',
    );
    is(run_scope($app, $sse_miss_scope), [
        {
            type => 'sse.http.response.start',
            status => 404,
            headers => [['content-type', 'text/plain']],
        },
        {
            type => 'sse.http.response.body',
            body => 'Not Found',
            more => 0,
        },
    ], 'SSE decline remains byte-for-byte unchanged with no Trace key');
    ok(!exists $sse_miss_scope->{'pagi.routing.trace'},
        'an absent SSE Trace key remains absent');

    my $lifespan_scope = {
        type => 'lifespan',
        'pagi.routing.trace' => $sentinel,
    };
    is($app->(
        $lifespan_scope,
        sub { return Future->fail('must not receive') },
        sub { return Future->fail('must not send') },
    )->get, undef, 'lifespan completion remains inert');
    is($lifespan_scope->{'pagi.routing.trace'}, $sentinel,
        'lifespan preserves preexisting Trace-key identity and contents');

    my $bare_lifespan_scope = { type => 'lifespan' };
    my $bare_scope_id = refaddr($bare_lifespan_scope);
    is($app->(
        $bare_lifespan_scope,
        sub { return Future->fail('must not receive') },
        sub { return Future->fail('must not send') },
    )->get, undef, 'lifespan without a Trace key remains inert');
    is(refaddr($bare_lifespan_scope), $bare_scope_id,
        'lifespan without a Trace key preserves scope identity');
    ok(!exists $bare_lifespan_scope->{'pagi.routing.trace'},
        'an absent lifespan Trace key remains absent');
};

done_testing;
