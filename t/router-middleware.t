#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Response::Text ();
use PAGI::Routing qw(middleware mount route router sse websocket);

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

{
    package Local::BoundController;
    use Future;
    use Future::AsyncAwait;
    use PAGI::Response::Text ();
    use PAGI::Routing qw(middleware route router);
    use Scalar::Util qw(refaddr);

    sub new {
        my ($class) = @_;
        return bless { trace => [] }, $class;
    }

    sub routing {
        my ($self) = @_;
        return router(routes => [
            route('/private' => sub { return $self->private(@_) },
                middleware => [middleware(sub {
                    my ($inner) = @_;
                    return $self->require_auth($inner);
                })],
            ),
        ]);
    }

    sub require_auth {
        my ($self, $inner) = @_;
        ++$self->{factory_calls};
        $self->{factory_receiver} = refaddr($self);
        return async sub {
            my ($scope, $receive, $send) = @_;
            ++$self->{wrapper_calls};
            push @{$self->{trace}}, 'auth before';
            my $copy = { %$scope, bound_middleware => 'present' };
            my $wrapped_send = sub {
                my ($event) = @_;
                return $send->({ %$event, bound_middleware => 1 });
            };
            await Future->wrap($inner->($copy, $receive, $wrapped_send));
            push @{$self->{trace}}, 'auth after';
            return;
        };
    }

    sub private {
        my ($self, $request) = @_;
        $self->{handler_receiver} = refaddr($self);
        $self->{handler_arity} = scalar @_;
        $self->{handler_argument} = ref($request);
        $self->{handler_scope} = $request->scope;
        push @{$self->{trace}}, 'handler';
        return PAGI::Response::Text->new('private');
    }
}

subtest 'declarative route binds ordinary controller and middleware closures once' => sub {
    my $controller = Local::BoundController->new;
    my $routing = $controller->routing;
    my $identity = refaddr($controller);

    is($controller->{factory_calls}, undef,
        'declaration does not run the bound middleware factory');
    my $app = $routing->to_app;
    is([$controller->{factory_calls}, $controller->{factory_receiver}],
        [1, $identity],
        'compilation invokes the middleware method once on the exact object');

    my $original = {
        type => 'http', method => 'GET', path => '/private', headers => [],
    };
    my @events;
    $app->(
        $original,
        sub { return Future->done({
            type => 'http.request', body => '', more => 0,
        }) },
        sub { push @events, $_[0]; return Future->done },
    )->get;

    is(event_body(\@events), 'private',
        'the explicitly bound handler response is emitted');
    is($controller->{trace}, ['auth before', 'handler', 'auth after'],
        'bound middleware surrounds the bound handler in declared order');
    is([$controller->{handler_receiver}, $controller->{handler_arity},
        $controller->{handler_argument}],
        [$identity, 2, 'PAGI::Request'],
        'ordinary closure binding supplies exactly the object and Request');
    is($controller->{handler_scope}{bound_middleware}, 'present',
        'the bound handler sees the middleware scope clone');
    ok(!exists $original->{bound_middleware},
        'the middleware does not mutate the caller-owned scope');
    is([map { $_->{bound_middleware} } @events], [1, 1],
        'the middleware wraps every response event');

    request($app, path => '/private')->get;
    is([$controller->{factory_calls}, $controller->{wrapper_calls}], [1, 2],
        'the compiled factory is retained while the wrapper runs per request');
};

subtest 'declarative route middleware uses native app-to-app onion order' => sub {
    my (@trace, $builds);
    $builds = 0;
    my $routing = router(routes => [
        route('/' => sub {
            my ($request) = @_;
            push @trace, 'handler ' . ref($request);
            return PAGI::Response::Text->new('home');
        }, middleware => [
            middleware(factory('outer', \@trace, \$builds)),
            middleware(factory('inner', \@trace, \$builds)),
        ]),
    ]);

    is($builds, 0, 'declaration retains descriptions without wrapping');
    my $app = $routing->to_app;
    is($builds, 2, 'both factories run at compilation');
    my $events = request($app)->get;
    is(event_body($events), 'home', 'the Request handler response is emitted');
    is(\@trace, [
        'outer before', 'inner before', 'handler PAGI::Request',
        'inner after', 'outer after',
    ], 'first listed middleware is outermost');

    @trace = ();
    request($app)->get;
    is($builds, 2, 'a retained app never rebuilds middleware per request');
};

subtest 'object and factory descriptions compose on a declarative route' => sub {
    my (@trace, $object_builds, $factory_builds);
    my $object = Local::ObjectMiddleware->new(
        'object', \@trace, \$object_builds,
    );
    my $object_description = middleware($object);
    my $factory_description = middleware(
        factory('description', \@trace, \$factory_builds),
    );
    my $routing = router(routes => [
        route('/' => sub {
            push @trace, 'handler';
            return PAGI::Response::Text->new('mixed');
        }, middleware => [$object_description, $factory_description]),
    ]);

    is([map { ref($_) } @{$routing->routes->[0]->middleware}], [
        'PAGI::Routing::Middleware', 'PAGI::Routing::Middleware',
    ], 'both explicit entries remain immutable descriptions');
    my $events = request($routing->to_app)->get;
    is(event_body($events), 'mixed', 'mixed middleware forms preserve response flow');
    is(\@trace, [
        'object before', 'description before', 'handler',
        'description after', 'object after',
    ], 'object and description retain declaration order');
    is([$object_builds, $factory_builds], [1, 1],
        'each configured form wraps once for the compiled app');
};

