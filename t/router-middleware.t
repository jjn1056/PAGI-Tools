#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::App::Router;
use PAGI::Routing qw(middleware);

async sub request {
    my ($app, %changes) = @_;
    my @events;
    my $scope = {
        type => 'http', method => 'GET', path => '/', headers => [], %changes,
    };
    my $receive = sub {
        return Future->done({ type => 'http.request', body => '', more => 0 });
    };
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    await $app->($scope, $receive, $send);
    return \@events;
}

sub event_body {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
}

sub factory {
    my ($label, $trace, $builds) = @_;
    return sub {
        my ($inner) = @_;
        ++$$builds if $builds;
        return async sub {
            push @$trace, "$label before";
            await $inner->(@_);
            push @$trace, "$label after";
        };
    };
}

{
    package Local::ObjectMiddleware;
    use Future::AsyncAwait;

    sub new {
        my ($class, $label, $trace, $builds) = @_;
        return bless {
            label => $label, trace => $trace, builds => $builds,
        }, $class;
    }

    sub wrap {
        my ($self, $inner) = @_;
        ++${$self->{builds}};
        return async sub {
            push @{$self->{trace}}, "$self->{label} before";
            await $inner->(@_);
            push @{$self->{trace}}, "$self->{label} after";
        };
    }
}

subtest 'public route middleware uses native app-to-app onion order' => sub {
    my (@trace, $builds);
    $builds = 0;
    my $router = PAGI::App::Router->new;
    $router->get('/' => [
        factory('outer', \@trace, \$builds),
        factory('inner', \@trace, \$builds),
    ] => sub {
        my ($c) = @_;
        push @trace, 'handler ' . ref($c);
        return $c->text('home');
    });

    is($builds, 0, 'declaration normalizes without wrapping');
    my $app = $router->to_app;
    is($builds, 2, 'both factories run at compilation');
    my $events = request($app)->get;
    is(event_body($events), 'home', 'the Context handler response is emitted');
    is(\@trace, [
        'outer before', 'inner before', 'handler PAGI::Context::HTTP',
        'inner after', 'outer after',
    ], 'first listed middleware is outermost');

    @trace = ();
    request($app)->get;
    is($builds, 2, 'a retained app never rebuilds middleware per request');
};

subtest 'object and explicit description forms compose on the public route' => sub {
    my (@trace, $object_builds, $factory_builds);
    my $object = Local::ObjectMiddleware->new(
        'object', \@trace, \$object_builds,
    );
    my $description = middleware(
        factory('description', \@trace, \$factory_builds),
    );
    my $router = PAGI::App::Router->new;
    $router->get('/' => [$object, $description] => sub {
        push @trace, 'handler';
        return $_[0]->text('mixed');
    });

    my $snapshot = $router->to_router;
    is([map { ref($_) } @{$snapshot->routes->[0]->middleware}], [
        'PAGI::Routing::Middleware', 'PAGI::Routing::Middleware',
    ], 'both entries normalize to immutable descriptions');
    my $events = request($router->to_app)->get;
    is(event_body($events), 'mixed', 'mixed middleware forms preserve response flow');
    is(\@trace, [
        'object before', 'description before', 'handler',
        'description after', 'object after',
    ], 'object and description retain declaration order');
    is([$object_builds, $factory_builds], [1, 1],
        'each configured form wraps once for the compiled app');
};

subtest 'class-name middleware is accepted and resolved at compilation' => sub {
    my $router = PAGI::App::Router->new;
    $router->get('/' => ['RequestId'] => sub {
        my ($c) = @_;
        return $c->text(defined $c->scope->{request_id} ? 'has id' : 'missing id');
    });

    my $events = request($router->to_app)->get;
    is(event_body($events), 'has id', 'short class name resolves through shared middleware');
    my ($request_id) = map { $_->[1] }
        grep { lc($_->[0]) eq 'x-request-id' } @{$events->[0]{headers}};
    ok(defined $request_id && length $request_id,
        'the class middleware also modifies the response stream');
};

