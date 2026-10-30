use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use FindBin;
use lib 'lib', "$FindBin::Bin/../lib";
use PAGI::Test::Client;
use PAGI::Tools qw(compose middleware mount response route router sse websocket);
use PAGI::Auth qw(unauth_result);
use PAGI::Utils ();
use PAGI::Utils::Middleware qw(clone_scope);
use PAGI::Middleware::RequestClass;

# PAGI::Middleware::RequestClass: every handler below it receives the
# application's Request class, through the scope key pagi.request.factory.

{ package Local::AppRequest;   use parent 'PAGI::Request'; }
{ package Local::OtherRequest; use parent 'PAGI::Request'; }
{ package Local::OnlyTag;      sub tag { return 'x' } }
{ package Local::WithNew;      sub new { return bless {}, shift } }

{
    package Local::ClassEndpoint;
    use parent 'PAGI::Endpoint::HTTP';
    use PAGI::Response::Text ();

    sub get {
        my ($self, $request) = @_;
        return PAGI::Response::Text->new(ref $request);
    }
}

# Compiling this read puts a symbol in the package's stash before its file
# is loaded: RequestClass must still require it.
sub never_reads { no warnings 'once'; return $PAGITest::RequestClass::Mentioned::DEBUG }

# A route handler that answers with the class of the Request it received.
my $class_of = sub { my ($request) = @_; return response('Text', ref $request) };

sub with_class {
    my ($class, %compose) = @_;
    return compose(
        middleware => [middleware('RequestClass', class => $class)],
        routes     => [route('/' => $class_of)],
        %compose,
    );
}

