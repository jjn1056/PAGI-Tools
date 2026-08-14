#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Encode qw(decode FB_CROAK LEAVE_SRC);
use Future;
use Scalar::Util qw(refaddr);

use lib 'lib';

use PAGI::App::Cascade;
use PAGI::App::URLMap;
use PAGI::Compose qw(compose);
use PAGI::Exception::IncompleteResponse;
use PAGI::Middleware::ErrorHandler;
use PAGI::Routing qw(middleware mount route router);

{
    package Local::UpgradeFailure;

    sub new {
        my ($class, $message) = @_;
        return bless { message => $message }, $class;
    }

    use overload q{""} => sub { return $_[0]{message} }, fallback => 1;
}

sub http_scope {
    my (%changes) = @_;
    my $path = exists $changes{path} ? $changes{path} : '/';
    return {
        type         => 'http',
        http_version => '1.1',
        method       => 'GET',
        scheme       => 'http',
        path         => $path,
        raw_path     => $path,
        root_path    => '',
        query_string => '',
        headers      => [],
        server       => ['testserver', 80],
        client       => ['127.0.0.1', 50000],
        %changes,
    };
}

sub receive_request {
    return Future->done({
        type => 'http.request',
        body => '',
        more => 0,
    });
}

sub run_http {
    my ($app, %changes) = @_;
    my (@events, @warnings);
    my $error;
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $ok = eval {
            Future->wrap($app->(
                http_scope(%changes),
                \&receive_request,
                $send,
            ))->get;
            1;
        };
        $error = $@ unless $ok;
    }
    return (\@events, $error, \@warnings);
}

sub response_start {
    my ($events) = @_;
    return (grep {
        (defined $_->{type} ? $_->{type} : '') eq 'http.response.start'
    } @$events)[0];
}

sub response_body {
    my ($events) = @_;
    return join '', map { defined $_->{body} ? $_->{body} : '' }
        grep {
            (defined $_->{type} ? $_->{type} : '') eq 'http.response.body'
        } @$events;
}

sub response_header {
    my ($events, $name) = @_;
    my $start = response_start($events);
    return unless $start;
    for my $header (@{$start->{headers} || []}) {
        next unless ref($header) eq 'ARRAY';
        return $header->[1]
            if lc(defined $header->[0] ? $header->[0] : '') eq lc($name);
    }
    return;
}

sub response_header_values {
    my ($events, $name) = @_;
    my $start = response_start($events);
    return [] unless $start;
    return [map { $_->[1] } grep {
        ref($_) eq 'ARRAY'
            && lc(defined $_->[0] ? $_->[0] : '') eq lc($name)
    } @{$start->{headers} || []}];
}

sub response_app {
    my ($status, $body) = @_;
    return sub {
        my ($scope, $receive, $send) = @_;
        return Future->wrap($send->({
            type    => 'http.response.start',
            status  => $status,
            headers => [],
        }))->then(sub {
            return Future->wrap($send->({
                type => 'http.response.body',
                body => $body,
                more => 0,
            }));
        });
    };
}

subtest 'removed Router callbacks are rejected rather than aliased' => sub {
    like(
        dies {
            router(routes => [], not_found => sub { return });
        },
        qr/unknown router option 'not_found'/,
        'the old not_found callback is rejected',
    );
    like(
        dies {
            router(routes => [], method_not_allowed => sub { return });
        },
        qr/unknown router option 'method_not_allowed'/,
        'the old method_not_allowed callback is rejected',
    );
};

