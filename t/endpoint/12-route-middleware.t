#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util ();

use lib 'lib';
use PAGI::Endpoint::Router ();
use PAGI::Response ();
use PAGI::Response::Text ();
use PAGI::Routing qw(middleware);
use PAGI::Test::Client ();

BEGIN {
    $INC{'PAGI/Middleware/RequestId.pm'} = __FILE__;
    $INC{'PAGI/Middleware/Session.pm'} = __FILE__;
}

sub scope {
    my (%changes) = @_;
    return {
        type => 'http', method => 'GET', path => '/', raw_path => '/', root_path => '',
        path_params => {}, headers => [], %changes,
    };
}

sub run_scope {
    my ($app, $request_scope) = @_;
    my @events;
    $app->(
        $request_scope,
        sub { return Future->done({ type => 'unused.receive' }) },
        sub { push @events, $_[0]; return Future->done },
    )->get;
    return \@events;
}

{
    package PAGI::Middleware::RequestId;
    sub new {
        ++$Local::MiddlewareEndpoint::request_id_constructions;
        return bless {}, $_[0];
    }
    sub wrap {
        my ($self, $inner) = @_;
        ++$Local::MiddlewareEndpoint::request_id_wraps;
        return async sub {
            push @Local::MiddlewareEndpoint::order, 'request-id enter';
            my $returned = $inner->(@_);
            await Future->wrap($returned);
            push @Local::MiddlewareEndpoint::order, 'request-id exit';
            return;
        };
    }
}

{
    package PAGI::Middleware::Session;
    sub new {
        my ($class, %config) = @_;
        push @Local::MiddlewareEndpoint::session_configs, { %config };
        return bless { %config }, $class;
    }
    sub wrap {
        my ($self, $inner) = @_;
        return async sub {
            push @Local::MiddlewareEndpoint::order, 'session enter';
            my $returned = $inner->(@_);
            await Future->wrap($returned);
            push @Local::MiddlewareEndpoint::order, 'session exit';
            return;
        };
    }
}

{
    package Local::ConfiguredMiddleware;
    sub new { bless { wraps => 0, calls => 0 }, $_[0] }
    sub wrap {
        my ($self, $inner) = @_;
        ++$self->{wraps};
        return async sub {
            my ($scope, $receive, $send) = @_;
            ++$self->{calls};
            push @Local::MiddlewareEndpoint::order, 'object enter';
            my $cloned = { %$scope, endpoint_clone => 'present' };
            my $wrapped_send = sub {
                my ($event) = @_;
                return $send->({ %$event, endpoint_send_wrapper => 1 });
            };
            my $returned = $inner->($cloned, $receive, $wrapped_send);
            await Future->wrap($returned);
            push @Local::MiddlewareEndpoint::order, 'object exit';
            return;
        };
    }
}

{
    package Local::MiddlewareEndpoint;
    use parent 'PAGI::Endpoint::Router';
    our ($request_id_constructions, $request_id_wraps, $auth_factories,
        $auth_calls, $downstream_calls);
    our (@order, @session_configs, @handler_scopes);

    sub new {
        my ($class, %args) = @_;
        return bless { object => $args{object} }, $class;
    }

    sub list {
        my ($self) = @_;
        return [
            'RequestId',
            $self->middleware_as('require_auth'),
            $self->{object},
            PAGI::Routing::middleware('Session', cookie_name => 'sid'),
        ];
    }

    sub routes {
        my ($self, $r) = @_;
        $r->get('/admin' => $self->list => 'admin');
        $r->get('/deny' => $self->list => 'admin');
        $r->websocket('/socket' => $self->list => 'socket');
        $r->sse('/events' => $self->list => 'events');
    }

    sub require_auth {
        my ($self, $inner) = @_;
        ++$auth_factories;
        return async sub {
            my ($scope, $receive, $send) = @_;
            ++$auth_calls;
            push @order, 'auth enter';
            if ($scope->{path} eq '/deny') {
                push @order, 'auth short circuit';
                await $send->({
                    type => 'http.response.start', status => 403, headers => [],
                });
                await $send->({
                    type => 'http.response.body', body => 'denied', more => 0,
                });
                push @order, 'auth exit';
                return;
            }
            ++$downstream_calls;
            my $returned = $inner->($scope, $receive, $send);
            await Future->wrap($returned);
            push @order, 'auth exit';
            return;
        };
    }

    sub admin {
        my ($self, $request) = @_;
        push @order, 'handler';
        push @handler_scopes, $request->scope;
        return PAGI::Response::Text->new('admin');
    }

    sub socket {
        my ($self, $websocket) = @_;
        push @order, 'handler';
        push @handler_scopes, $websocket->scope;
        return $websocket->close(1000, 'middleware');
    }

    sub events {
        my ($self, $sse) = @_;
        push @order, 'handler';
        push @handler_scopes, $sse->scope;
        $sse->start->get;
        return $sse->close;
    }
}

