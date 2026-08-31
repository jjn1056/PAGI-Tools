#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::App::Router ();
use PAGI::App::Router::Builder ();
use PAGI::Response::Text ();
use PAGI::Routing::Middleware ();
use PAGI::Test::Client ();
use PAGI::Utils qw(as_app);

{
    package Local::StringifiedOption;
    use overload '""' => sub { return 'methods' }, fallback => 1;
}

{
    package Local::BuilderApp;

    sub new { return bless { builds => 0 }, $_[0] }
    sub to_app {
        my ($self) = @_;
        ++$self->{builds};
        return sub { return };
    }
}

{
    package Local::MethodEndpoint;

    sub new { return bless { allowed_calls => 0, builds => 0 }, $_[0] }
    sub allowed_methods { ++$_[0]{allowed_calls}; return qw(GET POST OPTIONS) }
    sub to_app {
        ++$_[0]{builds};
        return sub { return };
    }
}

subtest 'constructor copies and normalizes router configuration' => sub {
    my $factory = sub { return $_[0] };
    my $middleware = [$factory];
    my $default = Local::BuilderApp->new;

    my $builder = PAGI::App::Router::Builder->new(
        desc       => 'root routes',
        middleware => $middleware,
        http_default => $default,
    );

    my $options = $builder->_router_options;
    is($options->{desc}, 'root routes', 'stores the top-level description');
    ok(!exists $options->{not_found},
        'materialized Router options have no not-found callback key');
    ok(!exists $options->{method_not_allowed},
        'materialized Router options have no method-not-allowed callback key');
    ok($options->{middleware}[0]->isa('PAGI::Routing::Middleware'),
        'normalizes top-level middleware immediately');
    is(refaddr($options->{http_default}), refaddr($default),
        'retains the original HTTP default application');
    ok($options->{has_http_default}, 'records that HTTP default was configured');
    is($default->{builds}, 0, 'constructor configuration performs no compilation');
    is(refaddr($builder->to_router->http_default), refaddr($default),
        'the configured application reaches the immutable Router unchanged');
    is($default->{builds}, 0, 'materialization performs no application compilation');
    like(dies { $builder->http_default(sub { }) },
        qr/http_default.*only.*once|already configured/i,
        'constructor and method forms share one-shot configuration');

    my $method_default = Local::BuilderApp->new;
    my $method_builder = PAGI::App::Router::Builder->new;
    is($method_builder->http_default($method_default), $method_builder,
        'the method form returns its builder');
    is(refaddr($method_builder->to_router->http_default), refaddr($method_default),
        'the method form propagates the original application');
    like(dies { $method_builder->http_default($default) },
        qr/http_default.*only.*once|already configured/i,
        'a second method configuration croaks');

    push @$middleware, sub { return $_[0] };
    push @{$options->{middleware}}, PAGI::Routing::Middleware->new(sub { return $_[0] });
    is(scalar @{$builder->_router_options->{middleware}}, 1,
        'top-level middleware lists are defensive');

    like dies { PAGI::App::Router::Builder->new('desc') },
        qr/router option list must be key\/value pairs/,
        'odd router options are rejected';
    like dies { PAGI::App::Router::Builder->new(unknown => 1) },
        qr/unknown router option 'unknown'/,
        'unknown router options are rejected';
    like dies {
        PAGI::App::Router::Builder->new(
            http_default => $default,
            http_default => $method_default,
        );
    }, qr/duplicate router option 'http_default'/,
        'duplicate constructor options are rejected before hash construction';
    like dies { PAGI::App::Router::Builder->new(desc => []) },
        qr/desc must be a string/,
        'invalid descriptions are rejected';
    for my $class (qw(PAGI::App::Router::Builder PAGI::App::Router)) {
        my $instance = $class->new;
        ok(!$instance->can('not_found'), "$class has no not-found accessor");
        ok(!$instance->can('method_not_allowed'),
            "$class has no method-not-allowed accessor");
        for my $removed (qw(not_found method_not_allowed)) {
            like dies { $class->new($removed => sub { }) },
                qr/unknown router option '\Q$removed\E'/,
                "$class rejects removed option '$removed'";
        }
    }
};