subtest 'application fallback middleware renders custom 404 and 405 policy' => sub {
    my $application = compose(
        app => router(routes => [
            route('/items' => sub { return $_[0]->text('items') },
                methods => 'GET'),
        ]),
        middleware => [
            middleware('Routing::NotFound', handler => sub {
                my ($context, $trace) = @_;
                ok($trace->routing_declined, 'NotFound receives decline facts');
                return $context->text('application missing');
            }),
            middleware('Routing::MethodNotAllowed', handler => sub {
                my ($context, $trace) = @_;
                is($trace->allowed_methods, [qw(GET HEAD)],
                    'MethodNotAllowed receives a method snapshot');
                $context->response
                    ->header('Allow' => 'DELETE')
                    ->header('allow' => 'PATCH');
                return $context->text('application method policy');
            }),
        ],
    )->to_app;

    my ($missing, $missing_error, $missing_warnings)
        = run_http($application, path => '/missing');
    is($missing_error, undef, 'custom application 404 completes');
    is($missing_warnings, [], 'custom application 404 does not warn');
    is(response_start($missing)->{status}, 404, 'status is seeded to 404');
    is(response_body($missing), 'application missing', 'custom 404 body is used');

    my ($method, $method_error, $method_warnings) = run_http(
        $application,
        method => 'PUT',
        path   => '/items',
    );
    is($method_error, undef, 'custom application 405 completes');
    is($method_warnings, [], 'custom application 405 does not warn');
    is(response_start($method)->{status}, 405, 'status is seeded to 405');
    is(response_header_values($method, 'Allow'), ['GET, HEAD'],
        'conflicting duplicate Allow fields become one authoritative union');
    is(response_body($method), 'application method policy',
        'custom 405 body is used');
};

subtest 'Router and Mount boundaries provide local fallback policy' => sub {
    my $child = router(
        middleware => [
            middleware('Routing::NotFound', handler => sub {
                return $_[0]->text('child Router missing');
            }),
        ],
        routes => [
            route('/item' => sub { return $_[0]->text('child item') },
                methods => 'GET'),
        ],
    );
    my $root = router(routes => [
        mount('/local',
            router     => $child,
            name       => 'local',
            middleware => [
                middleware('Routing::MethodNotAllowed', handler => sub {
                    return $_[0]->text('mount method policy');
                }),
            ],
        ),
    ])->to_app;

    my ($missing, $missing_error) = run_http($root, path => '/local/missing');
    is($missing_error, undef, 'Router-local NotFound completes');
    is(response_start($missing)->{status}, 404,
        'Router boundary owns its local 404');
    is(response_body($missing), 'child Router missing',
        'Router-local renderer is selected');

    my ($method, $method_error) = run_http(
        $root,
        method => 'PUT',
        path   => '/local/item',
    );
    is($method_error, undef, 'Mount-local MethodNotAllowed completes');
    is(response_start($method)->{status}, 405,
        'Mount occurrence owns its local 405');
    is(response_body($method), 'mount method policy',
        'Mount-local renderer is selected');
};

subtest 'a naked Router is unanswered while Compose supplies complete defaults' => sub {
    local $ENV{PAGI_ENV} = 'production';
    my $routing = router(routes => [
        route('/known' => sub { return $_[0]->text('known') }),
    ]);

    my ($naked, $naked_error, $naked_warnings)
        = run_http($routing->to_app, path => '/missing');
    is($naked_error, undef, 'naked Router decline is normal completion');
    is($naked_warnings, [], 'naked Router decline does not warn');
    is($naked, [], 'naked Router sends no response for a miss');

    my ($complete, $complete_error, $complete_warnings)
        = run_http(compose(app => $routing)->to_app, path => '/missing');
    is($complete_error, undef, 'Compose completes the Router application');
    is($complete_warnings, [], 'Compose 404 does not enter error handling');
    is(response_start($complete)->{status}, 404,
        'Compose supplies its mandatory NotFound failsafe');
};

