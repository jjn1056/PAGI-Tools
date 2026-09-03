use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use JSON::MaybeXS qw(decode_json);
use Scalar::Util qw(refaddr);
use FindBin qw($Bin);
use lib "$Bin/lib";
use ComposeTest qw(scope capture_send);
use PAGI::Compose qw(compose);
use PAGI::Exception::IncompleteResponse;
use PAGI::Response::Text ();
use PAGI::Routing qw(router route mount);
use PAGI::Test::Client;
use PAGI::Utils qw(as_app_object);

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

sub assert_pages_error {
    my ($label, $events, $status, $title, $content_type) = @_;
    my $response_starts = starts($events);
    is(scalar @$response_starts, 1, "$label emits exactly one response start");
    is($response_starts->[0]{status}, $status, "$label status is $status");
    is(header_values($response_starts->[0], 'Content-Type'), [$content_type],
        "$label uses its negotiated Pages representation");
    my $body = body_text($events);
    if ($content_type eq 'application/problem+json') {
        my $problem = decode_json($body);
        is($problem->{status}, $status, "$label problem status matches the wire");
        is($problem->{title}, $title, "$label problem title is semantic");
    }
    else {
        like($body, qr/\Q$status\E\s+\Q$title\E/,
            "$label body contains semantic status and title");
    }
}

sub assert_client_pages_error {
    my ($label, $response, $status, $title, $content_type) = @_;
    is($response->status, $status, "$label status is $status");
    is($response->content_type, $content_type,
        "$label uses its negotiated Pages representation");
    if ($content_type eq 'application/problem+json') {
        is($response->json->{status}, $status,
            "$label problem status matches the wire");
        is($response->json->{title}, $title,
            "$label problem title is semantic");
    }
    else {
        like($response->text, qr/\Q$status\E\s+\Q$title\E/,
            "$label body contains semantic status and title");
    }
}

sub route_set {
    return [
        route('/items' => sub { return PAGI::Response::Text->new('get') }, methods => 'GET'),
        route('/items' => sub { return PAGI::Response::Text->new('post') }, methods => 'POST'),
        route('/explicit/404' => sub {
            return PAGI::Response::Text->new('application 404', status => 404);
        }),
        route('/explicit/405' => sub {
            return PAGI::Response::Text->new('application 405', status => 405);
        }),
        route('/explicit/406' => sub {
            return PAGI::Response::Text->new('application 406', status => 406);
        }),
        route('/explicit/415' => sub {
            return PAGI::Response::Text->new('application 415', status => 415);
        }),
        route('/explicit/500' => sub {
            return PAGI::Response::Text->new('application 500', status => 500);
        }),
    ];
}

sub composition_modes {
    my ($routes) = @_;
    return (
        ['direct routes', compose(routes => $routes)->to_app],
        ['root-mounted Router', compose(routes => [
            mount('/' => app => router(routes => $routes)),
        ])->to_app],
    );
}

subtest 'Compose routes receive ordinary Router HTTP outcomes' => sub {
    local $ENV{PAGI_ENV} = 'production';
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };

    my $empty = PAGI::Test::Client->new(
        app => compose(routes => [])->to_app,
    )->get('/missing', headers => { Accept => 'application/problem+json' });
    assert_client_pages_error(
        'empty routes Router default', $empty, 404, 'Not Found',
        'application/problem+json',
    );

    my $client = PAGI::Test::Client->new(
        app => compose(routes => route_set())->to_app,
    );
    my $full = $client->get('/items');
    is($full->status, 200, 'selected route status is retained');
    is($full->text, 'get', 'selected route body is retained');

    my $partial = $client->delete('/items',
        headers => { Accept => 'text/plain' });
    assert_client_pages_error(
        'Router method mismatch', $partial, 405, 'Method Not Allowed',
        'text/plain; charset=utf-8',
    );
    is($partial->header('Allow'), 'GET, HEAD, POST',
        'Router 405 carries the deterministic union Allow');
    is(\@warnings, [], 'ordinary Router outcomes do not warn');
};

subtest 'explicit matched application responses pass unchanged in both Router forms' => sub {
    local $ENV{PAGI_ENV} = 'production';
    for my $mode (composition_modes(route_set())) {
        my ($label, $app) = @$mode;
        for my $status (404, 405, 406, 415, 500) {
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
                "$label explicit $status is not routing-normalized");
        }
    }
};

