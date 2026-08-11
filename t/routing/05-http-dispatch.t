#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Scalar::Util qw(refaddr);

use PAGI::App::Router;
use PAGI::Response;
use PAGI::Routing qw(router route middleware);
use PAGI::Routing::Compiler;

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

subtest 'normal HTTP leaves adapt immediate and Future response values exactly once' => sub {
    my @contexts;
    my @argument_counts;
    my @call_contexts;
    my $sync = route '/items/{id}' => sub {
        push @argument_counts, scalar @_;
        push @call_contexts, defined wantarray ? (wantarray ? 'list' : 'scalar') : 'void';
        my ($c) = @_;
        push @contexts, $c;
        return $c->text('item ' . $c->path_param('id'));
    };
    my $sync_app = PAGI::Routing::Compiler->_compile_http_leaf($sync);
    my ($receive, $send, $events) = channels();

    $sync_app->(
        scope(path => '/items/42', path_params => { id => '42' }),
        $receive,
        $send,
    )->get;

    isa_ok($contexts[0], 'PAGI::Context::HTTP');
    is(\@argument_counts, [1], 'normal handler receives only Context');
    is(\@call_contexts, ['scalar'], 'normal handler is invoked in scalar context');
    is(response_body($events), 'item 42', 'immediate Response is emitted');
    is(
        [map { $_->{type} } @$events],
        [qw(http.response.start http.response.body)],
        'one immediate Response produces one response event pair',
    );

    my $future = route '/future' => sub {
        my ($c) = @_;
        return Future->done($c->text('future response'));
    };
    my $future_app = PAGI::Routing::Compiler->_compile_http_leaf($future);
    ($receive, $send, $events) = channels();
    $future_app->(scope(path => '/future'), $receive, $send)->get;
    is(response_body($events), 'future response', 'Future-resolved Response is emitted');

    my $count = 0;
    my $counted = Local::CountedResponse->new(\$count);
    my $counted_app = PAGI::Routing::Compiler->_compile_http_leaf(
        route('/counted' => sub { return $counted }),
    );
    ($receive, $send, $events) = channels();
    $counted_app->(scope(path => '/counted'), $receive, $send)->get;
    is($count, 1, 'adapter asks the response value to emit exactly once');
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
    my $raw = route '/raw', raw => $component;
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
            my ($c) = @_;
            push @normal, $c->path_param('id');
            return $c->text('provider ' . $c->path_param('id'));
        }),
        route('/normal/rejected' => sub {
            return $_[0]->text('continued');
        }),
        route('/raw/{id:&HttpProvider}', raw => sub {
            my ($request_scope, $receive, $send) = @_;
            push @raw, $request_scope->{path_params}{id};
            $send->({
                type => 'http.response.start', status => 204, headers => [],
            })->get;
            $send->({
                type => 'http.response.body', body => '', more => 0,
            })->get;
            return Future->done;
        }),
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
        'a rejected raw provider route produces the existing generated outcome');
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