sub get_text {
    my ($app, $path) = @_;
    return PAGI::Test::Client->new(app => $app)->get($path // '/')->text;
}

subtest 'construction checks its options' => sub {
    like(dies { PAGI::Middleware::RequestClass->new },
        qr/\ARequestClass requires class at /, 'class is required');
    like(dies { PAGI::Middleware::RequestClass->new(class => 'Local::AppRequest', bogus => 1) },
        qr/RequestClass has unknown option 'bogus'/, 'an unknown option dies');
    for my $bad (undef, '', 'Not A Package', '1Leading::Digit', 'Trailing::', ['Local::AppRequest']) {
        like(dies { PAGI::Middleware::RequestClass->new(class => $bad) },
            qr/\ARequestClass class must be a package name at /,
            'not a package name: ' . (defined $bad ? (ref $bad || "'$bad'") : 'undef'));
    }
};

subtest 'an inline class with no file is used as it is' => sub {
    is(get_text(with_class('Local::AppRequest')), 'Local::AppRequest', 'the handler gets it');
    is(get_text(with_class('PAGI::Request')), 'PAGI::Request', 'PAGI::Request itself is allowed');
};

subtest 'an inline package that is not a PAGI::Request dies at build, not as unloadable' => sub {
    for my $class (qw(Local::OnlyTag Local::WithNew)) {
        my $app = with_class($class);
        like(dies { $app->to_app }, qr/\ARequestClass \Q$class\E is not a PAGI::Request at /, $class);
    }
};

subtest 'a file-backed class is required at build' => sub {
    ok(!exists $INC{'PAGITest/RequestClass/FileRequest.pm'}, 'not loaded yet');
    is(get_text(with_class('PAGITest::RequestClass::FileRequest')),
        'PAGITest::RequestClass::FileRequest', 'required, and the handler gets it');

    require PAGITest::RequestClass::Nested::Part;
    is(get_text(with_class('PAGITest::RequestClass::Nested')),
        'PAGITest::RequestClass::Nested', 'a stash holding only a nested package is still required');

    my $app = with_class('PAGITest::RequestClass::NotRequest');
    like(dies { $app->to_app },
        qr/\ARequestClass PAGITest::RequestClass::NotRequest is not a PAGI::Request at /,
        'a file-backed class that is not a Request is loaded, then refused');
    ok(exists $INC{'PAGITest/RequestClass/NotRequest.pm'}, 'it was loaded');
};

subtest 'a file-backed class is required even if compiled code named one of its symbols' => sub {
    is(get_text(with_class('PAGITest::RequestClass::Mentioned')),
        'PAGITest::RequestClass::Mentioned', 'required, and the handler gets it');
};

subtest 'a class that is neither defined nor loadable dies when the application is built' => sub {
    my $app;
    ok(lives { $app = with_class('Local::NoSuchRequest') }, 'compose() itself does not build middleware');
    like(dies { $app->to_app },
        qr/\ARequestClass: cannot load Local::NoSuchRequest: Can't locate Local\/NoSuchRequest\.pm/,
        'to_app does');
    $app = with_class('PAGI::Response');
    like(dies { $app->to_app }, qr/\ARequestClass PAGI::Response is not a PAGI::Request at /,
        'a loaded class that is not a Request');
};

subtest 'HTTP, WebSocket and SSE scopes get the key on a copy; others pass through' => sub {
    my @seen;
    my $app = PAGI::Middleware::RequestClass->new(class => 'Local::AppRequest')->wrap(sub {
        my ($scope) = @_;
        push @seen, $scope;
        return Future->done;
    });
    my $receive = sub { Future->done({ type => 'http.disconnect' }) };
    for my $type (qw(http websocket sse)) {
        my $outer = { type => $type, headers => [] };
        $app->($outer, $receive, sub { Future->done })->get;
        my $inner = pop @seen;
        ok($inner != $outer, "$type: a copy");
        ok(!exists $outer->{'pagi.request.factory'}, "$type: the outer scope is unchanged");
        is(ref(PAGI::Utils::request_for_scope($inner, $receive)), 'Local::AppRequest',
            "$type: the key builds the class");
    }
    my $lifespan = { type => 'lifespan' };
    $app->($lifespan, $receive, sub { Future->done })->get;
    ok(pop(@seen) == $lifespan, 'lifespan: the same hashref');
    ok(!exists $lifespan->{'pagi.request.factory'}, 'lifespan: no key');
};

subtest 'request_for_scope without a receive keeps the class' => sub {
    my $inner;
    my $app = PAGI::Middleware::RequestClass->new(class => 'Local::AppRequest')->wrap(sub {
        ($inner) = @_;
        return Future->done;
    });
    $app->({ type => 'http', path => '/', headers => [['x-a', '1']] },
        sub { Future->done({ type => 'http.disconnect' }) }, sub { Future->done })->get;
    my $request = PAGI::Utils::request_for_scope($inner);
    is(ref $request, 'Local::AppRequest', "RequestClass's factory (written with \@_)");
    is($request->header('x-a'), '1', 'it reads the scope');
    like(dies { $request->body->get }, qr/built from the scope alone; it has no body/,
        'and has no body');

    my $signature_factory = do {
        use feature 'signatures';
        no warnings 'experimental::signatures';
        sub ($scope, $receive) { Local::OtherRequest->new($scope, $receive) };
    };
    is(ref(PAGI::Utils::request_for_scope(
            { type => 'http', path => '/', headers => [], 'pagi.request.factory' => $signature_factory })),
        'Local::OtherRequest', 'a factory written with a signature gets ($scope, undef)');
};

subtest 'mounts, http_default and a route of its own' => sub {
    my $native = async sub {
        my ($scope, $receive, $send) = @_;
        my $request = PAGI::Utils::request_for_scope($scope, $receive);
        await response('Text', ref $request)->to_app->($scope, $receive, $send);
    };
    my $client = PAGI::Test::Client->new(app => compose(
        middleware   => [middleware('RequestClass', class => 'Local::AppRequest')],
        routes       => [
            mount('/m', routes => [route('/x' => $class_of)]),
            mount('/r', app => router(routes => [route('/x' => $class_of)])),
            mount('/n', app => $native),
            route('/e' => Local::ClassEndpoint->new),
        ],
        http_default => $class_of,
    ));
    is($client->get('/m/x')->text, 'Local::AppRequest', 'a route inside mount(routes => ...)');
    is($client->get('/r/x')->text, 'Local::AppRequest', 'a mounted Router');
    is($client->get('/n/x')->text, 'Local::AppRequest', 'a mounted native application reads the key');
    is($client->get('/e')->text, 'Local::AppRequest', 'an Endpoint::HTTP method');
    is($client->get('/elsewhere')->text, 'Local::AppRequest', 'http_default');

    $client = PAGI::Test::Client->new(app => compose(routes => [
        route('/a' => $class_of, middleware => [middleware('RequestClass', class => 'Local::AppRequest')]),
        route('/b' => $class_of),
    ]));
    is($client->get('/a')->text, 'Local::AppRequest', "a Route's own middleware list");
    is($client->get('/b')->text, 'PAGI::Request', 'its sibling stays plain');
};

subtest 'a HEAD request reaches a GET route with the class' => sub {
    my $seen;
    my $client = PAGI::Test::Client->new(app => compose(
        middleware => [middleware('RequestClass', class => 'Local::AppRequest')],
        routes     => [route('/' => sub { my ($request) = @_; $seen = ref $request; return response('Text', 'ok') },
            methods => 'GET')],
    ));
    my $res = $client->head('/');
    is([$res->status, $res->text, $seen], [200, '', 'Local::AppRequest'],
        'the GET handler answers HEAD with the class');
};

subtest 'an inner layer resets or replaces the class' => sub {
    my $reset = middleware(sub {
        my ($app) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            await $app->(clone_scope($scope, { 'pagi.request.factory' => undef }), $receive, $send);
        };
    });
    my $client = PAGI::Test::Client->new(app => compose(
        middleware => [middleware('RequestClass', class => 'Local::AppRequest')],
        routes     => [
            route('/plain' => $class_of, middleware => [$reset]),
            route('/other' => $class_of, middleware => [middleware('RequestClass', class => 'Local::OtherRequest')]),
            route('/mine'  => $class_of),
        ],
    ));
    is($client->get('/plain')->text, 'PAGI::Request', 'an undef key below gives PAGI::Request');
    is($client->get('/other')->text, 'Local::OtherRequest', 'an inner RequestClass wins');
    is($client->get('/mine')->text, 'Local::AppRequest', 'the outer class elsewhere');
};