subtest 'class-name middleware is accepted and resolved at compilation' => sub {
    my $routing = router(routes => [
        route('/' => sub {
            my ($request) = @_;
            return PAGI::Response::Text->new(
                defined $request->scope->{request_id} ? 'has id' : 'missing id',
            );
        }, middleware => [middleware('RequestId')]),
    ]);

    my $events = request($routing->to_app)->get;
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
    my $routing = router(routes => [
        route('/denied' => sub {
            ++$handler_calls;
            return PAGI::Response::Text->new('must not run');
        }, middleware => [middleware($auth)]),
    ]);

    my $denied = request($routing->to_app, path => '/denied')->get;
    is([$denied->[0]{status}, event_body($denied), $handler_calls],
        [401, 'denied', 0], 'native middleware may own the response');

    my $inject = sub {
        my ($inner) = @_;
        return sub {
            my ($scope, $receive, $send) = @_;
            my $wrapped_receive = sub {
                return Future->done({
                    type => 'http.request', body => 'synthetic', more => 0,
                });
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
    my $channels = router(routes => [
        route('/channels' => async sub {
            my ($request) = @_;
            my $body = await $request->body;
            return PAGI::Response::Text->new($body);
        }, middleware => [middleware($inject)]),
    ]);
    my $events = request($channels->to_app, path => '/channels')->get;
    is(event_body($events), 'synthetic', 'wrapped receive reaches the Request body');
    my ($wrapped) = map { $_->[1] }
        grep { lc($_->[0]) eq 'x-wrapped' } @{$events->[0]{headers}};
    is($wrapped, 'yes', 'wrapped send changes the emitted Response');
};

subtest 'nested Mount, Router, and route middleware stack once' => sub {
    my (@trace, $builds);
    my $child = router(
        middleware => [middleware(factory('child router', \@trace, \$builds))],
        routes => [
            route('/data' => sub {
                push @trace, 'handler';
                return PAGI::Response::Text->new('data');
            }, middleware => [middleware(factory('route', \@trace, \$builds))]),
        ],
    );
    my $root = router(
        middleware => [middleware(factory('root router', \@trace, \$builds))],
        routes => [
            mount('/api', routes => [
                mount('/v1', app => $child, name => 'v1',
                    middleware => [middleware(factory(
                        'known mount', \@trace, \$builds,
                    ))]),
            ], middleware => [middleware(factory(
                'callback Mount', \@trace, \$builds,
            ))]),
        ],
    );

    my $events = request($root->to_app, path => '/api/v1/data')->get;
    is(event_body($events), 'data', 'nested public middleware graph responds');
    is(\@trace, [
        'root router before', 'callback Mount before', 'known mount before',
        'child router before', 'route before', 'handler',
        'route after', 'child router after', 'known mount after',
        'callback Mount after', 'root router after',
    ], 'every structural layer retains native onion order');
    is($builds, 5, 'each declared occurrence wraps once');
};

subtest 'route middleware is uniform for normal WebSocket and SSE handlers' => sub {
    my @trace;
    my $mw = factory('protocol', \@trace);
    my $routing = router(routes => [
        websocket('/ws' => sub {
            push @trace, 'handler ' . ref($_[0]);
            return Future->done;
        }, middleware => [middleware($mw)]),
        sse('/events' => sub {
            push @trace, 'handler ' . ref($_[0]);
            return Future->done;
        }, middleware => [middleware($mw)]),
    ]);
    my $app = $routing->to_app;

    request($app, type => 'websocket', method => undef, path => '/ws')->get;
    request($app, type => 'sse', method => undef, path => '/events')->get;
    is(\@trace, [
        'protocol before', 'handler PAGI::WebSocket', 'protocol after',
        'protocol before', 'handler PAGI::SSE', 'protocol after',
    ], 'protocol middleware wraps the shared direct-object adapter');
};

subtest 'declarative routes reject bare middleware entries' => sub {
    like(dies { route('/hash' => sub { }, middleware => [{}]) },
        qr/middleware entry 0 must be/, 'hashref entry is rejected');
    my $object = bless {}, 'Local::NoWrap';
    like(dies { route('/object' => sub { }, middleware => [$object]) },
        qr/middleware entry 0 must be/, 'object without wrap is rejected');
    like(dies { route('/empty' => sub { }, middleware => ['']) },
        qr/middleware entry 0 must be/, 'empty class name is rejected');
};

done_testing;