subtest 'selected silent targets become production-safe 500 through Test Client' => sub {
    local $ENV{PAGI_ENV} = 'production';
    my @cases = (
        [
            'selected raw route',
            compose(routes => [
                route('/silent' => as_app_object(sub { return })),
            ])->to_app,
            scope(path => '/silent'),
        ],
        [
            'selected opaque Mount',
            compose(routes => [mount('/opaque', app => sub { return })])->to_app,
            scope(path => '/opaque/child'),
        ],
    );

    for my $case (@cases) {
        my ($label, $app, $request_scope) = @$case;
        my @warnings;
        my $response;
        {
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            $response = PAGI::Test::Client->new(app => $app)->get(
                $request_scope->{path} // '/',
            );
        }
        assert_client_pages_error(
            $label, $response, 500, 'Internal Server Error',
            'text/html; charset=utf-8',
        );
        is(scalar @warnings, 1, "$label is reported once");
        like($warnings[0], qr/^PAGI application error: HTTP application completed /,
            "$label reports the guard failure");
    }
};

subtest 'thrown and failed-Future targets become one Test Client 500' => sub {
    local $ENV{PAGI_ENV} = 'production';
    my @cases = (
        ['database-like throw', compose(routes => [
            route('/explode' => as_app_object(sub { die "DB connection lost\n" })),
        ])->to_app, scope(path => '/explode'), qr/DB connection lost/],
        ['database-like failed Future', compose(routes => [
            route('/fail' => as_app_object(sub {
                return Future->fail("DB transaction failed\n");
            })),
        ])->to_app, scope(path => '/fail'), qr/DB transaction failed/],
    );

    for my $case (@cases) {
        my ($label, $app, $request_scope, $warning_pattern) = @$case;
        my (@warnings, $response);
        {
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            $response = PAGI::Test::Client->new(app => $app)->get(
                $request_scope->{path},
            );
        }
        assert_client_pages_error(
            $label, $response, 500, 'Internal Server Error',
            'text/html; charset=utf-8',
        );
        unlike($response->text, $warning_pattern,
            "$label production response does not expose the original failure");
        is(scalar @warnings, 1, "$label is reported once");
        like($warnings[0], $warning_pattern, "$label reports the original failure");
    }
};

subtest 'Compose leaves routing metadata to the retained Router' => sub {
    my $routing_metadata = { selected => '/complete', captures => { id => 7 } };
    my $incoming_scope = scope(path => '/complete');
    $incoming_scope->{'pagi.routing'} = $routing_metadata;
    my $seen_metadata;
    my $app = compose(
        routes => [route('/complete' => as_app_object(sub {
            my ($request_scope, $receive, $send) = @_;
            $seen_metadata = $request_scope->{'pagi.routing'};
            $send->({ type => 'http.response.start', status => 204, headers => [] })->get;
            return $send->({ type => 'http.response.body', body => '', more => 0 });
        }))],
    )->to_app;
    my ($events, $warnings, $error) = run_request($app, $incoming_scope);
    is($error, undef, 'request with routing metadata completes');
    is($warnings, [], 'routing metadata does not trigger diagnostics');
    is(refaddr($incoming_scope->{'pagi.routing'}), refaddr($routing_metadata),
        'Compose leaves incoming routing metadata untouched');
    is($seen_metadata->{version}, 1,
        'the retained Router supplies its own routing metadata version');
    is(scalar @{$seen_metadata->{frames}}, 1,
        'the retained Router supplies one root routing frame');
    assert_rendered('metadata-preserving complete response', $events, 204, '');
};