subtest 'refuse, deny and decline handlers get the class' => sub {
    my $client = PAGI::Test::Client->new(app => compose(
        middleware => [
            middleware('RequestClass', class => 'Local::AppRequest'),
            middleware('TrustedHosts', hosts => ['example.com'], refuse => sub {
                my ($request) = @_;
                return response('Text', ref $request, status => 400);
            }),
        ],
        routes => [route('/' => $class_of)],
    ));
    my $res = $client->get('/');
    is([$res->status, $res->text], [400, 'Local::AppRequest'], 'a TrustedHosts refuse handler');

    my $refusal = sub {
        my ($request) = @_;
        return response('Text', ref $request, status => 503);
    };
    $client = PAGI::Test::Client->new(app => compose(
        middleware => [middleware('RequestClass', class => 'Local::AppRequest')],
        routes     => [
            websocket('/ws' => sub { my ($ws) = @_; return $ws->deny($refusal) }),
            sse('/events' => sub { my ($sse) = @_; return $sse->decline($refusal) }),
        ],
    ));
    my $socket = $client->websocket('/ws');
    ok($socket->refused, 'the socket is denied');
    is([$socket->response->status, $socket->response->text], [503, 'Local::AppRequest'],
        'a WebSocket deny handler');
    $res = $client->sse('/events');
    is([$res->status, $res->text], [503, 'Local::AppRequest'], 'an SSE decline handler');
};