subtest 'middleware can short circuit or wrap native channels' => sub {
    my $handler_calls = 0;
    my $auth = sub {
        my ($inner) = @_;
        return sub {
            my ($scope, $receive, $send) = @_;
            $send->({ type => 'http.response.start', status => 401, headers => [] })->get;
            $send->({ type => 'http.response.body', body => 'denied', more => 0 })->get;
            return Future->done;
        };
    };
    my $router = PAGI::App::Router->new;
    $router->get('/denied' => [$auth] => sub {
        ++$handler_calls;
        return $_[0]->text('must not run');
    });

    my $denied = request($router->to_app, path => '/denied')->get;
    is([$denied->[0]{status}, event_body($denied), $handler_calls],
        [401, 'denied', 0], 'native middleware may own the response');

    my $inject = sub {
        my ($inner) = @_;
        return sub {
            my ($scope, $receive, $send) = @_;
            my $wrapped_receive = sub {
                return Future->done({ type => 'synthetic' });
            };
            my $wrapped_send = sub {
                my ($event) = @_;
                if (($event->{type} // '') eq 'http.response.start') {
                    $event = {
                        %$event,
                        headers => [@{$event->{headers} // []}, ['x-wrapped', 'yes']],
                    };
                }
                return $send->($event);
            };
            return $inner->($scope, $wrapped_receive, $wrapped_send);
        };
    };
    my $channels = PAGI::App::Router->new;
    $channels->get('/channels' => [$inject] => sub {
        my ($c) = @_;
        my $event = $c->receive->()->get;
        return $c->text($event->{type});
    });
    my $events = request($channels->to_app, path => '/channels')->get;
    is(event_body($events), 'synthetic', 'wrapped receive reaches the Context');
    my ($wrapped) = map { $_->[1] }
        grep { lc($_->[0]) eq 'x-wrapped' } @{$events->[0]{headers}};
    is($wrapped, 'yes', 'wrapped send changes the emitted Response');
};

subtest 'group, known mount, opaque mount, and route middleware stack once' => sub {
    my (@trace, $builds);
    my $child = PAGI::App::Router->new(
        middleware => [factory('child router', \@trace, \$builds)],
    );
    $child->get('/data' => [factory('route', \@trace, \$builds)] => sub {
        push @trace, 'handler';
        return $_[0]->text('data');
    });

    my $root = PAGI::App::Router->new(
        middleware => [factory('root router', \@trace, \$builds)],
    );
    $root->group('/api' => [factory('group', \@trace, \$builds)] => sub {
        my ($api) = @_;
        $api->mount('/v1' => [factory('known mount', \@trace, \$builds)],
            router => $child)->name('v1');
    });

    my $events = request($root->to_app, path => '/api/v1/data')->get;
    is(event_body($events), 'data', 'nested public middleware graph responds');
    is(\@trace, [
        'root router before', 'group before', 'known mount before',
        'child router before', 'route before', 'handler',
        'route after', 'child router after', 'known mount after',
        'group after', 'root router after',
    ], 'every structural layer retains native onion order');
    is($builds, 5, 'each declared occurrence wraps once');
};

subtest 'route middleware is uniform for normal WebSocket and SSE handlers' => sub {
    my @trace;
    my $mw = factory('protocol', \@trace);
    my $router = PAGI::App::Router->new;
    $router->websocket('/ws' => [$mw] => sub {
        push @trace, 'handler ' . ref($_[0]);
        return Future->done;
    });
    $router->sse('/events' => [$mw] => sub {
        push @trace, 'handler ' . ref($_[0]);
        return Future->done;
    });
    my $app = $router->to_app;

    request($app, type => 'websocket', method => undef, path => '/ws')->get;
    request($app, type => 'sse', method => undef, path => '/events')->get;
    is(\@trace, [
        'protocol before', 'handler PAGI::Context::WebSocket', 'protocol after',
        'protocol before', 'handler PAGI::Context::SSE', 'protocol after',
    ], 'protocol middleware wraps the shared Context adapter');
};

subtest 'invalid entries fail during public declaration normalization' => sub {
    my $router = PAGI::App::Router->new;
    like(dies { $router->get('/hash' => [{}] => sub { }) },
        qr/middleware entry 0 must be/, 'hashref entry is rejected');
    my $object = bless {}, 'Local::NoWrap';
    like(dies { $router->get('/object' => [$object] => sub { }) },
        qr/middleware entry 0 must be/, 'object without wrap is rejected');
    like(dies { $router->get('/empty' => [''] => sub { }) },
        qr/middleware entry 0 must be/, 'empty class name is rejected');
};

done_testing;