subtest 'invalid PAGI_ENV is contained only when an error path consults it' => sub {
    local $ENV{PAGI_ENV} = 'invalid-compose-environment';

    my $routing = compose(routes => [
        route('/known' => sub { return PAGI::Response::Text->new('known') }),
    ])->to_app;
    my ($route_events, $route_warnings, $route_error) = run_request(
        $routing, scope(path => '/missing'),
    );
    is($route_error, undef, 'Router default does not consult the environment');
    assert_pages_error(
        'invalid environment Router default', $route_events, 404,
        'Not Found', 'text/html; charset=utf-8',
    );
    is($route_warnings, [], 'ordinary Router 404 does not warn');

    my $throwing = compose(routes => [
        route('/explode' => as_app_object(sub { die "native application failed\n" })),
    ])->to_app;
    my ($throw_events, $throw_warnings, $throw_error)
        = run_request($throwing, scope(path => '/explode'));
    is($throw_error, undef, 'throwing selected app remains contained');
    assert_pages_error(
        'invalid environment throwing native app', $throw_events, 500,
        'Internal Server Error', 'text/html; charset=utf-8',
    );
    is(scalar @$throw_warnings, 2,
        'application and resolver failures are both reported');
    like($throw_warnings->[0], qr/native application failed/,
        'the native application failure is reported first');
    like($throw_warnings->[1], qr/Invalid PAGI_ENV 'invalid-compose-environment'/,
        'the resolver failure is reported second');

    my $complete = compose(routes => [route('/complete' => as_app_object(sub {
        my ($request_scope, $receive, $send) = @_;
        $send->({ type => 'http.response.start', status => 200, headers => [] })->get;
        return $send->({ type => 'http.response.body', body => 'complete', more => 0 });
    }))])->to_app;
    my ($complete_events, $complete_warnings, $complete_error)
        = run_request($complete, scope(path => '/complete'));
    is($complete_error, undef, 'normally complete selected app does not consult PAGI_ENV');
    is($complete_warnings, [], 'normally complete selected app does not warn');
    assert_rendered('invalid environment complete selected app',
        $complete_events, 200, 'complete');
};

subtest 'post-start incomplete response is reported and rethrown without replacement' => sub {
    local $ENV{PAGI_ENV} = 'production';
    my $app = compose(routes => [route('/incomplete' => as_app_object(sub {
        my ($request_scope, $receive, $send) = @_;
        return $send->({
            type => 'http.response.start', status => 200, headers => [],
        });
    }))])->to_app;
    my ($events, $warnings, $error) = run_request($app, scope(path => '/incomplete'));
    isa_ok($error, ['PAGI::Exception::IncompleteResponse']);
    is($error && $error->can('stage') ? $error->stage : undef,
        'after_start', 'guard reports the exact post-start stage');
    is(scalar @{starts($events)}, 1, 'only the application response start is emitted');
    is(starts($events)->[0]{status}, 200, 'the original start remains unchanged');
    is(bodies($events), [], 'no replacement response body is emitted');
    is(scalar @$warnings, 1, 'post-start incompletion is reported once');
    like($warnings->[0], qr/^PAGI application error: HTTP application completed after response start/,
        'internal reporter receives the typed guard error');

    my (@client_warnings, $client_error);
    {
        local $SIG{__WARN__} = sub { push @client_warnings, @_ };
        eval {
            PAGI::Test::Client->new(
                app => $app,
                raise_app_exceptions => 1,
            )->get('/incomplete');
            1;
        } or $client_error = $@;
    }
    isa_ok($client_error, ['PAGI::Exception::IncompleteResponse']);
    is($client_error->stage, 'after_start',
        'Test Client receives the rethrown post-start exception');
    is(scalar @client_warnings, 1,
        'Test Client path reports the post-start failure once');
};

subtest 'body before start becomes one clean automatic 500 response' => sub {
    local $ENV{PAGI_ENV} = 'production';
    my $invalid = {
        type => 'http.response.body', body => 'must not reach the wire', more => 0,
    };
    my $app = compose(routes => [route('/invalid' => as_app_object(sub {
        my ($request_scope, $receive, $send) = @_;
        return $send->($invalid);
    }))])->to_app;
    my ($events, $warnings, $error) = run_request($app, scope(path => '/invalid'));

    is($error, undef, 'automatic ErrorHandler contains the guard exception');
    is([map { $_->{type} } @$events], [
        'http.response.start', 'http.response.body',
    ], 'wire receives only the replacement response pair');
    assert_pages_error(
        'body-before-start guard failure', $events, 500,
        'Internal Server Error', 'text/html; charset=utf-8',
    );
    is(scalar @$warnings, 1, 'body-before-start failure is reported once');
    like($warnings->[0], qr/^PAGI application error: HTTP application sent a response body before response start/,
        'internal reporter receives the typed guard diagnostic');
};

done_testing;
