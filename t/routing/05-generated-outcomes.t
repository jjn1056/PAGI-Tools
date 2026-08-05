#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Scalar::Util qw(refaddr);

use PAGI::Response;
use PAGI::Routing qw(router route mount middleware);
use PAGI::Routing::Compiler;

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

sub run_app {
    my ($app, %scope_changes) = @_;
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

    $app->(scope(%scope_changes), $receive, $send)->get;
    return \@events;
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
    my $value;
    for my $pair (@{$start->{headers} // []}) {
        $value = $pair->[1] if lc($pair->[0]) eq lc($name);
    }
    return $value;
}

sub simple_router {
    my (%options) = @_;
    return router(
        routes => [
            route('/items' => sub { return $_[0]->text('matched') }, methods => 'GET'),
        ],
        %options,
    );
}

subtest 'plain generated outcomes use the normal response contract' => sub {
    my $app = simple_router()->to_app;

    my $not_found = run_app($app, method => 'GET', path => '/missing');
    is(response_start($not_found)->{status}, 404, 'an unmatched path receives the default 404 status');
    is(response_body($not_found), 'Not Found', 'the default not-found handler emits its body');
    is(response_header($not_found, 'Allow'), undef, 'a default 404 has no Allow header');

    my $not_allowed = run_app($app, method => 'POST', path => '/items');
    is(response_start($not_allowed)->{status}, 405, 'a partial match receives the default 405 status');
    is(response_body($not_allowed), 'Method Not Allowed', 'the default method handler emits its body');
    is(response_header($not_allowed, 'Allow'), 'GET, HEAD', 'the default 405 receives the selected methods');
};

subtest 'custom generated handlers receive the seeded Context response' => sub {
    my @seen;
    my $app = simple_router(
        not_found => sub {
            my ($c) = @_;
            push @seen, ['not_found', $c->response->status, $c->response->header('Allow')];
            return $c->text('custom missing');
        },
        method_not_allowed => sub {
            my ($c) = @_;
            push @seen, ['method_not_allowed', $c->response->status, $c->response->header('Allow')];
            return $c->text('custom method');
        },
    )->to_app;

    my $not_found = run_app($app, method => 'GET', path => '/missing');
    my $not_allowed = run_app($app, method => 'POST', path => '/items');

    is(
        \@seen,
        [
            ['not_found', 404, undef],
            ['method_not_allowed', 405, 'GET, HEAD'],
        ],
        'ordinary fallback handlers see status and Allow on their cached response before running',
    );
    is(response_start($not_found)->{status}, 404, 'the seeded custom not-found response stays 404');
    is(response_body($not_found), 'custom missing', 'the custom not-found body is emitted');
    is(response_start($not_allowed)->{status}, 405, 'the seeded custom method response stays 405');
    is(response_header($not_allowed, 'Allow'), 'GET, HEAD', 'the seeded Allow reaches the wire');
    is(response_body($not_allowed), 'custom method', 'the custom method body is emitted');
};

subtest 'the final 405 response receives Allow without overriding application policy' => sub {
    my $detached = simple_router(
        method_not_allowed => sub {
            return PAGI::Response->new->status(405)->text('detached');
        },
    )->to_app;
    my $events = run_app($detached, method => 'POST', path => '/items');
    is(response_header($events, 'Allow'), 'GET, HEAD', 'a detached final 405 receives a missing Allow');

    my $custom = simple_router(
        method_not_allowed => sub {
            return PAGI::Response->new
                ->status(405)
                ->header('aLlOw' => 'PATCH')
                ->text('custom Allow');
        },
    )->to_app;
    $events = run_app($custom, method => 'POST', path => '/items');
    is(response_header($events, 'Allow'), 'PATCH', 'a detached custom Allow is preserved');

    my $changed = simple_router(
        method_not_allowed => sub {
            my ($c) = @_;
            return $c->response->status(409)->text('changed status');
        },
    )->to_app;
    $events = run_app($changed, method => 'POST', path => '/items');
    is(response_start($events)->{status}, 409, 'a method handler may change the seeded status');
    is(response_header($events, 'Allow'), undef, 'the compiler-seeded Allow is absent after status changes away from 405');

    my $changed_with_custom = simple_router(
        method_not_allowed => sub {
            my ($c) = @_;
            return $c->response
                ->status(409)
                ->header('Allow' => 'PATCH')
                ->text('changed status with custom Allow');
        },
    )->to_app;
    $events = run_app($changed_with_custom, method => 'POST', path => '/items');
    my @allow_values = map { $_->[1] }
        grep { lc($_->[0]) eq 'allow' }
        @{response_start($events)->{headers}};
    is(\@allow_values, ['PATCH'], 'status-away filtering removes only the compiler seed and preserves later custom Allow');
};

subtest 'a respond-only generated 405 receives Allow at the event boundary' => sub {
    my $original_start = {
        type => 'http.response.start',
        status => 405,
        headers => [['x-opaque' => 'yes']],
    };
    my $opaque = Local::OpaqueResponse->new($original_start, 'opaque method');
    my $app = simple_router(
        method_not_allowed => sub { return $opaque },
    )->to_app;

    my $events = run_app($app, method => 'POST', path => '/items');

    is(response_start($events)->{status}, 405, 'the respond-only value emits its 405 start event');
    is(response_header($events, 'x-opaque'), 'yes', 'the respond-only value retains its original header');
    is(response_header($events, 'Allow'), 'GET, HEAD', 'the event boundary appends the computed Allow');
    is(response_body($events), 'opaque method', 'the respond-only value emits its body');
    is(
        $original_start,
        {
            type => 'http.response.start',
            status => 405,
            headers => [['x-opaque' => 'yes']],
        },
        'the original start event and header array remain unmodified',
    );
};

subtest 'a detached non-405 start event and intentional Allow pass by identity' => sub {
    my $original_headers = [
        ['Allow' => 'PATCH'],
        ['x-opaque' => 'detached'],
    ];
    my $original_start = {
        type => 'http.response.start',
        status => 409,
        headers => $original_headers,
    };
    my $opaque = Local::OpaqueResponse->new($original_start, 'opaque conflict');
    my $app = simple_router(
        method_not_allowed => sub { return $opaque },
    )->to_app;

    my $events = run_app($app, method => 'POST', path => '/items');
    my $emitted_start = response_start($events);

    is($emitted_start->{status}, 409, 'the detached response controls its final non-405 status');
    is(response_header($events, 'Allow'), 'PATCH', 'the detached intentional Allow is preserved');
    is(refaddr($emitted_start), refaddr($original_start), 'the non-405 detached start event passes by identity');
    is(refaddr($emitted_start->{headers}), refaddr($original_headers), 'its original header array passes by identity');
    is(response_body($events), 'opaque conflict', 'the detached response body is sent');
};

subtest 'fully matched application 404 and 405 responses pass untouched' => sub {
    my $app = router(routes => [
        route('/application-404' => sub {
            return $_[0]->response
                ->status(404)
                ->header('X-Origin' => 'application')
                ->text('application missing');
        }),
        route('/application-405' => sub {
            return $_[0]->response
                ->status(405)
                ->header('Allow' => 'BREW')
                ->text('application method');
        }),
    ])->to_app;

    my $not_found = run_app($app, path => '/application-404');
    is(response_start($not_found)->{status}, 404, 'a matched application 404 retains its status');
    is(response_header($not_found, 'X-Origin'), 'application', 'a matched application 404 retains its header');
    is(response_body($not_found), 'application missing', 'a matched application 404 retains its body');

    my $not_allowed = run_app($app, path => '/application-405');
    is(response_start($not_allowed)->{status}, 405, 'a matched application 405 retains its status');
    is(response_header($not_allowed, 'Allow'), 'BREW', 'a matched application 405 retains its custom Allow');
    is(response_body($not_allowed), 'application method', 'a matched application 405 retains its body');
};

subtest 'compiled 405 responses preserve first-seen method order' => sub {
    my @cases = (
        [
            'GET then POST',
            [
                route('/ordered' => sub { }, methods => 'GET'),
                route('/ordered' => sub { }, methods => 'POST'),
            ],
            'GET, HEAD, POST',
        ],
        [
            'POST then GET',
            [
                route('/ordered' => sub { }, methods => 'POST'),
                route('/ordered' => sub { }, methods => 'GET'),
            ],
            'POST, GET, HEAD',
        ],
        [
            'explicit HEAD before GET',
            [
                route('/ordered' => sub { }, methods => 'HEAD'),
                route('/ordered' => sub { }, methods => 'GET'),
            ],
            'HEAD, GET',
        ],
        [
            'deduplication without movement',
            [
                route('/ordered' => sub { }, methods => [qw(POST GET POST HEAD)]),
                route('/ordered' => sub { }, methods => [qw(GET POST)]),
            ],
            'POST, GET, HEAD',
        ],
    );

    for my $case (@cases) {
        my ($label, $routes, $expected) = @$case;
        my $app = router(routes => $routes)->to_app;
        my $events = run_app($app, method => 'TRACE', path => '/ordered');
        is(response_header($events, 'Allow'), $expected, $label);
    }
};

subtest 'generated response and Allow state is fresh for every request' => sub {
    my $calls = 0;
    my @initial_allow;
    my $app = router(
        routes => [
            route('/ordered' => sub { }, methods => 'GET'),
            route('/ordered' => sub { }, methods => 'POST'),
        ],
        method_not_allowed => sub {
            my ($c) = @_;
            ++$calls;
            push @initial_allow, $c->response->header('Allow');
            if ($calls == 1) {
                $c->response->remove_header('Allow')->header('Allow' => 'MUTATED');
            }
            return $c->text("request $calls");
        },
    )->to_app;

    my $first = run_app($app, method => 'TRACE', path => '/ordered');
    my $second = run_app($app, method => 'TRACE', path => '/ordered');

    is(response_header($first, 'Allow'), 'MUTATED', 'a custom first-request Allow is preserved');
    is(response_header($second, 'Allow'), 'GET, HEAD, POST', 'the next request receives a clean ordered Allow');
    is(\@initial_allow, ['GET, HEAD, POST', 'GET, HEAD, POST'], 'each Context begins with an independent seeded response');
};

subtest 'router middleware surrounds full and generated outcomes while route middleware is full-only' => sub {
    my @router_statuses;
    my $route_runs = 0;
    my $router_middleware = middleware(sub {
        my ($inner) = @_;
        return sub {
            my ($scope, $receive, $send) = @_;
            my $observing_send = sub {
                my ($event) = @_;
                push @router_statuses, $event->{status}
                    if ($event->{type} // '') eq 'http.response.start';
                return $send->($event);
            };
            return $inner->($scope, $receive, $observing_send);
        };
    });
    my $route_middleware = middleware(sub {
        my ($inner) = @_;
        return sub {
            ++$route_runs;
            return $inner->(@_);
        };
    });
    my $app = router(
        routes => [
            route('/wrapped' => sub { return $_[0]->text('full') },
                middleware => [$route_middleware]),
        ],
        middleware => [$router_middleware],
    )->to_app;

    run_app($app, method => 'GET', path => '/wrapped');
    run_app($app, method => 'GET', path => '/missing');
    run_app($app, method => 'POST', path => '/wrapped');

    is(\@router_statuses, [200, 404, 405], 'router middleware observes full, generated 404, and generated 405 responses');
    is($route_runs, 1, 'route middleware runs only for the full decision');
};

subtest 'public compilation returns apps and standalone HTTP routes retain fallback behavior' => sub {
    my $router = simple_router();
    is(ref(PAGI::Routing::Compiler->compile($router)), 'CODE', 'Compiler compiles a router to CODE');
    is(ref($router->to_app), 'CODE', 'Router to_app returns CODE');

    my $standalone = route('/standalone' => sub { return $_[0]->text('standalone') });
    my $standalone_app = $standalone->to_app;
    is(ref($standalone_app), 'CODE', 'standalone HTTP Route to_app returns CODE');
    is(response_body(run_app($standalone_app, path => '/standalone')), 'standalone', 'standalone route handles a full match');
    is(response_start(run_app($standalone_app, method => 'POST', path => '/standalone'))->{status}, 405,
        'standalone route retains generated 405 behavior');
    is(response_start(run_app($standalone_app, path => '/missing'))->{status}, 404,
        'standalone route retains generated 404 behavior');

    my $standalone_mount = mount('/future', routes => []);
    is(ref($standalone_mount->to_app), 'CODE', 'standalone Mount to_app returns CODE through one-node compilation');
};

subtest 'each to_app call resolves an independent middleware graph' => sub {
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
    my $description = router(
        routes => [
            route('/fresh' => sub { return $_[0]->text('fresh') }, middleware => [$descriptor]),
        ],
    );

    my $first = $description->to_app;
    my $second = $description->to_app;
    run_app($first, path => '/fresh');
    run_app($first, path => '/fresh');
    run_app($second, path => '/fresh');

    is($builds, 2, 'the middleware factory resolves once for each newly compiled graph');
    is(\@instances, [1, 1, 2], 'the two apps retain independent middleware instances');
};

{
    package Local::OpaqueResponse;

    sub new {
        my ($class, $start, $body) = @_;
        return bless {
            start => $start,
            body => $body,
        }, $class;
    }

    sub respond {
        my ($self, $send) = @_;
        $send->($self->{start})->get;
        return $send->({
            type => 'http.response.body',
            body => $self->{body},
            more => 0,
        });
    }
}

done_testing;