subtest 'opaque Mounts guard incompletion while Router Mounts preserve evidence' => sub {
    local $ENV{PAGI_ENV} = 'production';
    my $child = router(routes => [
        route('/known' => sub { return $_[0]->text('known') }),
    ]);

    my $opaque = compose(app => router(routes => [
        mount('/opaque' => $child->to_app),
    ]))->to_app;
    my ($opaque_events, $opaque_error, $opaque_warnings)
        = run_http($opaque, path => '/opaque/missing');
    is($opaque_error, undef, 'Compose contains opaque child incompletion');
    is(response_start($opaque_events)->{status}, 500,
        'an opaque compiled Router cannot publish a 404 decline outward');
    like($opaque_warnings->[0], qr/completed without starting a response/,
        'the completion guard reports the opaque child');

    my $aware = compose(
        app => router(routes => [
            mount('/aware', router => $child, name => 'aware'),
        ]),
        middleware => [
            middleware('Routing::NotFound', handler => sub {
                return $_[0]->text('trusted outer fallback');
            }),
        ],
    )->to_app;
    my ($aware_events, $aware_error, $aware_warnings)
        = run_http($aware, path => '/aware/missing');
    is($aware_error, undef, 'Router Mount decline completes through outer policy');
    is($aware_warnings, [], 'trusted Router Mount decline does not warn');
    is(response_start($aware_events)->{status}, 404,
        'Router Mount preserves trusted decline evidence');
    is(response_body($aware_events), 'trusted outer fallback',
        'the outer application fallback owns the decline');

    my $complete_child = compose(
        app => $child,
        middleware => [
            middleware('Routing::NotFound', handler => sub {
                return $_[0]->text('opaque child fallback');
            }),
        ],
    )->to_app;
    my $intentionally_opaque = compose(app => router(routes => [
        mount('/opaque' => $complete_child),
    ]))->to_app;
    my ($child_events, $child_error, $child_warnings)
        = run_http($intentionally_opaque, path => '/opaque/missing');
    is($child_error, undef, 'Compose-wrapped opaque child completes itself');
    is($child_warnings, [], 'child fallback is a normal response');
    is(response_start($child_events)->{status}, 404,
        'the opaque child Compose supplies its own fallback');
    is(response_body($child_events), 'opaque child fallback',
        'the child policy remains inside the opaque boundary');
};

subtest 'URLMap keeps naked and Compose-wrapped Routers opaque' => sub {
    local $ENV{PAGI_ENV} = 'production';
    my $routing = router(routes => [
        route('/known' => sub { return $_[0]->text('known') }),
    ]);

    my $naked_map = PAGI::App::URLMap->new;
    $naked_map->mount('/api' => $routing->to_app);
    my ($naked, $naked_error, $naked_warnings) = run_http(
        compose(app => $naked_map)->to_app,
        path => '/api/missing',
    );
    is($naked_error, undef, 'outer Compose contains URLMap child incompletion');
    is(response_start($naked)->{status}, 500,
        'URLMap does not leak a naked Router decline outward');
    like($naked_warnings->[0], qr/completed without starting a response/,
        'URLMap naked Router is reported as incomplete');

    my $wrapped = compose(
        app => $routing,
        middleware => [
            middleware('Routing::NotFound', handler => sub {
                return $_[0]->text('URLMap child fallback');
            }),
        ],
    )->to_app;
    my $wrapped_map = PAGI::App::URLMap->new;
    $wrapped_map->mount('/api' => $wrapped);
    my ($complete, $complete_error, $complete_warnings) = run_http(
        compose(app => $wrapped_map)->to_app,
        path => '/api/missing',
    );
    is($complete_error, undef, 'Compose-wrapped URLMap child completes');
    is($complete_warnings, [], 'URLMap child fallback does not warn');
    is(response_start($complete)->{status}, 404,
        'URLMap child Compose supplies the fallback');
    is(response_body($complete), 'URLMap child fallback',
        'URLMap preserves the complete child response');
};

subtest 'Cascade advances on trusted Router decline evidence' => sub {
    my $routing = router(routes => [
        route('/known' => sub { return $_[0]->text('known') }),
    ])->to_app;
    my $cascade = PAGI::App::Cascade->new(apps => [
        $routing,
        response_app(200, 'next application'),
    ])->to_app;

    my ($events, $error, $warnings)
        = run_http($cascade, path => '/missing');
    is($error, undef, 'trusted decline advances without error');
    is($warnings, [], 'trusted decline does not warn');
    is(response_start($events)->{status}, 200,
        'the next Cascade child owns the response');
    is(response_body($events), 'next application',
        'Cascade did not require a generated 404 to advance');
};