subtest 'manual response emission remains an error under the normal contract' => sub {
    my $manual_undef = PAGI::Routing::Compiler->_compile_http_leaf(
        route('/manual-undef' => sub {
            my ($c) = @_;
            $c->respond($c->text('already sent'))->get;
            return undef;
        }),
    );
    my ($receive, $send, $events) = channels();
    like(
        dies { $manual_undef->(scope(path => '/manual-undef'), $receive, $send)->get },
        qr/handler did not return a response/,
        'manual response followed by undef retains return-value diagnostic',
    );
    is(response_body($events), 'already sent', 'the handler-owned first response was emitted');

    my $manual_response = PAGI::Routing::Compiler->_compile_http_leaf(
        route('/manual-response' => sub {
            my ($c) = @_;
            my $response = $c->text('sent once');
            $c->respond($response)->get;
            return $response;
        }),
    );
    ($receive, $send, $events) = channels();
    like(
        dies { $manual_response->(scope(path => '/manual-response'), $receive, $send)->get },
        qr/response already sent/,
        'manual response plus returned Response triggers the Context double-send guard',
    );
    is(response_body($events), 'sent once', 'double-send guard prevents a second response body');
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
    my $default = route '/items/{id}' => sub { return $_[0]->text('default') };
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
            route('/method' => sub { return $_[0]->text('GET') }),
            'GET',
        ],
        [
            'automatic HEAD',
            route('/method' => sub { return $_[0]->text('HEAD') }),
            'HEAD',
        ],
        [
            'scalar method',
            route('/method' => sub { return $_[0]->text('POST') }, methods => 'post'),
            'POST',
        ],
        [
            'array method',
            route('/method' => sub { return $_[0]->text('PATCH') }, methods => [qw(PUT PATCH)]),
            'PATCH',
        ],
        [
            'wildcard method',
            route('/method' => sub { return $_[0]->text('wildcard') }, methods => '*'),
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
        route('/method' => sub { return $_[0]->text('GET') }),
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
    my $first_full = route '/same' => sub { return $_[0]->text('first') }, methods => 'POST';
    my $second_full = route '/same' => sub { return $_[0]->text('second') }, methods => 'POST';
    my $entries = compiled_entries($first_full, $second_full);
    my $decision = PAGI::Routing::Compiler->_select_http(
        $entries,
        scope(method => 'POST', path => '/same'),
    );
    is(refaddr($decision->{app}), refaddr($entries->[0]{app}), 'first full match wins without specificity sorting');

    my $get = route '/same' => sub { return $_[0]->text('get') }, methods => 'GET';
    my $post = route '/same' => sub { return $_[0]->text('post') }, methods => 'POST';
    $entries = compiled_entries($get, $post);
    $decision = PAGI::Routing::Compiler->_select_http(
        $entries,
        scope(method => 'POST', path => '/same'),
    );
    is($decision->{kind}, 'full', 'later full match beats an earlier partial');
    is(refaddr($decision->{app}), refaddr($entries->[1]{app}), 'later matching declaration is selected');

    my $constrained = route '/items/{id}' => sub { return $_[0]->text('item') },
        methods => 'GET', constraints => { id => sub { return 0 } };
    is(
        PAGI::Routing::Compiler->_select_http(
            compiled_entries($constrained),
            scope(method => 'POST', path => '/items/42'),
        ),
        { kind => 'none' },
        'constraint failure is no match rather than a partial match',
    );

    my $specific = route '/known' => sub { return $_[0]->text('specific') }, methods => 'GET';
    my $catch_all = route '/*path' => sub { return $_[0]->text('catch all') }, methods => '*';
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

subtest 'PAGI::App::Router Allow values retain first-seen declaration order' => sub {
    my @cases = (
        [
            'POST declared before GET',
            sub {
                my ($router) = @_;
                $router->post('/ordered' => sub { return Future->done });
                $router->get('/ordered' => sub { return Future->done });
            },
            'POST, GET, HEAD',
        ],
        [
            'GET declared before POST',
            sub {
                my ($router) = @_;
                $router->get('/ordered' => sub { return Future->done });
                $router->post('/ordered' => sub { return Future->done });
            },
            'GET, HEAD, POST',
        ],
    );

    for my $case (@cases) {
        my ($label, $declare, $want) = @$case;
        my $router = PAGI::App::Router->new;
        $declare->($router);
        my $app = $router->to_app;
        my ($receive, $send, $events) = channels();

        $app->(scope(method => 'TRACE', path => '/ordered'), $receive, $send)->get;
        is(allow_header($events), $want, "$label controls the Allow order");
    }
};

subtest 'route middleware is compiled once and executes only after full selection' => sub {
    my $builds = 0;
    my $runs = 0;
    my $descriptor = middleware(sub {
        my ($inner) = @_;
        ++$builds;
        return sub {
            ++$runs;
            return $inner->(@_);
        };
    });
    my $declared = route '/wrapped' => sub {
        my ($c) = @_;
        return $c->text('wrapped');
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
    is($builds, 1, 'selected app invocation reuses compiled middleware');
    is(response_body($events), 'wrapped', 'middleware delegates to the selected handler adapter');
};

{
    package Local::CountedResponse;

    sub new {
        my ($class, $count) = @_;
        return bless { count => $count }, $class;
    }

    sub respond {
        my ($self) = @_;
        ++${$self->{count}};
        return Future->done;
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
