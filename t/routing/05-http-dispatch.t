#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);

use PAGI::App::Router;
use PAGI::Response;
use PAGI::Response::Text ();
use PAGI::Routing qw(router route middleware);
use PAGI::Routing::Compiler;
use PAGI::Utils qw(as_app);

sub HttpProvider { return qr/accepted/ }

sub channels {
    my @events;
    my $receive = sub {
        return Future->done({
            type => 'http.request',
            body => '',
            more => 0,
        });
    };
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    return ($receive, $send, \@events);
}

sub scope {
    my (%changes) = @_;
    return {
        type    => 'http',
        method  => 'GET',
        path    => '/',
        headers => [],
        %changes,
    };
}

sub compiled_entries {
    return [
        map {
            {
                route => $_,
                app   => PAGI::Routing::Compiler->_compile_http_leaf($_),
            }
        } @_
    ];
}

sub response_body {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
}

sub allow_header {
    my ($events) = @_;
    my ($start) = grep { ($_->{type} // '') eq 'http.response.start' } @$events;
    return unless $start;
    for my $pair (@{$start->{headers} // []}) {
        return $pair->[1] if lc($pair->[0]) eq 'allow';
    }
    return;
}

subtest 'normal HTTP leaves receive one exact Request and await one response emission' => sub {
    my @requests;
    my @argument_counts;
    my @call_contexts;
    my $sync = route '/items/{id}' => sub {
        push @argument_counts, scalar @_;
        push @call_contexts, defined wantarray ? (wantarray ? 'list' : 'scalar') : 'void';
        my ($request) = @_;
        push @requests, $request;
        return PAGI::Response::Text->new('item ' . $request->path_param('id'));
    };
    my $sync_app = PAGI::Routing::Compiler->_compile_http_leaf($sync);
    my ($receive, $send, $events) = channels();
    my $request_scope = scope(
        path => '/items/42',
        path_params => { id => '42' },
    );

    $sync_app->($request_scope, $receive, $send)->get;

    isa_ok($requests[0], ['PAGI::Request']);
    is(\@argument_counts, [1], 'normal handler receives exactly one Request');
    is(\@call_contexts, ['scalar'], 'normal handler is invoked in scalar context');
    is(refaddr($requests[0]->scope), refaddr($request_scope),
        'Request retains the exact selected scope');
    is($requests[0]->path_params, { id => '42' },
        'Request sees selected path parameters');
    is(response_body($events), 'item 42', 'immediate Response is emitted');
    is(
        [map { $_->{type} } @$events],
        [qw(http.response.start http.response.body)],
        'one immediate Response produces one response event pair',
    );

    my $body_reads = 0;
    my $future = route '/future' => async sub {
        my ($request) = @_;
        my $body = await $request->body;
        return PAGI::Response::Text->new("future $body");
    };
    my $future_app = PAGI::Routing::Compiler->_compile_http_leaf($future);
    $receive = sub {
        ++$body_reads;
        return Future->done({
            type => 'http.request', body => 'response', more => 0,
        });
    };
    my @future_events;
    $send = sub { push @future_events, $_[0]; return Future->done };
    $events = \@future_events;
    $future_app->(scope(path => '/future'), $receive, $send)->get;
    is(response_body($events), 'future response', 'Future-resolved Response is emitted');
    is($body_reads, 1, 'Request body reads from the exact receive channel');

    my $count = 0;
    my @respond_sends;
    my $respond_completion = Future->new;
    my $counted = Local::CountedResponse->new(
        \$count,
        \@respond_sends,
        $respond_completion,
    );
    my $counted_app = PAGI::Routing::Compiler->_compile_http_leaf(
        route('/counted' => sub { return $counted }),
    );
    ($receive, $send, $events) = channels();
    my $counted_scope = scope(path => '/counted');
    my $running = $counted_app->($counted_scope, $receive, $send);
    ok(!$running->is_ready, 'adapter awaits the response emission Future');
    is($count, 1, 'adapter asks the response value to emit exactly once');
    is(\@respond_sends, [[$counted_scope, $receive, $send]],
        'adapter passes the exact native triplet to respond');
    $respond_completion->done;
    is($running->get, undef, 'adapter completes only after response emission');
};

subtest 'instantiated Response route targets compile once and retain normal routing boundaries' => sub {
    my $response = PAGI::Response::Text->new('root');
    my @middleware;
    my $app = router(routes => [
        route('/' => $response,
            name => 'root', desc => 'component root', methods => 'GET',
            constraints => {}, middleware => [middleware(sub {
                my ($inner) = @_;
                return async sub {
                    push @middleware, $_[0]{method};
                    await Future->wrap($inner->(@_));
                };
            })]),
    ])->to_app;

    my ($get_receive, $get_send, $get_events) = channels();
    $app->(scope(path => '/', method => 'GET'), $get_receive, $get_send)->get;
    is(response_body($get_events), 'root', 'component route emits its response');
    is(\@middleware, ['GET'], 'route middleware remains outside the component');

    my ($head_receive, $head_send, $head_events) = channels();
    $app->(scope(path => '/', method => 'HEAD'), $head_receive, $head_send)->get;
    is($head_events->[-1], { type => 'http.response.body', body => '', more => 0 },
        'component route remains inside the HEAD boundary');

    my ($post_receive, $post_send, $post_events) = channels();
    $app->(scope(path => '/', method => 'POST'), $post_receive, $post_send)->get;
    is($post_events->[0]{status}, 405, 'component route contributes a normal partial outcome');
    is(allow_header($post_events), 'GET, HEAD', 'component route contributes normalized Allow methods');

    my ($left_receive, $left_send, $left_events) = channels();
    my ($right_receive, $right_send, $right_events) = channels();
    Future->needs_all(
        $app->(scope(path => '/', method => 'GET'), $left_receive, $left_send),
        $app->(scope(path => '/', method => 'GET'), $right_receive, $right_send),
    )->get;
    is([response_body($left_events), response_body($right_events)], ['root', 'root'],
        'concurrent component requests receive independent emissions');
};

subtest 'component routes retain ordinary Route matching, methods, and compilation ownership' => sub {
    my $component = Local::CountingComponent->new('component');
    my $fallback = route('/component/{id}' => sub {
        return PAGI::Response::Text->new('fallback ' . $_[0]->path_param('id'));
    });
    my $node = route('/component/{id}' => $component,
        name => 'component', desc => 'component target',
        constraints => { id => qr/\Aok\z/ });
    is([$node->name, $node->desc], ['component', 'component target'],
        'component Route retains name and description metadata');
    my $router = router(routes => [$node, $fallback]);
    my $app = $router->to_app;
    is($component->compilations, 1, 'component to_app runs once for the first compilation');

    my ($receive, $send, $events) = channels();
    $app->(scope(path => '/component/ok', method => 'GET'), $receive, $send)->get;
    is(response_body($events), 'component', 'a passing component constraint selects the component');
    ($receive, $send, $events) = channels();
    $app->(scope(path => '/component/no', method => 'GET'), $receive, $send)->get;
    is(response_body($events), 'fallback no', 'a failing component constraint falls through');

    ($receive, $send, $events) = channels();
    $app->(scope(path => '/component/ok', method => 'HEAD'), $receive, $send)->get;
    is($events->[-1], { type => 'http.response.body', body => '', more => 0 },
        'omitted component methods include automatic HEAD');
    ($receive, $send, $events) = channels();
    $app->(scope(path => '/component/ok', method => 'POST'), $receive, $send)->get;
    is(allow_header($events), 'GET, HEAD', 'omitted component methods produce GET and HEAD Allow');

    my $post_component = Local::CountingComponent->new('post');
    my $post_app = router(routes => [
        route('/explicit' => $post_component, methods => 'POST'),
    ])->to_app;
    ($receive, $send, $events) = channels();
    $post_app->(scope(path => '/explicit', method => 'POST'), $receive, $send)->get;
    is(response_body($events), 'post', 'explicit component methods are honored');
    ($receive, $send, $events) = channels();
    $post_app->(scope(path => '/explicit', method => 'GET'), $receive, $send)->get;
    is(allow_header($events), 'POST', 'explicit component methods control Allow');

    my $root = Local::CountingComponent->new('root');
    my $wildcard = Local::CountingComponent->new('wildcard');
    my $paths = router(routes => [
        route('/' => $root), route('/*path' => $wildcard),
    ])->to_app;
    ($receive, $send, $events) = channels();
    $paths->(scope(path => '/'), $receive, $send)->get;
    is(response_body($events), 'root', 'an exact root component matches root');
    ($receive, $send, $events) = channels();
    $paths->(scope(path => '/child'), $receive, $send)->get;
    is(response_body($events), 'wildcard', 'an explicit catch-all component matches a child path');

    my @components = map { Local::CountingComponent->new($_) } qw(get post put);
    my $union = router(routes => [
        route('/union' => $components[0], methods => 'GET'),
        route('/union' => $components[1], methods => 'POST'),
        route('/union' => $components[2], methods => 'PUT'),
    ])->to_app;
    ($receive, $send, $events) = channels();
    $union->(scope(path => '/union', method => 'TRACE'), $receive, $send)->get;
    is($events->[0]{status}, 405, 'component routes produce the generated 405');
    is(allow_header($events), 'GET, HEAD, POST, PUT',
        'component routes retain first-seen multi-route Allow union');

    my $second = $router->to_app;
    is($component->compilations, 2, 'a fresh Router compilation calls component to_app once');
    for my $compiled ($app, $second) {
        ($receive, $send, $events) = channels();
        $compiled->(scope(path => '/component/ok'), $receive, $send)->get;
    }
    is($component->compilations, 2, 'component to_app is never called per request');
};

subtest 'one unchanged component isolates overlapping native invocations' => sub {
    my $component = Local::BarrierComponent->new;
    my $app = router(routes => [route('/overlap' => $component)])->to_app;
    my ($left_gate, $right_gate) = (Future->new, Future->new);
    my (@left, @right);
    my ($left_sends, $right_sends) = (0, 0);
    my $left_send = sub {
        push @left, $_[0];
        return ++$left_sends == 1 ? $left_gate : Future->done;
    };
    my $right_send = sub {
        push @right, $_[0];
        return ++$right_sends == 1 ? $right_gate : Future->done;
    };
    my ($left_receive) = channels();
    my ($right_receive) = channels();
    my $left_running = $app->(scope(path => '/overlap'), $left_receive, $left_send);
    my $right_running = $app->(scope(path => '/overlap'), $right_receive, $right_send);
    is($component->invocations, 2, 'both component invocations reached their send barriers');
    ok(!$left_running->is_ready && !$right_running->is_ready,
        'both requests remain pending while their own sends are blocked');
    isnt($left[0]{headers}[0][1], $right[0]{headers}[0][1],
        'overlapping requests receive distinct invocation-local metadata');
    $right_gate->done;
    $left_gate->done;
    Future->needs_all($left_running, $right_running)->get;
    is([response_body(\@left), response_body(\@right)], ['overlap 1', 'overlap 2'],
        'each overlapped invocation completes with its own response state');
};

subtest 'CODE endpoints remain handlers while as_app marks native CODE' => sub {
    my $ordinary = route('/ordinary' => sub {
        return PAGI::Response::Text->new(ref($_[0]));
    })->to_app;
    my ($receive, $send, $events) = channels();
    $ordinary->(scope(path => '/ordinary'), $receive, $send)->get;
    is(response_body($events), 'PAGI::Request',
        'ordinary Route coderefs receive one Request');

    my $native = async sub {
        my ($request_scope, $native_receive, $native_send) = @_;
        die 'native app requires HTTP scope'
            unless ref($request_scope) eq 'HASH'
                && ($request_scope->{type} // '') eq 'http';
        await $native_send->({
            type => 'http.response.start', status => 204, headers => [],
        });
        await $native_send->({
            type => 'http.response.body', body => '', more => 0,
        });
    };
    my $native_app = route('/native' => as_app($native))->to_app;
    ($receive, $send, $events) = channels();
    $native_app->(scope(path => '/native'), $receive, $send)->get;
    is($events->[0]{status}, 204,
        'as_app is the explicit native-coderef spelling');
};

subtest 'raw HTTP leaves are coerced once and retain ownership of all channels' => sub {
    my $coercions = 0;
    my @received;
    my $component = Local::RawComponent->new(
        \$coercions,
        sub {
            push @received, [@_];
            my ($scope, $receive, $send) = @_;
            $send->({
                type => 'http.response.start',
                status => 204,
                headers => [],
            })->get;
            $send->({
                type => 'http.response.body',
                body => '',
                more => 0,
            })->get;
            return Future->done('raw result is inert');
        },
    );
    my $raw = route '/raw' => $component;
    my $app = PAGI::Routing::Compiler->_compile_http_leaf($raw);
    is($coercions, 1, 'raw component is coerced at compile time');

    my ($receive, $send, $events) = channels();
    my $request_scope = scope(path => '/raw', marker => 'original');
    my $resolved = $app->($request_scope, $receive, $send)->get;

    is($coercions, 1, 'raw component is not recoerced per request');
    is(scalar @received, 1, 'raw app is invoked once');
    is(scalar @{$received[0]}, 3, 'raw app receives all three PAGI channels');
    is(refaddr($received[0][0]), refaddr($request_scope), 'raw app receives the supplied scope by identity');
    is(refaddr($received[0][1]), refaddr($receive), 'raw app owns receive by identity');
    is(refaddr($received[0][2]), refaddr($send), 'raw app owns send by identity');
    is($resolved, undef, 'raw app resolved value is ignored');
    is(
        [map { $_->{type} } @$events],
        [qw(http.response.start http.response.body)],
        'raw app emits its own response events',
    );
};

subtest 'provider constraints select normal and raw HTTP leaves before invocation' => sub {
    my (@normal, @raw);
    my $app = router(routes => [
        route('/normal/{id:&HttpProvider}' => sub {
            my ($request) = @_;
            push @normal, $request->path_param('id');
            return PAGI::Response::Text->new(
                'provider ' . $request->path_param('id'),
            );
        }),
        route('/normal/rejected' => sub {
            return PAGI::Response::Text->new('continued');
        }),
        route('/raw/{id:&HttpProvider}' => as_app(sub {
            my ($request_scope, $receive, $send) = @_;
            push @raw, $request_scope->{path_params}{id};
            $send->({
                type => 'http.response.start', status => 204, headers => [],
            })->get;
            $send->({
                type => 'http.response.body', body => '', more => 0,
            })->get;
            return Future->done;
        })),
    ])->to_app;

    my $run = sub {
        my ($path) = @_;
        my ($receive, $send, $events) = channels();
        $app->(scope(path => $path), $receive, $send)->get;
        return $events;
    };

    is(response_body($run->('/normal/accepted')), 'provider accepted',
        'an accepted provider capture reaches a normal HTTP handler unchanged');
    is(response_body($run->('/normal/rejected')), 'continued',
        'a rejected provider route lets declaration-order scanning continue');
    is($run->('/raw/accepted')->[0]{status}, 204,
        'an accepted provider capture selects the raw HTTP application');
    is($run->('/raw/rejected')->[0]{status}, 404,
        'a rejected raw provider route reaches the Router HTTP default');
    is(\@normal, ['accepted'],
        'the constrained normal handler runs only for its accepted capture');
    is(\@raw, ['accepted'],
        'the raw application is never invoked for a rejected capture');
};

subtest 'invalid normal returns retain the shared diagnostic' => sub {
    my @cases = (
        ['undef', sub { return undef }],
        ['scalar', sub { return 42 }],
        ['wrong object', sub { return bless {}, 'Local::NotAResponse' }],
    );

    for my $case (@cases) {
        my ($label, $handler) = @$case;
        my $app = PAGI::Routing::Compiler->_compile_http_leaf(
            route('/bad' => $handler),
        );
        my ($receive, $send, $events) = channels();
        like(
            dies { $app->(scope(path => '/bad'), $receive, $send)->get },
            qr/handler did not return a response/,
            "$label return is rejected",
        );
        is($events, [], "$label return emits no response events");
    }
};

subtest 'handler exceptions and failed Futures propagate unchanged' => sub {
    my $throwing = PAGI::Routing::Compiler->_compile_http_leaf(
        route('/throw' => sub { die "handler exploded\n" }),
    );
    my ($receive, $send, $events) = channels();
    like(
        dies { $throwing->(scope(path => '/throw'), $receive, $send)->get },
        qr/handler exploded/,
        'synchronous handler exception propagates',
    );
    is($events, [], 'synchronous exception is not converted into a response');

    my $failing = PAGI::Routing::Compiler->_compile_http_leaf(
        route('/fail' => sub { return Future->fail("future exploded\n") }),
    );
    ($receive, $send, $events) = channels();
    like(
        dies { $failing->(scope(path => '/fail'), $receive, $send)->get },
        qr/future exploded/,
        'failed handler Future propagates',
    );
    is($events, [], 'failed Future is not converted into a response');
};

subtest 'selection returns exact request-local full, partial, and none records' => sub {
    my $default = route '/items/{id}' => sub {
        return PAGI::Response::Text->new('default');
    };
    my $entries = compiled_entries($default);
    my $incoming_params = { tenant => 'acme' };
    my $incoming = scope(
        method => 'GET',
        path => '/items/42',
        path_params => $incoming_params,
        marker => 'retained',
    );
    my $full = PAGI::Routing::Compiler->_select_http($entries, $incoming);

    is(
        $full,
        {
            kind => 'full',
            app => $entries->[0]{app},
            scope => {
                %$incoming,
                path_params => { tenant => 'acme', id => '42' },
            },
        },
        'full decision has only kind, app, and a matched shallow scope',
    );
    isnt(refaddr($full), refaddr($incoming), 'decision is distinct from the input scope');
    isnt(refaddr($full->{scope}), refaddr($incoming), 'matched scope is request-local');
    isnt(refaddr($full->{scope}{path_params}), refaddr($incoming_params), 'matched path params are request-local');
    is($incoming_params, { tenant => 'acme' }, 'selection leaves incoming path params unchanged');

    my $partial = PAGI::Routing::Compiler->_select_http(
        $entries,
        scope(method => 'POST', path => '/items/42'),
    );
    is(
        $partial,
        { kind => 'partial', allowed_methods => ['GET', 'HEAD'] },
        'partial decision has only kind and normalized allowed methods',
    );

    my $none = PAGI::Routing::Compiler->_select_http(
        $entries,
        scope(method => 'POST', path => '/missing'),
    );
    is($none, { kind => 'none' }, 'none decision has only kind');
    isnt(refaddr($partial), refaddr($none), 'each decision is newly allocated');
};

subtest 'method matching consumes normalized scalar, array, wildcard, and HEAD declarations' => sub {
    my @cases = (
        [
            'default GET',
            route('/method' => sub { return PAGI::Response::Text->new('GET') }),
            'GET',
        ],
        [
            'automatic HEAD',
            route('/method' => sub { return PAGI::Response::Text->new('HEAD') }),
            'HEAD',
        ],
        [
            'scalar method',
            route('/method' => sub { return PAGI::Response::Text->new('POST') }, methods => 'post'),
            'POST',
        ],
        [
            'array method',
            route('/method' => sub { return PAGI::Response::Text->new('PATCH') }, methods => [qw(PUT PATCH)]),
            'PATCH',
        ],
        [
            'wildcard method',
            route('/method' => sub { return PAGI::Response::Text->new('wildcard') }, methods => '*'),
            'BREW',
        ],
    );

    for my $case (@cases) {
        my ($label, $declared, $method) = @$case;
        my $entries = compiled_entries($declared);
        my $decision = PAGI::Routing::Compiler->_select_http(
            $entries,
            scope(method => lc($method), path => '/method'),
        );
        is($decision->{kind}, 'full', "$label produces a full decision");
        is(refaddr($decision->{app}), refaddr($entries->[0]{app}), "$label selects its compiled leaf");
    }

    my $default_entries = compiled_entries(
        route('/method' => sub { return PAGI::Response::Text->new('GET') }),
    );
    is(
        PAGI::Routing::Compiler->_select_http(
            $default_entries,
            scope(method => 'OPTIONS', path => '/method'),
        ),
        { kind => 'partial', allowed_methods => ['GET', 'HEAD'] },
        'OPTIONS is not added automatically',
    );
};

subtest 'declaration-order scanning continues past partials and stops on the first full match' => sub {
    my $first_full = route '/same' => sub { return PAGI::Response::Text->new('first') }, methods => 'POST';
    my $second_full = route '/same' => sub { return PAGI::Response::Text->new('second') }, methods => 'POST';
    my $entries = compiled_entries($first_full, $second_full);
    my $decision = PAGI::Routing::Compiler->_select_http(
        $entries,
        scope(method => 'POST', path => '/same'),
    );
    is(refaddr($decision->{app}), refaddr($entries->[0]{app}), 'first full match wins without specificity sorting');

    my $get = route '/same' => sub { return PAGI::Response::Text->new('get') }, methods => 'GET';
    my $post = route '/same' => sub { return PAGI::Response::Text->new('post') }, methods => 'POST';
    $entries = compiled_entries($get, $post);
    $decision = PAGI::Routing::Compiler->_select_http(
        $entries,
        scope(method => 'POST', path => '/same'),
    );
    is($decision->{kind}, 'full', 'later full match beats an earlier partial');
    is(refaddr($decision->{app}), refaddr($entries->[1]{app}), 'later matching declaration is selected');

    my $constrained = route '/items/{id}' => sub { return PAGI::Response::Text->new('item') },
        methods => 'GET', constraints => { id => sub { return 0 } };
    is(
        PAGI::Routing::Compiler->_select_http(
            compiled_entries($constrained),
            scope(method => 'POST', path => '/items/42'),
        ),
        { kind => 'none' },
        'constraint failure is no match rather than a partial match',
    );

    my $specific = route '/known' => sub { return PAGI::Response::Text->new('specific') }, methods => 'GET';
    my $catch_all = route '/*path' => sub { return PAGI::Response::Text->new('catch all') }, methods => '*';
    $entries = compiled_entries($specific, $catch_all);
    $decision = PAGI::Routing::Compiler->_select_http(
        $entries,
        scope(method => 'DELETE', path => '/known'),
    );
    is($decision->{kind}, 'full', 'true catch-all full match beats an earlier partial');
    is(refaddr($decision->{app}), refaddr($entries->[1]{app}), 'catch-all leaf is selected');
    is($decision->{scope}{path_params}, { path => 'known' }, 'catch-all capture reaches matched scope');
};

subtest 'partial decisions preserve first-seen method order without sharing arrays' => sub {
    my @cases = (
        [
            'GET then POST',
            [
                route('/ordered' => sub { }, methods => 'GET'),
                route('/ordered' => sub { }, methods => 'POST'),
            ],
            [qw(GET HEAD POST)],
        ],
        [
            'POST then GET',
            [
                route('/ordered' => sub { }, methods => 'POST'),
                route('/ordered' => sub { }, methods => 'GET'),
            ],
            [qw(POST GET HEAD)],
        ],
        [
            'explicit HEAD before GET',
            [
                route('/ordered' => sub { }, methods => 'HEAD'),
                route('/ordered' => sub { }, methods => 'GET'),
            ],
            [qw(HEAD GET)],
        ],
        [
            'deduplication never moves an earlier method',
            [
                route('/ordered' => sub { }, methods => [qw(POST GET POST HEAD PUT)]),
                route('/ordered' => sub { }, methods => [qw(GET DELETE POST)]),
            ],
            [qw(POST GET HEAD PUT DELETE)],
        ],
    );

    for my $case (@cases) {
        my ($label, $routes, $wanted) = @$case;
        my $entries = compiled_entries(@$routes);
        my $decision = PAGI::Routing::Compiler->_select_http(
            $entries,
            scope(method => 'TRACE', path => '/ordered'),
        );
        is($decision, { kind => 'partial', allowed_methods => $wanted }, $label);
    }

    my $entries = compiled_entries(
        route('/ordered' => sub { }, methods => 'GET'),
        route('/ordered' => sub { }, methods => 'POST'),
    );
    my $first = PAGI::Routing::Compiler->_select_http(
        $entries,
        scope(method => 'TRACE', path => '/ordered'),
    );
    my $second = PAGI::Routing::Compiler->_select_http(
        $entries,
        scope(method => 'TRACE', path => '/ordered'),
    );
    isnt(refaddr($first), refaddr($second), 'consecutive selections allocate distinct decisions');
    isnt(
        refaddr($first->{allowed_methods}),
        refaddr($second->{allowed_methods}),
        'consecutive selections allocate distinct method arrays',
    );
    push @{$first->{allowed_methods}}, 'MUTATED';
    is($second->{allowed_methods}, [qw(GET HEAD POST)], 'one request cannot mutate another request method array');

    my $nested;
    my $inside = 0;
    my $reentrant_route = route '/ordered/{id}' => sub { },
        methods => 'GET',
        constraints => {
            id => sub {
                if (!$inside) {
                    $inside = 1;
                    $nested = PAGI::Routing::Compiler->_select_http(
                        compiled_entries(
                            route('/ordered/{id}' => sub { }, methods => 'POST'),
                        ),
                        scope(method => 'TRACE', path => '/ordered/nested'),
                    );
                    $inside = 0;
                }
                return 1;
            },
        };
    my $outer = PAGI::Routing::Compiler->_select_http(
        compiled_entries($reentrant_route),
        scope(method => 'TRACE', path => '/ordered/outer'),
    );
    is($outer->{allowed_methods}, [qw(GET HEAD)], 'outer reentrant selection retains its method array');
    is($nested->{allowed_methods}, ['POST'], 'nested in-flight selection retains an independent method array');
    isnt(
        refaddr($outer->{allowed_methods}),
        refaddr($nested->{allowed_methods}),
        'reentrant in-flight selections do not share method arrays',
    );
};

subtest 'PAGI::App::Router emits first-seen authoritative Allow order' => sub {
    my @cases = (
        [
            'POST declared before GET',
            sub {
                my ($router) = @_;
                $router->post('/ordered' => sub { return Future->done });
                $router->get('/ordered' => sub { return Future->done });
            },
            [qw(POST GET HEAD)],
        ],
        [
            'GET declared before POST',
            sub {
                my ($router) = @_;
                $router->get('/ordered' => sub { return Future->done });
                $router->post('/ordered' => sub { return Future->done });
            },
            [qw(GET HEAD POST)],
        ],
    );

    for my $case (@cases) {
        my ($label, $declare, $want) = @$case;
        my $router = PAGI::App::Router->new;
        $declare->($router);
        my $app = $router->to_app;
        my ($receive, $send, $events) = channels();
        $app->(
            scope(method => 'TRACE', path => '/ordered'),
            $receive,
            $send,
        )->get;
        is($events->[0]{status}, 405, "$label emits Method Not Allowed");
        is(allow_header($events), join(', ', @$want),
            "$label controls the authoritative Allow order");
    }
};

subtest 'route middleware is compiled once and executes only after full selection' => sub {
    my $builds = 0;
    my $runs = 0;
    my @middleware_argument_counts;
    my $descriptor = middleware(sub {
        my ($inner) = @_;
        ++$builds;
        return sub {
            ++$runs;
            push @middleware_argument_counts, scalar @_;
            return $inner->(@_);
        };
    });
    my $declared = route '/wrapped' => sub {
        return PAGI::Response::Text->new('wrapped');
    }, methods => 'GET', middleware => [$descriptor];
    my $entries = compiled_entries($declared);

    is($builds, 1, 'middleware factory runs once during leaf compilation');
    is($runs, 0, 'compiled middleware has not executed during compilation');

    my $partial = PAGI::Routing::Compiler->_select_http(
        $entries,
        scope(method => 'POST', path => '/wrapped'),
    );
    is($partial->{kind}, 'partial', 'wrong method produces partial decision');
    is($runs, 0, 'partial selection does not invoke route middleware');

    my $none = PAGI::Routing::Compiler->_select_http(
        $entries,
        scope(method => 'GET', path => '/missing'),
    );
    is($none->{kind}, 'none', 'wrong path produces none decision');
    is($runs, 0, 'none selection does not invoke route middleware');

    my $full = PAGI::Routing::Compiler->_select_http(
        $entries,
        scope(method => 'GET', path => '/wrapped'),
    );
    is($full->{kind}, 'full', 'matching route produces full decision');
    is($runs, 0, 'full selection itself does not invoke route middleware');
    is($builds, 1, 'selection never recompiles middleware');

    my ($receive, $send, $events) = channels();
    $full->{app}->($full->{scope}, $receive, $send)->get;
    is($runs, 1, 'selected app invocation executes route middleware once');
    is(\@middleware_argument_counts, [3],
        'route middleware remains an exact three-argument native app');
    is($builds, 1, 'selected app invocation reuses compiled middleware');
    is(response_body($events), 'wrapped', 'middleware delegates to the selected handler adapter');
};

{
    package Local::CountedResponse;

    use parent 'PAGI::Response';

    sub new {
        my ($class, $count, $sends, $completion) = @_;
        return bless {
            count      => $count,
            sends      => $sends,
            completion => $completion,
        }, $class;
    }

    sub respond {
        my ($self, $scope, $receive, $send) = @_;
        ++${$self->{count}};
        push @{$self->{sends}}, [$scope, $receive, $send];
        return $self->{completion};
    }
}

{
    package Local::CountingComponent;

    sub new { return bless { body => $_[1], compilations => 0 }, $_[0] }
    sub compilations { return $_[0]{compilations} }
    sub to_app {
        my ($self) = @_;
        ++$self->{compilations};
        my $body = $self->{body};
        return async sub {
            my ($scope, $receive, $send) = @_;
            await $send->({
                type => 'http.response.start', status => 200, headers => [],
            });
            await $send->({
                type => 'http.response.body', body => $body, more => 0,
            });
            return;
        };
    }
}

{
    package Local::BarrierComponent;

    sub new { return bless { invocations => 0 }, $_[0] }
    sub invocations { return $_[0]{invocations} }
    sub to_app {
        my ($self) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            my $id = ++$self->{invocations};
            await $send->({
                type    => 'http.response.start', status => 200,
                headers => [['x-invocation', $id]],
            });
            await $send->({
                type => 'http.response.body', body => "overlap $id", more => 0,
            });
            return;
        };
    }
}

{
    package Local::RawComponent;

    sub new {
        my ($class, $coercions, $app) = @_;
        return bless {
            coercions => $coercions,
            app => $app,
        }, $class;
    }

    sub to_app {
        my ($self) = @_;
        ++${$self->{coercions}};
        return $self->{app};
    }
}

done_testing;
