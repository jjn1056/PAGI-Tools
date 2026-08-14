use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);
use FindBin qw($Bin);
use lib "$Bin/lib";
use ComposeTest qw(scope capture_send);
use PAGI::Compose qw(compose);
use PAGI::Exception::IncompleteResponse;
use PAGI::Routing qw(router route mount middleware);
use PAGI::Routing::Trace;

sub run_request {
    my ($app, $request_scope) = @_;
    my ($send, $events) = capture_send();
    my @warnings;
    my $error;
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        eval {
            Future->wrap($app->(
                $request_scope || scope(),
                sub { return Future->done },
                $send,
            ))->get;
            1;
        } or $error = $@;
    }
    return ($events, \@warnings, $error);
}

sub starts {
    my ($events) = @_;
    return [grep { ($_->{type} // '') eq 'http.response.start' } @$events];
}

sub bodies {
    my ($events) = @_;
    return [grep { ($_->{type} // '') eq 'http.response.body' } @$events];
}

sub body_text {
    my ($events) = @_;
    return join '', map { defined($_->{body}) ? $_->{body} : '' } @{bodies($events)};
}

sub header_values {
    my ($event, $name) = @_;
    return [map { $_->[1] }
        grep { ref($_) eq 'ARRAY' && lc($_->[0] // '') eq lc($name) }
        @{$event->{headers} || []}];
}

sub assert_rendered {
    my ($label, $events, $status, $body) = @_;
    my $response_starts = starts($events);
    is(scalar @$response_starts, 1, "$label emits exactly one response start");
    is($response_starts->[0]{status}, $status, "$label status is $status");
    is(body_text($events), $body, "$label body is exact");
}

sub route_set {
    return [
        route('/items' => sub { return $_[0]->text('get') }, methods => 'GET'),
        route('/items' => sub { return $_[0]->text('post') }, methods => 'POST'),
        route('/explicit/404' => sub {
            return $_[0]->text('application 404', status => 404);
        }),
        route('/explicit/405' => sub {
            return $_[0]->text('application 405', status => 405);
        }),
        route('/explicit/500' => sub {
            return $_[0]->text('application 500', status => 500);
        }),
    ];
}

sub composition_modes {
    my ($routes) = @_;
    return (
        ['routes', compose(routes => $routes)->to_app],
        ['app Router', compose(app => router(routes => $routes))->to_app],
    );
}

subtest 'automatic route outcomes cover both Compose target modes' => sub {
    local $ENV{PAGI_ENV} = 'production';
    for my $mode (composition_modes(route_set())) {
        my ($label, $app) = @$mode;

        my ($full, $full_warnings, $full_error) = run_request(
            $app, scope(path => '/items', method => 'GET'),
        );
        is($full_error, undef, "$label FULL response completes");
        is($full_warnings, [], "$label FULL response does not warn");
        assert_rendered("$label FULL", $full, 200, 'get');

        my ($none, $none_warnings, $none_error) = run_request(
            $app, scope(path => '/missing'),
        );
        is($none_error, undef, "$label none outcome completes");
        is($none_warnings, [], "$label none outcome does not warn");
        assert_rendered("$label none", $none, 404, 'Not Found');

        my ($partial, $partial_warnings, $partial_error) = run_request(
            $app, scope(path => '/items', method => 'DELETE'),
        );
        is($partial_error, undef, "$label partial outcome completes");
        is($partial_warnings, [], "$label partial outcome does not warn");
        assert_rendered("$label partial", $partial, 405, 'Method Not Allowed');
        is(header_values(starts($partial)->[0], 'Allow'), ['GET, HEAD, POST'],
            "$label partial outcome carries the deterministic union Allow");
    }
};

subtest 'explicit matched application errors pass unchanged in both target modes' => sub {
    local $ENV{PAGI_ENV} = 'production';
    for my $mode (composition_modes(route_set())) {
        my ($label, $app) = @$mode;
        for my $status (404, 405, 500) {
            my ($events, $warnings, $error) = run_request(
                $app, scope(path => "/explicit/$status"),
            );
            is($error, undef, "$label explicit $status completes");
            is($warnings, [], "$label explicit $status does not warn");
            assert_rendered(
                "$label explicit $status", $events, $status,
                "application $status",
            );
            is(header_values(starts($events)->[0], 'Allow'), [],
                "$label explicit $status is not fallback-normalized");
        }
    }
};

subtest 'silent native raw and opaque targets become production-safe 500' => sub {
    local $ENV{PAGI_ENV} = 'production';
    my @cases = (
        ['native app', compose(app => sub { return })->to_app, scope()],
        [
            'selected raw route',
            compose(routes => [route('/raw', raw => sub { return })])->to_app,
            scope(path => '/raw'),
        ],
        [
            'selected opaque Mount',
            compose(routes => [mount('/opaque' => sub { return })])->to_app,
            scope(path => '/opaque/child'),
        ],
    );

    for my $case (@cases) {
        my ($label, $app, $request_scope) = @$case;
        my ($events, $warnings, $error) = run_request($app, $request_scope);
        is($error, undef, "$label incompletion is contained");
        assert_rendered($label, $events, 500, 'Error 500: Internal Server Error');
        is(scalar @$warnings, 1, "$label is reported once");
        like($warnings->[0], qr/^PAGI application error: HTTP application completed /,
            "$label reports the guard failure");
    }
};

subtest 'application throws failed Futures and renderer failures become one 500' => sub {
    local $ENV{PAGI_ENV} = 'production';
    my @cases = (
        ['database-like throw', compose(app => sub {
            die "DB connection lost\n";
        })->to_app, scope(), qr/DB connection lost/],
        ['database-like failed Future', compose(app => sub {
            return Future->fail("DB transaction failed\n");
        })->to_app, scope(), qr/DB transaction failed/],
        [
            'author fallback renderer throw',
            compose(
                routes => [],
                middleware => [middleware('Routing::NotFound', handler => sub {
                    die "fallback renderer failed\n";
                })],
            )->to_app,
            scope(path => '/missing'),
            qr/fallback renderer failed/,
        ],
    );

    for my $case (@cases) {
        my ($label, $app, $request_scope, $warning_pattern) = @$case;
        my ($events, $warnings, $error) = run_request($app, $request_scope);
        is($error, undef, "$label is contained");
        assert_rendered($label, $events, 500, 'Error 500: Internal Server Error');
        is(scalar @$warnings, 1, "$label is reported once");
        like($warnings->[0], $warning_pattern, "$label reports the original failure");
    }
};

subtest 'a fresh shallow routing trace is installed inside the HEAD boundary' => sub {
    local $ENV{PAGI_ENV} = 'production';
    my ($incoming_scope, $incoming_trace) =
        PAGI::Routing::Trace->_fresh_http_scope(scope(path => '/complete'));
    my $state = { request => 1 };
    $incoming_scope->{state} = $state;
    my ($seen_scope, $seen_trace, $seen_state);
    my $observer = sub {
        my ($inner) = @_;
        return sub {
            my ($request_scope, $receive, $send) = @_;
            $seen_scope = $request_scope;
            $seen_trace = $request_scope->{'pagi.routing.trace'};
            $seen_state = $request_scope->{state};
            return $inner->(@_);
        };
    };
    my $app = compose(
        app => sub {
            my ($request_scope, $receive, $send) = @_;
            $send->({ type => 'http.response.start', status => 204, headers => [] })->get;
            return $send->({ type => 'http.response.body', body => '', more => 0 });
        },
        middleware => [$observer],
    )->to_app;
    my ($events, $warnings, $error) = run_request($app, $incoming_scope);
    is($error, undef, 'request completes through the fresh trace scope');
    is($warnings, [], 'trace preparation does not warn');
    isnt(refaddr($seen_scope), refaddr($incoming_scope),
        'automatic boundary installs a shallow request scope');
    isnt(refaddr($seen_trace), refaddr($incoming_trace),
        'incoming compatible first-party Trace is replaced');
    is(refaddr($seen_state), refaddr($state),
        'shallow scope preparation preserves nested request state identity');
    is(refaddr($incoming_scope->{'pagi.routing.trace'}), refaddr($incoming_trace),
        'the caller-owned scope is not mutated');
    assert_rendered('fresh trace complete response', $events, 204, '');
};

subtest 'invalid PAGI_ENV is contained only when an error path consults it' => sub {
    local $ENV{PAGI_ENV} = 'invalid-compose-environment';

    my $routing = compose(routes => [
        route('/known' => sub { return $_[0]->text('known') }),
    ])->to_app;
    my ($route_events, $route_warnings, $route_error) = run_request(
        $routing, scope(path => '/missing'),
    );
    is($route_error, undef, 'Router observation environment failure is contained');
    assert_rendered(
        'invalid environment Router observation', $route_events, 500,
        'Error 500: Internal Server Error',
    );
    is(scalar @$route_warnings, 2,
        'Router observation and resolver failures are both reported');
    like($route_warnings->[0], qr/Invalid PAGI_ENV 'invalid-compose-environment'/,
        'Router observation failure is reported');
    like($route_warnings->[1], qr/Invalid PAGI_ENV 'invalid-compose-environment'/,
        'failsafe resolver failure is reported');

    my $throwing = compose(app => sub { die "native application failed\n" })->to_app;
    my ($throw_events, $throw_warnings, $throw_error) = run_request($throwing, scope());
    is($throw_error, undef, 'throwing native app remains contained');
    assert_rendered(
        'invalid environment throwing native app', $throw_events, 500,
        'Error 500: Internal Server Error',
    );
    is(scalar @$throw_warnings, 2,
        'application and resolver failures are both reported');
    like($throw_warnings->[0], qr/native application failed/,
        'the native application failure is reported first');
    like($throw_warnings->[1], qr/Invalid PAGI_ENV 'invalid-compose-environment'/,
        'the resolver failure is reported second');

    my $complete = compose(app => sub {
        my ($request_scope, $receive, $send) = @_;
        $send->({ type => 'http.response.start', status => 200, headers => [] })->get;
        return $send->({ type => 'http.response.body', body => 'complete', more => 0 });
    })->to_app;
    my ($complete_events, $complete_warnings, $complete_error)
        = run_request($complete, scope());
    is($complete_error, undef, 'normally complete native app does not consult PAGI_ENV');
    is($complete_warnings, [], 'normally complete native app does not warn');
    assert_rendered('invalid environment complete native app',
        $complete_events, 200, 'complete');
};

subtest 'post-start incomplete response is reported and rethrown without replacement' => sub {
    local $ENV{PAGI_ENV} = 'production';
    my $app = compose(app => sub {
        my ($request_scope, $receive, $send) = @_;
        return $send->({
            type => 'http.response.start', status => 200, headers => [],
        });
    })->to_app;
    my ($events, $warnings, $error) = run_request($app, scope());
    isa_ok($error, ['PAGI::Exception::IncompleteResponse']);
    is($error && $error->can('stage') ? $error->stage : undef,
        'after_start', 'guard reports the exact post-start stage');
    is(scalar @{starts($events)}, 1, 'only the application response start is emitted');
    is(starts($events)->[0]{status}, 200, 'the original start remains unchanged');
    is(bodies($events), [], 'no replacement response body is emitted');
    is(scalar @$warnings, 1, 'post-start incompletion is reported once');
    like($warnings->[0], qr/^PAGI application error: HTTP application completed after response start/,
        'internal reporter receives the typed guard error');
};

done_testing;