subtest 'Cascade rejects arbitrary silent native children' => sub {
    my $next_invocations = 0;
    my $next = response_app(200, 'must not run');
    my $cascade = PAGI::App::Cascade->new(apps => [
        sub { return Future->done },
        sub {
            $next_invocations++;
            return $next->(@_);
        },
    ])->to_app;

    my ($events, $error, $warnings)
        = run_http($cascade, path => '/missing');
    isa_ok($error, ['PAGI::Exception::IncompleteResponse'],
        'silent native child raises the typed lifecycle failure');
    is($warnings, [], 'the typed failure does not warn');
    is($events, [], 'no response from a later child is emitted');
    is($next_invocations, 0, 'Cascade does not invoke the next child');
};

subtest 'ErrorHandler awaits reporting and rethrows post-start failures' => sub {
    my $original = Local::UpgradeFailure->new('database stream failed');
    my $reporting = Future->new;
    my $reported;
    my $middleware = PAGI::Middleware::ErrorHandler->new(
        on_error => sub {
            $reported = $_[0];
            return $reporting;
        },
    );
    my @events;
    my $wrapped = $middleware->wrap(sub {
        my ($scope, $receive, $send) = @_;
        return Future->wrap($send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        }))->then(sub { return Future->fail($original) });
    });
    my $future = Future->wrap($wrapped->(
        http_scope(),
        \&receive_request,
        sub {
            push @events, $_[0];
            return Future->done;
        },
    ));

    ok(!$future->is_ready, 'post-start failure waits for on_error');
    is(refaddr($reported), refaddr($original),
        'on_error receives the original exception object');
    is(scalar(grep {
        (defined $_->{type} ? $_->{type} : '') eq 'http.response.start'
    } @events), 1, 'only the application response start was emitted');

    $reporting->done;
    ok($future->is_failed, 'post-start failure is rethrown after reporting');
    is(refaddr($future->failure), refaddr($original),
        'the original exception object is rethrown unchanged');
    is(scalar(grep {
        (defined $_->{type} ? $_->{type} : '') eq 'http.response.start'
    } @events), 1, 'ErrorHandler never emits a replacement response start');
};

subtest 'built-in ErrorHandler output is no-store and byte-correct UTF-8' => sub {
    my $middleware = PAGI::Middleware::ErrorHandler->new(
        content_type => 'text/plain',
        development  => 1,
    );
    my ($events, $error, $warnings) = run_http(
        $middleware->wrap(sub {
            return Future->fail("database snowman \x{2603}\n");
        }),
    );
    is($error, undef, 'pre-start failure is rendered');
    is($warnings, [], 'ordinary ErrorHandler rendering is warning-free');
    is(response_header($events, 'Cache-Control'), 'no-store',
        'built-in response disables storage');
    my $body = response_body($events);
    ok(!utf8::is_utf8($body), 'built-in body is an octet string');
    is(0 + response_header($events, 'Content-Length'), length($body),
        'Content-Length counts emitted bytes');
    like(decode('UTF-8', $body, FB_CROAK | LEAVE_SRC), qr/snowman \x{2603}/,
        'built-in development text decodes as UTF-8 exactly once');
};

subtest 'the standalone guide carries the routing fallback migration' => sub {
    open my $guide_fh, '<:encoding(UTF-8)', 'UPGRADING.md'
        or die "cannot read UPGRADING.md: $!";
    local $/;
    my $guide = <$guide_fh>;
    close $guide_fh;
    like($guide, qr/^## Routing fallbacks and application error handling$/m,
        'the existing-user handoff includes the migration section');
};

done_testing;
