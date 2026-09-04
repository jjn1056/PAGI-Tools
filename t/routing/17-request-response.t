use strict;
use warnings;

use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);
use PAGI::Routing qw(request_response);
use PAGI::Routing::RequestResponse;

{
    package Local::CompanyRequest;
    use parent 'PAGI::Request';

    sub company_name { 'Example Corp' }
}

{
    package Local::ReturnedApp;
    our $TO_APP_CALLS = 0;
    sub new { bless { app => $_[1] }, $_[0] }
    sub to_app {
        ++$TO_APP_CALLS;
        return $_[0]->{app};
    }
}

sub scope {
    return { type => 'http', path => $_[0] // '/' };
}

sub quiet_receive {
    return sub { Future->done({ type => 'http.disconnect' }) };
}

sub recorder {
    my @events;
    return (sub { push @events, $_[0]; return Future->done }, \@events);
}

subtest 'constructor and routing factory create the public RequestResponse app object' => sub {
    my $handler = sub { return sub { return } };

    my $from_constructor = PAGI::Routing::RequestResponse->new(
        handler => $handler,
    );
    my $from_factory = request_response($handler);

    is(ref($from_constructor), 'PAGI::Routing::RequestResponse',
        'constructor returns the exact public app-object class');
    is(ref($from_factory), 'PAGI::Routing::RequestResponse',
        'routing factory returns the exact public app-object class');
    ref_ok($from_constructor->to_app, 'CODE', 'app object compiles to native CODE');
};

subtest 'request_factory supplies a Request subclass from the exact request boundary' => sub {
    my (@factory_calls, @handler_requests, @app_calls);
    my $factory = sub {
        my ($scope, $receive) = @_;
        push @factory_calls, [@_];
        return Local::CompanyRequest->new($scope, $receive);
    };
    my $component = request_response(
        sub {
            my ($request) = @_;
            push @handler_requests, $request;
            return sub {
                push @app_calls, [@_];
                return 'custom request complete';
            };
        },
        request_factory => $factory,
    );
    my $app = $component->to_app;
    my $scope = scope('/company');
    my $receive = quiet_receive();
    my ($send) = recorder();

    is($app->($scope, $receive, $send)->get, 'custom request complete',
        'handler result remains the invoked application');
    is(scalar @factory_calls, 1, 'request factory runs exactly once');
    is($factory_calls[0], [$scope, $receive],
        'request factory receives exactly the original scope and receive');
    is(scalar @handler_requests, 1, 'handler runs exactly once');
    isa_ok($handler_requests[0], ['Local::CompanyRequest'],
        'handler receives the custom Request subclass');
    is($handler_requests[0]->company_name, 'Example Corp',
        'custom Request behavior is available to the handler');
    is($app_calls[0], [$scope, $receive, $send],
        'returned application retains the exact original triplet');
};

subtest 'constructor and routing factory require exactly one handler CODE' => sub {
    like(dies { PAGI::Routing::RequestResponse->new },
        qr/request_response handler must be a coderef/,
        'constructor rejects a missing handler');
    like(dies { PAGI::Routing::RequestResponse->new(handler => 'no') },
        qr/request_response handler must be a coderef/,
        'constructor rejects a scalar handler');
    like(dies { request_response() },
        qr/request_response handler must be a coderef/,
        'routing factory rejects a missing handler');
    like(dies { request_response(sub { }, 'extra') },
        qr{request_response option list must be key/value pairs},
        'routing factory rejects an odd option list');
    like(dies {
        PAGI::Routing::RequestResponse->new(
            handler => sub { }, request_factory => 'not code',
        );
    }, qr/request_response request_factory must be a coderef/,
        'constructor rejects a non-coderef request factory');
    like(dies { request_response(sub { }, unknown => sub { }) },
        qr/unknown request_response option 'unknown'/,
        'routing factory rejects an unknown option');
};

subtest 'request_factory must return a Request instance or subclass' => sub {
    my $handler_called = 0;
    my $app = request_response(
        sub {
            ++$handler_called;
            return sub { return };
        },
        request_factory => sub { return bless {}, 'Local::NotARequest' },
    )->to_app;

    like(dies {
        $app->(scope('/invalid-factory'), quiet_receive(), sub { Future->done })->get;
    }, qr/request_response request_factory must return a PAGI::Request instance or subclass/,
        'invalid request object gets the factory-boundary diagnostic');
    is($handler_called, 0, 'handler does not run with an invalid request object');
};

subtest 'non-HTTP scope is rejected before the handler runs' => sub {
    my $called = 0;
    my $app = request_response(sub {
        ++$called;
        return sub { return };
    })->to_app;

    like(dies { $app->({ type => 'websocket' }, quiet_receive(), sub { Future->done })->get },
        qr/requires HTTP scope/,
        'non-HTTP scope is rejected');
    is($called, 0, 'handler did not run for the rejected scope');
};

subtest 'immediate handler result receives one Request and preserves the triplet' => sub {
    my ($request, $arguments, $call_context, $app_arguments);
    my $handler = sub {
        $arguments = [@_];
        $call_context = defined wantarray
            ? (wantarray ? 'list' : 'scalar') : 'void';
        ($request) = @_;
        return sub {
            $app_arguments = [@_];
            return 'complete';
        };
    };
    my $app = request_response($handler)->to_app;
    my $scope = scope('/original');
    my $receive = quiet_receive();
    my ($send) = recorder();

    is($app->($scope, $receive, $send)->get, 'complete',
        'immediate native application completion is returned');
    is(scalar @$arguments, 1, 'handler receives exactly one argument');
    is($call_context, 'scalar', 'handler is invoked in scalar context');
    isa_ok($request, ['PAGI::Request'], 'handler receives a Request');
    is(refaddr($request->raw), refaddr($scope), 'Request retains original scope');
    is($app_arguments, [$scope, $receive, $send],
        'returned native app receives the exact original triplet');
};

subtest 'Future-backed handler result remains pending and then invokes its app' => sub {
    my $returned = Future->new;
    my $called = 0;
    my $app = request_response(sub { return $returned })->to_app;
    my $running = $app->(scope('/future'), quiet_receive(), sub { Future->done });

    ok(!$running->is_ready, 'handler Future keeps invocation pending');
    $returned->done(sub { ++$called; return 'later' });
    is($running->get, 'later', 'resolved handler result is invoked and awaited');
    is($called, 1, 'resolved native app is invoked once');
};

subtest 'returned object compiles once for each request and is never cached' => sub {
    $Local::ReturnedApp::TO_APP_CALLS = 0;
    my $invocations = 0;
    my $object = Local::ReturnedApp->new(sub { ++$invocations; return });
    my $app = request_response(sub { return $object })->to_app;

    $app->(scope('/one'), quiet_receive(), sub { Future->done })->get;
    $app->(scope('/two'), quiet_receive(), sub { Future->done })->get;

    is($Local::ReturnedApp::TO_APP_CALLS, 2,
        'returned object is compiled once per handler invocation');
    is($invocations, 2, 'each compiled app is invoked once');
};

subtest 'invalid and undefined handler results fail before application invocation' => sub {
    my $started = 0;
    for my $case (
        ['undefined', undef],
        ['invalid scalar', 'not an application'],
    ) {
        my ($label, $value) = @$case;
        my $app = request_response(sub { return $value })->to_app;
        like(dies { $app->(scope("/$label"), quiet_receive(), sub { ++$started; Future->done })->get },
            qr/request handler must return a PAGI application: a native coderef or app object/,
            "$label result gets the Request handler diagnostic");
    }
    is($started, 0, 'invalid values never start an application response');
};

subtest 'concurrent invocations retain their own request and original triplet' => sub {
    my (@requests, @returned);
    my $app = request_response(sub {
        my ($request) = @_;
        push @requests, $request;
        my $gate = Future->new;
        push @returned, $gate;
        return $gate;
    })->to_app;
    my $first_scope = scope('/first');
    my $second_scope = scope('/second');
    my $first_receive = quiet_receive();
    my $second_receive = quiet_receive();
    my ($first_send) = recorder();
    my ($second_send) = recorder();

    my $first = $app->($first_scope, $first_receive, $first_send);
    my $second = $app->($second_scope, $second_receive, $second_send);

    is(scalar @requests, 2, 'both handlers begin before either return app resolves');
    isnt(refaddr($requests[0]), refaddr($requests[1]), 'each invocation has a distinct Request');
    is([refaddr($requests[0]->raw), refaddr($requests[1]->raw)],
        [refaddr($first_scope), refaddr($second_scope)],
        'each Request retained its own scope');
    $returned[1]->done(sub {
        is([@_], [$second_scope, $second_receive, $second_send],
            'second app retains its original triplet');
        return;
    });
    $returned[0]->done(sub {
        is([@_], [$first_scope, $first_receive, $first_send],
            'first app retains its original triplet');
        return;
    });
    $second->get;
    $first->get;
};

subtest 'a returned application observes only receive events remaining after handler body consumption' => sub {
    my @events = (
        { type => 'http.request', body => 'first', more => 1 },
        { type => 'http.request', body => 'second', more => 0 },
    );
    my $receive = sub { Future->done(shift @events) };
    my @seen;
    my $app = request_response(async sub {
        my ($request) = @_;
        my $stream = $request->body_stream;
        push @seen, await $stream->next_chunk;
        return async sub {
            my ($scope, $returned_receive) = @_;
            my $event = await $returned_receive->();
            push @seen, $event->{body};
            return;
        };
    })->to_app;

    $app->(scope('/body'), $receive, sub { Future->done })->get;

    is(\@seen, ['first', 'second'],
        'returned app receives the advanced original receive channel');
};

done_testing;