{
    package Local::MissingMiddlewareMethod;
    use parent 'PAGI::Endpoint::Router';
    sub routes {
        my ($self, $r) = @_;
        $r->get('/bad' => [$self->middleware_as('missing')] => sub {
            return PAGI::Response::Text->new('bad');
        });
    }
}

{
    package Local::AsyncMiddlewareFactory;
    use parent 'PAGI::Endpoint::Router';
    sub routes {
        my ($self, $r) = @_;
        $r->get('/bad' => [$self->middleware_as('async_factory')] => sub {
            return PAGI::Response::Text->new('bad');
        });
    }
    sub async_factory {
        my ($self, $inner) = @_;
        return Future->done(sub { return $inner->(@_) });
    }
}

{
    package Local::MountMiddlewareEndpoint;
    use parent 'PAGI::Endpoint::Router';
    our @order;

    sub routes {
        my ($self, $r) = @_;
        $r->mount('/nested',
            routes => sub {
                my ($child) = @_;
                $child->get('/leaf' => 'leaf');
            },
            middleware => [$self->middleware_as('around_mount')],
        );
    }

    sub around_mount {
        my ($self, $inner) = @_;
        $self->{factory_receiver} = Scalar::Util::refaddr($self);
        return async sub {
            push @order, 'mount before';
            await Future->wrap($inner->(@_));
            push @order, 'mount after';
            return;
        };
    }

    sub leaf {
        my ($self, $request) = @_;
        $self->{handler_receiver} = Scalar::Util::refaddr($self);
        push @order, 'leaf';
        return PAGI::Response::Text->new('nested');
    }
}

sub reset_runtime {
    @Local::MiddlewareEndpoint::order = ();
    @Local::MiddlewareEndpoint::handler_scopes = ();
    $Local::MiddlewareEndpoint::auth_calls = 0;
    $Local::MiddlewareEndpoint::downstream_calls = 0;
}

subtest 'four universal forms normalize at declaration and compile synchronously' => sub {
    my $object = Local::ConfiguredMiddleware->new;
    my $endpoint = Local::MiddlewareEndpoint->new(object => $object);
    @Local::MiddlewareEndpoint::session_configs = ();
    $Local::MiddlewareEndpoint::request_id_constructions = 0;
    $Local::MiddlewareEndpoint::request_id_wraps = 0;
    $Local::MiddlewareEndpoint::auth_factories = 0;

    my $router = $endpoint->to_router;
    is([$Local::MiddlewareEndpoint::request_id_constructions,
        $Local::MiddlewareEndpoint::request_id_wraps,
        $Local::MiddlewareEndpoint::auth_factories, $object->{wraps}],
        [0, 0, 0, 0], 'materialization stores descriptions without running helpers');
    is(\@Local::MiddlewareEndpoint::session_configs, [],
        'configured class is not constructed during normalization');

    my $app = $router->to_app;
    is([$Local::MiddlewareEndpoint::request_id_constructions,
        $Local::MiddlewareEndpoint::request_id_wraps,
        $Local::MiddlewareEndpoint::auth_factories, $object->{wraps}],
        [4, 4, 4, 4], 'each route compiles all four middleware forms once');
    is(\@Local::MiddlewareEndpoint::session_configs, [
        { cookie_name => 'sid' }, { cookie_name => 'sid' },
        { cookie_name => 'sid' }, { cookie_name => 'sid' },
    ],
        'middleware descriptions pass configuration to the class constructor');

    like(dies { Local::MissingMiddlewareMethod->to_router },
        qr/has no middleware method "missing"/,
        'middleware_as validates the method during route declaration');
    like(dies { Local::AsyncMiddlewareFactory->to_app },
        qr/middleware factory must return PAGI app coderef; got Future/,
        'middleware factory must return its native app synchronously');
};

