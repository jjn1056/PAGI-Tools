#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);

use PAGI::Response;
use PAGI::Routing qw(router route mount middleware);
use PAGI::Routing::Compiler;

sub scope {
    my (%changes) = @_;
    return {
        type        => 'http',
        method      => 'GET',
        path        => '/',
        root_path   => '',
        raw_path    => '/',
        path_params => {},
        headers     => [['accept', 'application/problem+json']],
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

sub run_scope {
    my ($app, $request_scope) = @_;
    my @events;
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    Future->wrap($app->($request_scope, \&receive, $send))->get;
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

sub response_status {
    my ($events) = @_;
    my $start = response_start($events);
    return defined($start) ? $start->{status} : undef;
}

sub response_body {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
}

sub response_headers {
    my ($events, $name) = @_;
    my $start = response_start($events);
    return [] unless $start;
    return [map { $_->[1] }
        grep { lc($_->[0]) eq lc($name) } @{$start->{headers} // []}];
}

sub response_header {
    my ($events, $name) = @_;
    return response_headers($events, $name)->[0];
}

sub text_handler {
    return PAGI::Response->text('matched');
}

sub mangle_allow_middleware {
    my ($mode) = @_;
    return middleware(sub {
        my ($inner) = @_;
        return async sub {
            my ($request_scope, $receive, $send) = @_;
            my $wrapped_send = sub {
                my ($event) = @_;
                if (($event->{type} // '') eq 'http.response.start'
                        && ($event->{status} // 0) == 405) {
                    my @headers = grep {
                        lc($_->[0]) ne 'allow'
                    } @{$event->{headers} // []};
                    push @headers, ['Allow', 'CHILD'], ['allow', 'CHILD']
                        if $mode eq 'duplicate';
                    push @headers, ['ALLOW', 'ROOT-CHANGED']
                        if $mode eq 'change';
                    $event = { %$event, headers => \@headers };
                }
                return Future->wrap($send->($event));
            };
            await Future->wrap(
                $inner->($request_scope, $receive, $wrapped_send),
            );
        };
    });
}

subtest 'Router renders direct NONE and PARTIAL outcomes with negotiated Pages responses' => sub {
    my $app = router(routes => [
        route('/items' => \&text_handler, methods => 'GET'),
        route('/items' => \&text_handler, methods => 'POST'),
    ])->to_app;

    my $none = run_app($app, path => '/missing', raw_path => '/missing');
    is(response_status($none), 404, 'NONE renders 404');
    is(response_header($none, 'Content-Type'), 'application/problem+json',
        'NONE uses normal request negotiation');
    like(response_body($none), qr/"status"\s*:\s*404/,
        'NONE emits the negotiated problem representation');

    my $partial = run_app(
        $app, method => 'TRACE', path => '/items', raw_path => '/items',
    );
    is(response_status($partial), 405, 'PARTIAL renders 405');
    is(response_header($partial, 'Content-Type'), 'application/problem+json',
        'PARTIAL uses normal request negotiation');
    is(response_headers($partial, 'Allow'), ['GET, HEAD, POST'],
        'PARTIAL emits one first-seen method union');
};

subtest 'later FULL and Mount FULL selections retain declaration-order ownership' => sub {
    my @runs;
    my $app = router(routes => [
        route('/items' => sub {
            push @runs, 'discarded GET';
            return PAGI::Response->text('get');
        }, methods => 'GET'),
        route('/items' => sub {
            push @runs, 'later POST';
            return PAGI::Response->text('post');
        }, methods => 'POST'),
        mount('/owned', app => async sub {
            my ($request_scope, $receive, $send) = @_;
            push @runs, 'mounted app';
            await Future->wrap($send->({
                type => 'http.response.start', status => 202,
                headers => [['x-owner', 'mount']],
            }));
            await Future->wrap($send->({
                type => 'http.response.body', body => 'mounted', more => 0,
            }));
        }),
        route('/owned/resource' => sub {
            push @runs, 'later parent';
            return PAGI::Response->text('parent');
        }),
    ])->to_app;

    my $later = run_app(
        $app, method => 'POST', path => '/items', raw_path => '/items',
    );
    is(response_body($later), 'post', 'a later FULL route beats an earlier partial');
    is(\@runs, ['later POST'], 'the discarded partial handler never runs');

    @runs = ();
    my $mounted = run_app(
        $app, path => '/owned/resource', raw_path => '/owned/resource',
    );
    is(response_status($mounted), 202, 'a matching Mount is FULL');
    is(response_body($mounted), 'mounted', 'the mounted application owns its outcome');
    is(\@runs, ['mounted app'], 'parent scanning never resumes after Mount FULL');
};

subtest 'selected endpoint 404 and 405 responses pass through unchanged' => sub {
    my $app = router(routes => [
        route('/explicit-404' => sub {
            return PAGI::Response->text('application missing', status => 404,
                headers => ['X-Origin' => 'handler']);
        }),
        route('/explicit-405' => sub {
            return PAGI::Response->text('application method', status => 405,
                headers => ['Allow' => 'PATCH', 'X-Origin' => 'handler']);
        }),
    ])->to_app;

    my $not_found = run_app(
        $app, path => '/explicit-404', raw_path => '/explicit-404',
    );
    is(response_status($not_found), 404, 'explicit 404 retains status');
    is(response_body($not_found), 'application missing', 'explicit 404 retains body');
    is(response_header($not_found, 'X-Origin'), 'handler',
        'explicit 404 retains headers');

    my $not_allowed = run_app(
        $app, path => '/explicit-405', raw_path => '/explicit-405',
    );
    is(response_status($not_allowed), 405, 'explicit 405 retains status');
    is(response_headers($not_allowed, 'Allow'), ['PATCH'],
        'explicit 405 keeps its endpoint Allow without Router synthesis');
    is(response_header($not_allowed, 'X-Origin'), 'handler',
        'explicit 405 retains unrelated headers');
};

subtest 'custom HTTP default receives NONE only inside selected middleware boundaries' => sub {
    my ($builds, $default_calls) = (0, 0);
    my (@default_seen, @order, @parent_runs);
    my $component = Local::RecordingDefault->new(
        \$builds, \$default_calls, \@default_seen, \@order,
    );
    my ($router_scope, $router_receive, $router_send);
    my $channel_middleware = middleware(sub {
        my ($inner) = @_;
        return async sub {
            ($router_scope, $router_receive, $router_send) = @_;
            push @order, 'child Router before';
            await Future->wrap($inner->(@_));
            push @order, 'child Router after';
        };
    });
    my $mount_middleware = middleware(sub {
        my ($inner) = @_;
        return async sub {
            push @order, 'Mount before';
            await Future->wrap($inner->(@_));
            push @order, 'Mount after';
        };
    });
    my $child = router(
        http_default => $component,
        middleware => [$channel_middleware],
        routes => [
            route('/item' => \&text_handler, methods => 'GET'),
            route('/throws' => sub { die "selected explosion\n" }),
            route('/returned-404' => sub {
                return PAGI::Response->text('selected missing', status => 404);
            }),
        ],
    );
    my $app = router(routes => [
        mount('/left', app => $child, middleware => [$mount_middleware]),
        mount('/right', app => $child),
        route('/left/missing' => sub {
            push @parent_runs, 'later parent';
            return PAGI::Response->text('parent');
        }),
    ])->to_app;
    is($builds, 2, 'the default component is compiled once per Router occurrence');

    my $incoming = scope(path => '/left/missing', raw_path => '/left/missing');
    my @events;
    my $receive = sub { return receive() };
    my $send = sub { push @events, $_[0]; return Future->done };
    Future->wrap($app->($incoming, $receive, $send))->get;
    is(response_status(\@events), 418, 'the selected child default emits its response');
    is(\@order, [
        'Mount before', 'child Router before', 'HTTP default',
        'child Router after', 'Mount after',
    ], 'HTTP default runs inside Mount and Router middleware');
    my $seen = $default_seen[0] // {};
    my $seen_scope = ref($seen->{scope}) eq 'HASH' ? $seen->{scope} : {};
    is(refaddr($seen->{scope}), refaddr($router_scope),
        'HTTP default receives the current Router scope by identity');
    is(refaddr($seen->{receive}), refaddr($router_receive),
        'HTTP default receives the current Router receive channel');
    is(refaddr($seen->{send}), refaddr($router_send),
        'HTTP default receives the current Router send channel');
    is([@{$seen_scope}{qw(path root_path)}], ['/missing', '/left'],
        'HTTP default sees the selected child Router path boundary');
    is(\@parent_runs, [], 'child NONE never resumes later parent scanning');

    my $before = $default_calls;
    my $partial = run_app(
        $app, method => 'POST', path => '/left/item', raw_path => '/left/item',
    );
    is(response_status($partial), 405, 'PARTIAL renders independently');
    is($default_calls, $before, 'PARTIAL does not invoke HTTP default');

    my $returned = run_app(
        $app, path => '/left/returned-404', raw_path => '/left/returned-404',
    );
    is(response_body($returned), 'selected missing',
        'a handler-returned 404 passes through');
    is($default_calls, $before, 'a selected handler 404 does not invoke HTTP default');

    like(dies {
        run_app($app, path => '/left/throws', raw_path => '/left/throws');
    }, qr/selected explosion/, 'selected exceptions propagate');
    is($default_calls, $before, 'selected exceptions do not invoke HTTP default');

    my $websocket = run_scope($app, scope(
        type => 'websocket', method => undef,
        path => '/left/missing', raw_path => '/left/missing', headers => [],
    ));
    is($websocket, [{ type => 'websocket.close' }],
        'WebSocket NONE retains the stock close outcome');
    my $sse = run_scope($app, scope(
        type => 'sse', method => undef,
        path => '/left/missing', raw_path => '/left/missing', headers => [],
    ));
    is($sse->[0]{type}, 'sse.http.response.start',
        'SSE NONE retains the stock response family');
    is($default_calls, $before, 'protocol NONE never invokes HTTP default');
};

subtest 'the root boundary repairs Router-generated Allow after all routing middleware' => sub {
    my $child = router(
        middleware => [mangle_allow_middleware('duplicate')],
        routes => [
            route('/item' => \&text_handler, methods => 'GET'),
            route('/item' => \&text_handler, methods => 'POST'),
            route('/endpoint' => sub {
                return PAGI::Response->text('endpoint', status => 405,
                    headers => ['Allow' => 'PATCH']);
            }),
        ],
    );
    my $app = router(
        middleware => [mangle_allow_middleware('change')],
        routes => [
            mount('/api', app => $child,
                middleware => [mangle_allow_middleware('delete')]),
        ],
    )->to_app;

    my $generated = run_app(
        $app, method => 'TRACE', path => '/api/item', raw_path => '/api/item',
    );
    is(response_status($generated), 405, 'the child Router generates 405');
    is(response_headers($generated, 'Allow'), ['GET, HEAD, POST'],
        'one authoritative first-seen Allow survives child, Mount, and Router changes');

    my $endpoint = run_app(
        $app, path => '/api/endpoint', raw_path => '/api/endpoint',
    );
    is(response_headers($endpoint, 'Allow'), ['ROOT-CHANGED'],
        'endpoint-produced 405 remains subject only to ordinary middleware');
};

subtest 'standalone compilation owns Router outcomes and middleware graphs remain fresh' => sub {
    my $description = router(routes => [
        route('/standalone' => sub { return PAGI::Response->text('standalone') }),
    ]);
    is(ref(PAGI::Routing::Compiler->compile($description)), 'CODE',
        'Compiler compiles a Router to CODE');
    is(ref($description->to_app), 'CODE', 'Router to_app returns CODE');

    my $standalone = route('/standalone' => sub {
        return PAGI::Response->text('standalone');
    })->to_app;
    is(response_body(run_app($standalone, path => '/standalone')), 'standalone',
        'standalone Route handles FULL');
    is(response_status(run_app(
        $standalone, method => 'POST', path => '/standalone',
    )), 405, 'standalone Route owns PARTIAL');
    is(response_status(run_app($standalone, path => '/missing')), 404,
        'standalone Route owns NONE');

    my $builds = 0;
    my @instances;
    my $descriptor = middleware(sub {
        my ($inner) = @_;
        my $instance = ++$builds;
        return sub {
            push @instances, $instance;
            return $inner->(@_);
        };
    });
    my $routing = router(routes => [
        route('/fresh' => sub { return PAGI::Response->text('fresh') },
            middleware => [$descriptor]),
    ]);
    my $first = $routing->to_app;
    my $second = $routing->to_app;
    run_app($first, path => '/fresh');
    run_app($first, path => '/fresh');
    run_app($second, path => '/fresh');
    is($builds, 2, 'each compiled graph resolves middleware once');
    is(\@instances, [1, 1, 2], 'compiled graphs retain independent instances');
};

{
    package Local::RecordingDefault;

    sub new {
        my ($class, $builds, $calls, $seen, $order) = @_;
        return bless {
            builds => $builds,
            calls  => $calls,
            seen   => $seen,
            order  => $order,
        }, $class;
    }

    sub to_app {
        my ($self) = @_;
        my $occurrence = ++${$self->{builds}};
        return async sub {
            my ($scope, $receive, $send) = @_;
            ++${$self->{calls}};
            push @{$self->{order}}, 'HTTP default';
            push @{$self->{seen}}, {
                occurrence => $occurrence,
                scope      => $scope,
                receive    => $receive,
                send       => $send,
            };
            await Future->wrap($send->({
                type => 'http.response.start', status => 418,
                headers => [['content-type', 'text/plain']],
            }));
            await Future->wrap($send->({
                type => 'http.response.body', body => 'custom default', more => 0,
            }));
        };
    }
}

done_testing;