subtest 'all leaf declarations retain one exact ordered record sequence' => sub {
    my $builder = PAGI::App::Router::Builder->new;
    my $handler = sub { return 'context result' };
    my $native = as_app(sub { return 'native result' });
    my $factory = sub { return $_[0] };
    my $methods = ['RPC'];

    $builder->get('/get' => $handler);
    $builder->post('/post' => $handler);
    $builder->put('/put' => $handler);
    $builder->patch('/patch' => $handler);
    $builder->delete('/delete' => $handler);
    $builder->head('/head' => $handler);
    $builder->options('/options' => $handler);
    $builder->any('/any' => $handler);
    $builder->route('/rpc' => $handler, methods => $methods);
    $builder->websocket('/socket' => $handler);
    $builder->sse('/events' => $handler);
    $builder->get('/native' => $native);
    $builder->get('/wrapped' => [$factory] => $handler);

    my $records = $builder->_declarations;
    is(
        [map { [$_->{node_kind}, $_->{methods}, $_->{path}] } @$records],
        [
            ['route',     ['GET'],     '/get'],
            ['route',     ['POST'],    '/post'],
            ['route',     ['PUT'],     '/put'],
            ['route',     ['PATCH'],   '/patch'],
            ['route',     ['DELETE'],  '/delete'],
            ['route',     ['HEAD'],    '/head'],
            ['route',     ['OPTIONS'], '/options'],
            ['route',     '*',         '/any'],
            ['route',     ['RPC'],     '/rpc'],
            ['websocket', undef, '/socket'],
            ['sse', undef, '/events'],
            ['route',     ['GET'], '/native'],
            ['route',     ['GET'], '/wrapped'],
        ],
        'all declarations preserve one exact insertion order across protocols',
    );
    is(refaddr($records->[11]{endpoint}), refaddr($native),
        'explicitly wrapped native application identity is retained');
    ok($records->[12]{middleware}[0]->isa('PAGI::Routing::Middleware'),
        'positional middleware is normalized at declaration time');

    $methods->[0] = 'CHANGED';
    $records->[0]{methods}[0] = 'CHANGED';
    push @{$records->[12]{middleware}}, PAGI::Routing::Middleware->new($factory);
    is($builder->_declarations->[8]{methods}, ['RPC'], 'method lists are defensive');
    is(scalar @{$builder->_declarations->[12]{middleware}}, 1,
        'record middleware lists are defensive');
};

subtest 'leaf grammar accepts application values and requires explicit native wrapping' => sub {
    my $builder = PAGI::App::Router::Builder->new;
    my $handler = sub { };
    my $native = as_app(sub { });
    my $factory = sub { return $_[0] };
    my $raw_object = Local::BuilderApp->new;

    $builder->get('/normal' => $handler);
    $builder->get('/wrapped' => [$factory] => $handler);
    $builder->get('/native' => $native);
    $builder->get('/native-wrapped' => [$factory], $native);
    $builder->get('/object', $raw_object);
    $builder->route('/rpc' => $handler, methods => ['RPC']);

    like dies { $builder->get('/missing') }, qr/requires a target/,
        'a declaration requires one target';
    like dies { $builder->get('/extra' => $handler => 'extra') },
        qr/option list must be key\/value pairs|requires exactly one target/,
        'extra positional values are rejected';
    like dies { $builder->get('/odd' => $handler, method => 'GET') },
        qr/unknown route option 'method'/,
        'unrecognized named tails are rejected';
    like dies { $builder->websocket('/socket' => $handler, methods => ['GET']) },
        qr/WebSocket routes do not accept methods/,
        'WebSocket declarations reject methods';
    like dies { $builder->sse('/events' => $handler, methods => ['GET']) },
        qr/SSE routes do not accept methods/,
        'SSE declarations reject methods';
    like dies { $builder->get('/normal' => 'native') },
        qr/route endpoint must be a coderef or instantiated object with to_app/,
        'package strings are not application values';
    like(dies { $builder->get('/package', 'Local::BuilderApp') },
        qr/route endpoint must be a coderef or instantiated object with to_app/,
        'application package strings are rejected through the shared app validator');
    is($raw_object->{builds}, 0,
        'application objects are retained without compilation at declaration');
    like dies { $builder->get('/bad-middleware' => [undef] => $handler) },
        qr/middleware entry 0 must be/,
        'invalid positional middleware entries are rejected';
    like dies {
        $builder->route('/stringified' => $handler,
            bless({}, 'Local::StringifiedOption') => ['GET']);
    }, qr/route option names must be strings/,
        'stringified reference option keys are rejected before hash construction';
    like dies {
        $builder->route('/duplicate-methods' => $handler,
            methods => ['GET'], methods => ['POST']);
    }, qr/duplicate route option 'methods'/,
        'duplicate route options are rejected before hash construction';
};