subtest 'HTTP middleware is first-listed-outermost, calls downstream, wraps send, and clones scope' => sub {
    my $object = Local::ConfiguredMiddleware->new;
    my $endpoint = Local::MiddlewareEndpoint->new(object => $object);
    my $app = $endpoint->to_app;
    reset_runtime();
    my $original = scope(path => '/admin', raw_path => '/admin');
    my $events = run_scope($app, $original);

    is(\@Local::MiddlewareEndpoint::order, [
        'request-id enter', 'auth enter', 'object enter', 'session enter',
        'handler', 'session exit', 'object exit', 'auth exit', 'request-id exit',
    ], 'runtime order is an onion with the first item outermost');
    is($Local::MiddlewareEndpoint::downstream_calls, 1,
        'method middleware invokes its native downstream app exactly once');
    is($Local::MiddlewareEndpoint::handler_scopes[0]{endpoint_clone}, 'present',
        'handler receives the scope clone supplied by standard middleware');
    ok(!exists $original->{endpoint_clone}, 'the caller-owned scope was not mutated');
    is([map { $_->{endpoint_send_wrapper} } @$events], [1, 1],
        'the configured object wraps every downstream send event');
    is($events->[0]{status}, 200, 'shared HTTP adapter still emits the response');
    is($events->[1]{body}, 'admin', 'shared HTTP adapter sends the body');
};

subtest 'method middleware can short circuit without response-valued next flow' => sub {
    my $object = Local::ConfiguredMiddleware->new;
    my $app = Local::MiddlewareEndpoint->new(object => $object)->to_app;
    reset_runtime();
    my $events = run_scope($app, scope(path => '/deny', raw_path => '/deny'));
    is(\@Local::MiddlewareEndpoint::order, [
        'request-id enter', 'auth enter', 'auth short circuit', 'auth exit',
        'request-id exit',
    ], 'short circuit skips later middleware and the handler');
    is($Local::MiddlewareEndpoint::downstream_calls, 0, 'downstream was not called');
    is($object->{calls}, 0, 'configured downstream middleware did not run');
    is([map { $_->{type} } @$events],
        ['http.response.start', 'http.response.body'], 'native middleware owns its events');
    is($events->[0]{status}, 403, 'short circuit status reaches the wire');
    is($events->[1]{body}, 'denied', 'short circuit body reaches the wire');
};

subtest 'the same universal middleware contract applies to WebSocket and SSE leaves' => sub {
    my $object = Local::ConfiguredMiddleware->new;
    my $app = Local::MiddlewareEndpoint->new(object => $object)->to_app;
    for my $case (
        [websocket => '/socket', [
            { type => 'websocket.close', code => 1000, reason => 'middleware',
              endpoint_send_wrapper => 1 },
        ]],
        [sse => '/events', [
            { type => 'sse.start', status => 200,
              endpoint_send_wrapper => 1 },
            { type => 'sse.close', endpoint_send_wrapper => 1 },
        ]],
    ) {
        my ($type, $path, $expected) = @$case;
        reset_runtime();
        my $events = run_scope($app, scope(type => $type, path => $path,
            raw_path => $path));
        is(\@Local::MiddlewareEndpoint::order, [
            'request-id enter', 'auth enter', 'object enter', 'session enter',
            'handler', 'session exit', 'object exit', 'auth exit',
            'request-id exit',
        ], "$type uses the same first-listed-outermost order");
        is($events, $expected, "$type send events traverse the same wrapper");
        is($Local::MiddlewareEndpoint::handler_scopes[0]{endpoint_clone}, 'present',
            "$type handler sees the middleware scope clone");
    }
};

subtest 'named Mount middleware and callback handlers share the Endpoint receiver' => sub {
    my $endpoint = bless {}, 'Local::MountMiddlewareEndpoint';
    my $identity = Scalar::Util::refaddr($endpoint);
    @Local::MountMiddlewareEndpoint::order = ();

    my $response = PAGI::Test::Client->new(app => $endpoint->to_app)
        ->get('/nested/leaf');
    is($response->text, 'nested', 'the callback child route dispatches');
    is($endpoint->{factory_receiver}, $identity,
        'middleware_as binds Mount middleware to the Endpoint instance');
    is($endpoint->{handler_receiver}, $identity,
        'the callback child facade binds its handler to the same Endpoint instance');
    is(\@Local::MountMiddlewareEndpoint::order,
        ['mount before', 'leaf', 'mount after'],
        'Mount middleware surrounds the callback child application');
};

done_testing;