subtest "in Compose, handler is outside the application middleware: a plain Request; a route-level catch entry gets the class" => sub {
    my $seen;
    my $handler = sub { my ($request) = @_; $seen = ref $request; return response('Text', 'handled', status => 500) };
    for my $case (
        ['after',  'PAGI::Request', [middleware('RequestClass', class => 'Local::AppRequest'), middleware('ErrorHandler', handler => $handler)]],
        ['before', 'PAGI::Request', [middleware('ErrorHandler', handler => $handler), middleware('RequestClass', class => 'Local::AppRequest')]],
    ) {
        my ($label, $expected, $middleware) = @$case;
        my $client = PAGI::Test::Client->new(app => compose(
            middleware => $middleware,
            routes     => [route('/' => sub { die "boom\n" })],
        ));
        my $res;
        is(warnings { $res = $client->get('/') }, [match(qr/\Aexception after response completed: boom/)],
            "$label: the re-raised error is reported");
        is([$res->status, $res->text, $seen], [500, 'handled', $expected], "$label: $expected");
    }
    my $client = PAGI::Test::Client->new(app => compose(
        middleware => [middleware('RequestClass', class => 'Local::AppRequest'),
            middleware('ErrorHandler', catch => { 'Local::RouteFailure' => sub {
                my ($request) = @_; $seen = ref $request; return response('Text', 'caught', status => 409) } })],
        routes => [route('/' => sub { die bless {}, 'Local::RouteFailure' })],
    ));
    is([$client->get('/')->status, $seen], [409, 'Local::AppRequest'], "a catch entry at the route gets the route's class");
};

subtest 'an Authentication backend gets the class only when listed after RequestClass' => sub {
    my $seen;
    my $backend = sub { my ($request) = @_; $seen = ref $request; return unauth_result() };
    for my $case (
        ['after',  'Local::AppRequest', [middleware('RequestClass', class => 'Local::AppRequest'), middleware('Authentication', backend => $backend)]],
        ['before', 'PAGI::Request',     [middleware('Authentication', backend => $backend), middleware('RequestClass', class => 'Local::AppRequest')]],
    ) {
        my ($label, $expected, $middleware) = @$case;
        my $res = PAGI::Test::Client->new(app => compose(
            middleware => $middleware,
            routes     => [route('/' => $class_of)],
        ))->get('/');
        is([$res->status, $res->text, $seen], [200, 'Local::AppRequest', $expected], "$label: $expected");
    }
};

subtest 'a hand-written middleware sets the same key' => sub {
    my $wrapper = middleware(sub {
        my ($app) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            await $app->(clone_scope($scope, {
                'pagi.request.factory' => sub { return Local::AppRequest->new(@_) },
            }), $receive, $send);
        };
    });
    my $client = PAGI::Test::Client->new(app => compose(
        middleware => [$wrapper],
        routes     => [route('/' => $class_of), mount('/m', routes => [route('/x' => $class_of)])],
    ));
    is($client->get('/')->text, 'Local::AppRequest', 'a route');
    is($client->get('/m/x')->text, 'Local::AppRequest', 'a mounted route');
};

subtest 'a key that is not a coderef is a 500 at request time' => sub {
    my $bad = middleware(sub {
        my ($app) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            await $app->(clone_scope($scope, { 'pagi.request.factory' => 'Local::AppRequest' }), $receive, $send);
        };
    });
    my $app = compose(
        middleware => [$bad],
        routes     => [route('/r' => $class_of), route('/e' => Local::ClassEndpoint->new)],
    );
    ok(lives { $app->to_app }, 'the application builds');
    my $client = PAGI::Test::Client->new(app => $app);
    for my $path ('/r', '/e') {
        my $res;
        is(warnings { $res = $client->get($path) },
            [match(qr/\Aexception after response completed: scope key 'pagi\.request\.factory' must be a coderef at /)],
            "$path: the error is reported");
        is($res->status, 500, "$path: answered 500");
    }
};

done_testing;