subtest 'last declaration modifiers update only the latest compatible route' => sub {
    my $builder = PAGI::App::Router::Builder->new;
    my $handler = sub { };
    my $constraints = { id => qr/\d+/ };

    is($builder->get('/one/{id}' => $handler), $builder, 'route declarations return the builder');
    is($builder->name('one')->desc('first')->constraints(%$constraints), $builder,
        'all modifiers return the builder');
    $constraints->{id} = qr/[a-z]+/;
    $builder->post('/two' => $handler);

    my $records = $builder->_declarations;
    is($records->[0]{name}, 'one', 'name updates the preceding route');
    is($records->[0]{desc}, 'first', 'description updates the preceding route');
    my $node = $builder->_materialize_nodes(undef)->[0];
    is($node->_pattern->match_route('/one/42'), { id => '42' },
        'materialized constraints accept the originally declared value');
    is($node->_pattern->match_route('/one/abc'), undef,
        'materialized constraints reject values outside the original declaration');
    is($records->[1]{name}, undef, 'later declarations do not inherit a name');
    is($records->[1]{desc}, undef, 'later declarations do not inherit a description');
    is($records->[1]{constraints}, undef, 'later declarations do not inherit constraints');

    my $empty = PAGI::App::Router::Builder->new;
    like dies { $empty->name('missing') },
        qr/name called without a preceding compatible declaration/,
        'name requires a preceding compatible declaration';
    like dies { $empty->desc('missing') },
        qr/desc called without a preceding compatible declaration/,
        'desc requires a preceding compatible declaration';
    like dies { $empty->constraints(id => qr/.+/) },
        qr/constraints called without a preceding compatible declaration/,
        'constraints requires a preceding compatible declaration';
    like dies { $builder->name('with/slash') }, qr/name must be one logical address segment/,
        'name uses shared logical segment validation';
    like dies { $builder->desc([]) }, qr/desc must be a string/,
        'description uses shared text validation';
    like dies { $builder->constraints('id') }, qr/constraints option list must be key\/value pairs/,
        'constraints require key/value pairs';
    like dies {
        $builder->constraints(id => qr/\d+/, id => qr/[a-z]+/);
    }, qr/duplicate constraints option 'id'/,
        'duplicate constraint options are rejected before hash construction';
};

subtest 'materialization defers immutable HTTP normalization to Route' => sub {
    my $builder = PAGI::App::Router::Builder->new;
    my $handler = sub { };

    $builder->get('/get' => $handler);
    $builder->route('/rpc' => $handler, methods => ['RPC']);
    $builder->route('/generic-any' => $handler, methods => '*');
    $builder->any('/any' => $handler);
    $builder->websocket('/socket' => $handler);
    $builder->sse('/events' => $handler);

    my $nodes = $builder->_materialize_nodes(undef);
    is([map { [$_->kind, $_->methods, $_->path] } @$nodes], [
        ['route', ['GET', 'HEAD'], '/get'],
        ['route', ['RPC'], '/rpc'],
        ['route', '*', '/generic-any'],
        ['route', '*', '/any'],
        ['websocket', undef, '/socket'],
        ['sse', undef, '/events'],
    ], 'immutable Route owns method normalization, including automatic HEAD');
};

