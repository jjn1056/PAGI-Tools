#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);

use PAGI::Response;
use PAGI::Routing qw(router route websocket sse mount middleware);

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
    my $receive = $channels{receive} || sub {
        return Future->done({ type => 'http.request', body => '', more => 0 });
    };
    my $send = $channels{send} || sub {
        push @events, $_[0];
        return Future->done;
    };
    $app->($request_scope, $receive, $send)->get;
    return \@events;
}

sub run_app {
    my ($app, %changes) = @_;
    return run_scope($app, scope(%changes));
}

sub response_start {
    my ($events) = @_;
    return (grep { ($_->{type} // '') eq 'http.response.start' } @$events)[0];
}

sub response_body {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
}

sub response_header {
    my ($events, $name) = @_;
    my $start = response_start($events);
    return unless $start;
    for my $pair (@{$start->{headers} // []}) {
        return $pair->[1] if lc($pair->[0]) eq lc($name);
    }
    return;
}

sub tracing_middleware {
    my ($label, $trace) = @_;
    return middleware(sub {
        my ($inner) = @_;
        return async sub {
            push @$trace, "$label before";
            my $returned = $inner->(@_);
            await Future->wrap($returned);
            push @$trace, "$label after";
        };
    });
}

sub body_header_middleware {
    my ($header) = @_;
    return middleware(sub {
        my ($inner) = @_;
        return async sub {
            my ($request_scope, $receive, $send) = @_;
            my @events;
            my $capture = sub {
                push @events, $_[0];
                return Future->done;
            };
            my $returned = $inner->($request_scope, $receive, $capture);
            await Future->wrap($returned);

            my $bytes = 0;
            for my $event (@events) {
                $bytes += length($event->{body} // '')
                    if ($event->{type} // '') eq 'http.response.body';
            }
            for my $event (@events) {
                if (($event->{type} // '') eq 'http.response.start') {
                    $event = {
                        %$event,
                        headers => [@{$event->{headers} // []}, [$header => $bytes]],
                    };
                }
                await $send->($event);
            }
        };
    });
}

sub after_metadata_middleware {
    my ($observations) = @_;
    return middleware(sub {
        my ($inner) = @_;
        return async sub {
            my ($request_scope) = @_;
            my $returned = $inner->(@_);
            await Future->wrap($returned);
            push @$observations, snapshot_frame($request_scope);
        };
    });
}

sub snapshot_frame {
    my ($request_scope) = @_;
    my $frames = $request_scope->{'pagi.routing'}{frames};
    my $frame = $frames->[-1];
    return {
        frame_count => scalar @$frames,
        mounts => [map { +{%$_} } @{$frame->{mounts}}],
        match => defined $frame->{match} ? { %{$frame->{match}} } : undef,
    };
}

subtest 'a Router mount transfers HTTP ownership to child outcomes' => sub {
    my @parent_calls;
    my $child = router(
        routes => [
            route('/item' => sub { return $_[0]->text('child GET') },
                methods => 'GET'),
            route('/application-404' => sub {
                return $_[0]->response
                    ->status(404)
                    ->header('X-Origin' => 'handler')
                    ->text('handler missing');
            }),
        ],
        not_found => sub { return $_[0]->text('child custom missing') },
        method_not_allowed => sub {
            return PAGI::Response->new->status(405)->text('child custom method');
        },
    );
    my $app = router(routes => [
        route('/api/item' => sub {
            push @parent_calls, 'earlier partial';
            return $_[0]->text('parent PATCH');
        }, methods => 'PATCH'),
        mount('/api', router => $child, namespace => 'child'),
        route('/api/item' => sub {
            push @parent_calls, 'later full item';
            return $_[0]->text('parent PUT');
        }, methods => 'PUT'),
        route('/api/missing' => sub {
            push @parent_calls, 'later full missing';
            return $_[0]->text('parent resumed');
        }),
    ])->to_app;

    my $full = run_app($app, path => '/api/item', raw_path => '/api/item');
    is(response_body($full), 'child GET', 'a child FULL result owns the request');

    my $partial = run_app(
        $app, method => 'PUT', path => '/api/item', raw_path => '/api/item',
    );
    is(response_start($partial)->{status}, 405, 'a child PARTIAL result remains final');
    is(response_header($partial, 'Allow'), 'GET, HEAD',
        'a detached child 405 receives only the child Allow set');
    is(response_body($partial), 'child custom method', 'the child custom 405 body wins');

    my $none = run_app($app, path => '/api/missing', raw_path => '/api/missing');
    is(response_start($none)->{status}, 404, 'a child NONE result remains final');
    is(response_body($none), 'child custom missing', 'the child custom 404 body wins');

    my $application = run_app(
        $app, path => '/api/application-404', raw_path => '/api/application-404',
    );
    is(response_start($application)->{status}, 404,
        'a fully matched handler-returned 404 passes through');
    is(response_header($application, 'X-Origin'), 'handler',
        'the handler-returned 404 keeps application headers');
    is(response_body($application), 'handler missing',
        'the handler-returned 404 keeps its body');
    is(\@parent_calls, [], 'no parent handler runs after Router-mount ownership transfers');
};

subtest 'Router-mount middleware order, metadata, compilation freshness, and immutability' => sub {
    my @trace;
    my @metadata;
    my @after_metadata;
    my $builds = 0;
    my $stateful = middleware(sub {
        my ($inner) = @_;
        my $identity = ++$builds;
        return sub {
            my ($request_scope, $receive, $send) = @_;
            return $inner->({ %$request_scope, 'router-mount.build' => $identity },
                $receive, $send);
        };
    });
    my $child = router(
        middleware => [tracing_middleware('child Router', \@trace), $stateful],
        routes => [
            mount('/inline', routes => [
                route('/item' => sub {
                    my ($c) = @_;
                    push @trace, 'handler';
                    push @metadata, snapshot_frame($c->scope);
                    return $c->text($c->scope->{'router-mount.build'});
                }, name => 'item', middleware => [tracing_middleware('route', \@trace)]),
            ], namespace => 'inline', middleware => [tracing_middleware('inline mount', \@trace)]),
        ],
        not_found => sub {
            push @trace, 'child 404';
            return $_[0]->text('missing');
        },
        method_not_allowed => sub {
            push @trace, 'child 405';
            return $_[0]->text('method');
        },
    );

    my $routes_before = [map { refaddr($_) } @{$child->routes}];
    my $named_before = { map { $_ => refaddr($child->named_routes->{$_}) }
        keys %{$child->named_routes} };
    my $middleware_before = [map { refaddr($_) } @{$child->middleware}];
    my $path_before = $child->path_for('/inline/item');

    my $outer = router(
        middleware => [
            tracing_middleware('outer Router', \@trace),
            after_metadata_middleware(\@after_metadata),
        ],
        routes => [
            mount('/left', router => $child, namespace => 'left',
                desc => 'Left child', middleware => [tracing_middleware('Router mount', \@trace)]),
            mount('/right', router => $child, namespace => 'right'),
        ],
    );
    my $first_app = $outer->to_app;
    my $second_app = $outer->to_app;
    is($builds, 4, 'two placements in each outer compilation build four fresh child wrappers');

    my $left = run_app(
        $first_app, path => '/left/inline/item', raw_path => '/left/inline/item',
    );
    is(response_body($left), '1', 'the first placement uses its own middleware build identity');
    is(\@trace, [
        'outer Router before', 'Router mount before', 'child Router before',
        'inline mount before', 'route before', 'handler', 'route after',
        'inline mount after', 'child Router after', 'Router mount after',
        'outer Router after',
    ], 'middleware order is outer Router, Router mount, child Router, inline mount, route, handler');
    is($metadata[-1], {
        frame_count => 1,
        mounts => [
            { path => '/left', namespace => 'left', desc => 'Left child' },
            { path => '/inline', namespace => 'inline', desc => undef },
        ],
        match => {
            kind => 'route', route => '/left/inline/item',
            name => '/left/inline/item', logical_namespace => '/left/inline',
            desc => undef,
        },
    }, 'the child leaf publishes composed metadata in the one root routing frame');
    is($after_metadata[-1], $metadata[-1],
        'outer Router middleware sees the complete child match after downstream');

    @trace = ();
    is(response_body(run_app(
        $first_app, path => '/right/inline/item', raw_path => '/right/inline/item',
    )), '2', 'the second placement has independent compiled middleware state');
    is(response_body(run_app(
        $second_app, path => '/left/inline/item', raw_path => '/left/inline/item',
    )), '3', 'a second outer to_app compilation builds another fresh first placement');

    @trace = ();
    run_app($first_app, path => '/left/missing', raw_path => '/left/missing');
    is(\@trace, [
        'outer Router before', 'Router mount before', 'child Router before',
        'child 404', 'child Router after', 'Router mount after', 'outer Router after',
    ], 'child generated 404 remains inside child, mount, and outer Router middleware');
    is($after_metadata[-1], {
        frame_count => 1,
        mounts => [
            { path => '/left', namespace => 'left', desc => 'Left child' },
        ],
        match => undef,
    }, 'outer middleware sees the Router placement after a child-generated 404');
    @trace = ();
    run_app(
        $first_app, method => 'POST',
        path => '/left/inline/item', raw_path => '/left/inline/item',
    );
    is(\@trace, [
        'outer Router before', 'Router mount before', 'child Router before',
        'inline mount before', 'child 405', 'inline mount after',
        'child Router after', 'Router mount after', 'outer Router after',
    ], 'child generated 405 is wrapped by the selected inline ancestry too');
    is($after_metadata[-1], {
        frame_count => 1,
        mounts => [
            { path => '/left', namespace => 'left', desc => 'Left child' },
            { path => '/inline', namespace => 'inline', desc => undef },
        ],
        match => undef,
    }, 'outer middleware sees the complete ancestry after a child-generated 405');

    is([map { refaddr($_) } @{$child->routes}], $routes_before,
        'composition preserves child route identities');
    is({ map { $_ => refaddr($child->named_routes->{$_}) } keys %{$child->named_routes} },
        $named_before, 'composition preserves the child named-route view');
    is([map { refaddr($_) } @{$child->middleware}], $middleware_before,
        'composition preserves child middleware descriptions');
    is($child->path_for('/inline/item'), $path_before,
        'composition preserves child-local reverse routing');
};

subtest 'relative child links follow the active Router placement without mutating the child' => sub {
    my @seen;
    my $child = router(routes => [
        route('/{person_id}' => sub {
            my ($c) = @_;
            my $frame = $c->scope->{'pagi.routing'}{frames}[-1];
            push @seen, {
                path => $c->path_for('show'),
                namespace => $frame->{logical_namespace},
                captures => { %{$frame->{captures}} },
            };
            return $c->text('person');
        }, name => 'show'),
    ]);
    my $outer = router(routes => [
        mount('/authors', router => $child, namespace => 'authors'),
        mount('/editors', router => $child, namespace => 'editors'),
    ]);
    my $app = $outer->to_app;

    run_app($app, path => '/authors/42', raw_path => '/authors/42');
    run_app($app, path => '/editors/42', raw_path => '/editors/42');

    is(\@seen, [
        {
            path => '/authors/42',
            namespace => '/authors',
            captures => { person_id => 42 },
        },
        {
            path => '/editors/42',
            namespace => '/editors',
            captures => { person_id => 42 },
        },
    ], 'one child handler resolves through the request-local active placement');
    is($child->path_for('show', { person_id => 42 }), '/42',
        'the reused child Router remains local and contains neither parent prefix');
};

subtest 'Router mounts share the one outer HEAD edge and root mounts consume nothing' => sub {
    my @seen_scopes;
    my $child = router(
        middleware => [
            body_header_middleware('X-Child-Bytes'),
            middleware('ContentLength'),
        ],
        routes => [
            route('/body' => sub {
                my ($c) = @_;
                push @seen_scopes, snapshot_frame($c->scope);
                return $c->text('representation');
            }),
            route('/file', raw => async sub {
                my ($request_scope, $receive, $send) = @_;
                await $send->({
                    type => 'http.response.start', status => 200,
                    headers => [['content-length' => 37]],
                });
                await $send->({
                    type => 'http.response.body', file => 'must-not-open',
                    offset => 4, length => 37,
                });
            }),
        ],
    );
    my $app = router(routes => [
        mount('/api', router => $child, namespace => 'api',
            middleware => [body_header_middleware('X-Mount-Bytes')]),
    ])->to_app;

    my $get = run_app($app, path => '/api/body', raw_path => '/api/body');
    my $head = run_app(
        $app, method => 'HEAD', path => '/api/body', raw_path => '/api/body',
    );
    for my $header (qw(Content-Length X-Child-Bytes X-Mount-Bytes)) {
        is(response_header($head, $header), response_header($get, $header),
            "HEAD preserves GET-equivalent $header after mounted middleware");
    }
    is(response_header($head, 'Content-Length'), 14,
        'the mounted child calculates representation length before suppression');
    is([grep { ($_->{type} // '') eq 'http.response.body' } @$head], [
        { type => 'http.response.body', body => '', more => 0 },
    ], 'the one outer HEAD edge emits only an empty terminal body');
    is([map { $_->{frame_count} } @seen_scopes], [1, 1],
        'GET and HEAD each install only the root routing frame');

    my $file_open_attempts = 0;
    my @transport_events;
    my $transport = sub {
        my ($event) = @_;
        ++$file_open_attempts if exists $event->{file};
        push @transport_events, $event;
        return Future->done;
    };
    run_scope($app, scope(
        method => 'HEAD', path => '/api/file', raw_path => '/api/file',
    ), send => $transport);
    is($file_open_attempts, 0, 'a mounted sendfile event never reaches HEAD transport');
    is($transport_events[-1], { type => 'http.response.body', body => '', more => 0 },
        'the mounted sendfile descriptor is replaced only at the outer edge');

    my @root_scope;
    my $root = router(routes => [
        mount('/', router => router(routes => [
            route('/item' => sub {
                my ($c) = @_;
                push @root_scope, [@{$c->scope}{qw(path root_path)}];
                return $c->text('root child');
            }),
        ]), namespace => 'root'),
    ])->to_app;
    is(response_body(run_app(
        $root, path => '/item', root_path => '/edge', raw_path => '/edge/item',
    )), 'root child', 'a root Router mount dispatches without adding a slash');
    is(\@root_scope, [['/item', '/edge']],
        'a root Router mount consumes no path and leaves root_path unchanged');
};

subtest 'Router mounts own WebSocket and SSE success and miss outcomes' => sub {
    my @http_fallback_calls;
    my $child = router(
        routes => [
            websocket('/socket' => sub {
                $_[0]->close(1000, 'child')->get;
                return 'synchronous websocket completion';
            }),
            sse('/events' => sub {
                $_[0]->start(status => 202)->get;
                $_[0]->send('child')->get;
                $_[0]->close->get;
                return Future->done('future SSE completion');
            }),
        ],
        not_found => sub {
            push @http_fallback_calls, 'child HTTP 404';
            return $_[0]->text('must not run');
        },
    );
    my @parent_protocol_calls;
    my $app = router(routes => [
        mount('/api', router => $child, namespace => 'api'),
        websocket('/api/missing' => sub {
            push @parent_protocol_calls, 'parent websocket';
            return Future->done;
        }),
        sse('/api/missing' => sub {
            push @parent_protocol_calls, 'parent sse';
            return Future->done;
        }),
    ])->to_app;

    is(run_scope($app, scope(
        type => 'websocket', method => undef,
        path => '/api/socket', raw_path => '/api/socket',
    )), [{ type => 'websocket.close', code => 1000, reason => 'child' }],
        'the mounted child WebSocket owns its exact emitted event');
    is(run_scope($app, scope(
        type => 'sse', method => undef,
        path => '/api/events', raw_path => '/api/events',
    )), [
        { type => 'sse.start', status => 202 },
        { type => 'sse.send', data => 'child' },
        { type => 'sse.close' },
    ], 'the mounted child SSE owns its exact emitted events');

    is(run_scope($app, scope(
        type => 'websocket', method => undef,
        path => '/api/missing', raw_path => '/api/missing',
        extensions => { 'websocket.http.response' => {} },
    )), [
        {
            type => 'websocket.http.response.start', status => 404,
            headers => [['content-type', 'text/plain']],
        },
        {
            type => 'websocket.http.response.body', body => 'Not Found', more => 0,
        },
    ], 'a mounted unmatched WebSocket owns its HTTP denial without rewriting');
    is(run_scope($app, scope(
        type => 'websocket', method => undef,
        path => '/api/missing', raw_path => '/api/missing',
    )), [{ type => 'websocket.close' }],
        'a mounted unmatched WebSocket owns its close outcome');
    is(run_scope($app, scope(
        type => 'sse', method => undef,
        path => '/api/missing', raw_path => '/api/missing',
    )), [
        {
            type => 'sse.http.response.start', status => 404,
            headers => [['content-type', 'text/plain']],
        },
        { type => 'sse.http.response.body', body => 'Not Found', more => 0 },
    ], 'a mounted unmatched SSE owns its decline event family');
    is(\@http_fallback_calls, [], 'protocol misses never invoke child HTTP handlers');
    is(\@parent_protocol_calls, [], 'protocol ownership never resumes parent scanning');
};

done_testing;