subtest 'materialization preserves explicit generic methods presence' => sub {
    my $builder = PAGI::App::Router::Builder->new;

    $builder->route('/undefined' => sub { }, methods => undef);

    like dies { $builder->_materialize_nodes(undef) },
        qr/methods must be a method string, arrayref, or '\*'/,
        'explicit undef reaches immutable Route validation';
};

subtest 'generic application objects default through immutable Route construction' => sub {
    my $builder = PAGI::App::Router::Builder->new;
    my $endpoint = Local::BuilderApp->new;
    my $error = dies { $builder->route('/default' => $endpoint) };

    is($error, undef,
        'a generic application object does not require explicit methods');
    return if defined $error;

    my $route = $builder->to_router->routes->[0];
    is($route->endpoint, $endpoint,
        'the immutable Route retains the exact endpoint object');
    is($route->methods, ['GET', 'HEAD'],
        'the immutable Route supplies GET plus automatic HEAD');
    is($endpoint->{builds}, 0,
        'method fallback does not compile the endpoint application');
};

subtest 'generic CODE handlers default through immutable Route construction' => sub {
    my $builder = PAGI::App::Router::Builder->new;
    my $handler = sub {
        return PAGI::Response::Text->new('generic handler default');
    };
    my $error = dies { $builder->route('/default' => $handler) };

    is($error, undef,
        'a generic CODE handler does not require explicit methods');
    return if defined $error;

    my $route = $builder->to_router->routes->[0];
    is($route->endpoint, $handler,
        'the immutable Route retains the exact handler CODE');
    is($route->methods, ['GET', 'HEAD'],
        'the immutable Route supplies GET plus automatic HEAD');

    my $client = PAGI::Test::Client->new(app => $builder->to_app);
    is($client->get('/default')->text, 'generic handler default',
        'GET dispatches through the generic handler');
    my $partial = $client->post('/default');
    is($partial->status, 405, 'Router owns the unsupported-method outcome');
    is($partial->header('allow'), 'GET, HEAD',
        'Router publishes the fallback method set in Allow');
};

subtest 'application capability is snapshotted once per immutable Route construction' => sub {
    my $builder = PAGI::App::Router::Builder->new;
    my $endpoint = Local::MethodEndpoint->new;
    $builder->route('/inferred' => $endpoint);

    is($endpoint->{allowed_calls}, 0,
        'mutable declaration does not query endpoint capabilities');

    my $first = $builder->to_router->routes->[0];
    is($first->endpoint, $endpoint,
        'the immutable Route retains the exact endpoint object');
    is($first->methods, ['GET', 'HEAD', 'POST', 'OPTIONS'],
        'the first immutable Route receives one normalized capability snapshot');
    is($endpoint->{allowed_calls}, 1,
        'the first immutable Route construction queries the capability once');

    my $second = $builder->to_router->routes->[0];
    is($second->methods, ['GET', 'HEAD', 'POST', 'OPTIONS'],
        'a later immutable snapshot retains the same normalized capability');
    is($endpoint->{allowed_calls}, 2,
        'each fresh immutable Route construction takes one fresh snapshot');
    is($endpoint->{builds}, 0,
        'method inference does not compile the endpoint application');
};

subtest 'explicit generic methods bypass endpoint capability inference' => sub {
    my $builder = PAGI::App::Router::Builder->new;
    my $endpoint = Local::MethodEndpoint->new;
    $builder->route('/explicit' => $endpoint, methods => ['PATCH']);

    my $route = $builder->to_router->routes->[0];
    is($route->methods, ['PATCH'], 'explicit methods reach the immutable Route');
    is($endpoint->{allowed_calls}, 0,
        'explicit methods do not query the endpoint capability');
};

done_testing;
