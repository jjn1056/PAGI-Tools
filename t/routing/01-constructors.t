#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future ();
use Scalar::Util qw(refaddr);
use overload ();

use lib 'lib';
use PAGI::Routing qw(:ALL);
use PAGI::Response::Text ();
use PAGI::Utils qw(as_app_object);

{
    package NoImports;
    use PAGI::Routing ();
}

{
    package RouteImports;
    use PAGI::Routing qw(:routes);
}

{
    package MiddlewareImports;
    use PAGI::Routing qw(:middleware);
}

{
    package AllImports;
    use PAGI::Routing qw(:ALL);
}

{
    package TestRoutingApp;
    our $CALLS = 0;
    sub new { bless { app => $_[1] }, $_[0] }
    sub to_app { $CALLS++; return $_[0]->{app} }
}

{
    package Local::MethodEndpoint;
    sub new {
        my ($class, @methods) = @_;
        return bless {
            methods => \@methods,
            calls => 0,
            contexts => [],
        }, $class;
    }
    sub to_app { return sub { } }
    sub allowed_methods {
        my ($self) = @_;
        ++$self->{calls};
        push @{$self->{contexts}},
            !defined wantarray ? 'void' : wantarray ? 'list' : 'scalar';
        return @{$self->{methods}};
    }
    sub calls { return $_[0]{calls} }
    sub contexts { return [@{$_[0]{contexts}}] }
    sub replace_methods { $_[0]{methods} = [@_[1 .. $#_]]; return }
}

{
    package BareListConfiguredObject;
    sub wrap { return $_[1] }
}

{
    package Local::ConfiguredMiddleware;
    sub new { return bless {}, $_[0] }
    sub wrap { return $_[1] }
}

{
    package Local::ProtocolConstraint;
    sub new { return bless { expected => $_[1] }, $_[0] }
    sub check { return $_[1] eq $_[0]{expected} }
    sub get_message { return "expected $_[0]{expected}, got $_[1]" }
}

{
    package Local::FactoryDeclaration;
    use PAGI::Routing qw(router route websocket sse mount);
    use PAGI::Routing::Route ();
    use PAGI::Routing::Mount ();

    our $CALLS = 0;
    sub Owned { $CALLS++; return qr/factory/ }

    sub http { return route('/http/{id:&Owned}' => sub { }) }
    sub native_http {
        return route('/native/{id:&Owned}' => PAGI::Utils::as_app_object(sub { }));
    }
    sub socket { return websocket('/socket/{id:&Owned}' => sub { }) }
    sub events { return sse('/events/{id:&Owned}' => sub { }) }
    sub inline_mount {
        return mount('/inline/{id:&Owned}', routes => []);
    }
    sub router_mount {
        return mount('/known/{id:&Owned}',
            app => router(routes => []), name      => 'known');
    }
    sub opaque_mount {
        return mount('/opaque/{id:&Owned}', app => sub { });
    }
    sub direct_route {
        return PAGI::Routing::Route->new(
            path => '/direct/{id:&Owned}', endpoint => sub { },
        );
    }
    sub direct_mount {
        return PAGI::Routing::Mount->new(
            '/direct-mount/{id:&Owned}', routes => [],
        );
    }
}

{
    package Local::RoutingReexport;
    use Exporter 'import';
    use PAGI::Routing qw(route);
    our @EXPORT_OK;
    BEGIN { @EXPORT_OK = qw(route) }
}

{
    package Local::ReexportConsumer;
    BEGIN { Local::RoutingReexport->import('route') }

    our $CALLS = 0;
    sub Owned { $CALLS++; return qr/consumer/ }
    sub build { return route('/reexport/{id:&Owned}' => sub { }) }
}

{
    package Local::RoutingWrapper;
    use PAGI::Routing qw(route);

    our $CALLS = 0;
    sub Owned { $CALLS++; return qr/wrapper/ }
    sub build { return route('/wrapper/{id:&Owned}' => sub { }) }
}

{
    package Local::WrapperConsumer;
    our $CALLS = 0;
    sub Owned { $CALLS++; return qr/consumer/ }
    sub build { return Local::RoutingWrapper::build() }
}

{
    package Local::RoutingRole;
    use PAGI::Routing qw(route);

    our $CALLS = 0;
    sub Owned { $CALLS++; return qr/role/ }
    sub routing { return route('/role/{id:&Owned}' => sub { }) }
}

{
    package Local::RoleConsumer;
    our $CALLS = 0;
    sub Owned { $CALLS++; return qr/consumer/ }
    BEGIN { *routing = \&Local::RoutingRole::routing }
}

{
    package Local::DescriptorCarrier;
    sub carry { return $_[0] }
}

subtest 'exports are opt-in and tag-specific' => sub {
    for my $name (qw(router route websocket sse mount middleware request_response)) {
        ok(!NoImports->can($name), "no default $name export");
        ok(AllImports->can($name), "ALL exports $name");
    }
    for my $name (qw(router route websocket sse mount)) {
        ok(RouteImports->can($name), "routes tag exports $name");
    }
    ok(!RouteImports->can('middleware'), 'routes tag excludes middleware');
    ok(!RouteImports->can('request_response'),
        'routes tag excludes the request adapter');
    ok(MiddlewareImports->can('middleware'), 'middleware tag exports middleware');
    ok(!MiddlewareImports->can('route'), 'middleware tag excludes route');
    ok(!PAGI::Routing->can('request_app'),
        'the removed request_app spelling remains unavailable');
    ok(defined &request_response,
        'request_response is imported from PAGI::Routing');
    my ($error, $stderr);
    {
        local *STDERR;
        open STDERR, '>', \$stderr or die "cannot capture STDERR: $!";
        $error = dies { eval q{ package BadImports; use PAGI::Routing qw(:all); 1 } or die $@ };
    }
    like $error,
        qr/Can't continue after import errors/, 'lowercase all is rejected';
    like $stderr, qr/"all" is not defined in %PAGI::Routing::EXPORT_TAGS/,
        'lowercase all diagnostic is captured';
};

subtest 'public constructors retain their direct declaration package' => sub {
    $Local::FactoryDeclaration::CALLS = 0;
    my @leaves = (
        [Local::FactoryDeclaration::http(), '/http/factory'],
        [Local::FactoryDeclaration::native_http(), '/native/factory'],
        [Local::FactoryDeclaration::socket(), '/socket/factory'],
        [Local::FactoryDeclaration::events(), '/events/factory'],
        [Local::FactoryDeclaration::direct_route(), '/direct/factory'],
    );
    my @mounts = (
        [Local::FactoryDeclaration::inline_mount(), '/inline/factory/tail'],
        [Local::FactoryDeclaration::router_mount(), '/known/factory/tail'],
        [Local::FactoryDeclaration::opaque_mount(), '/opaque/factory/tail'],
        [Local::FactoryDeclaration::direct_mount(), '/direct-mount/factory/tail'],
    );

    for my $case (@leaves) {
        my ($node, $path) = @$case;
        is($node->_pattern->match_route($path), { id => 'factory' },
            ref($node) . ' resolves &Owned in its direct declaration package');
        ok(!defined $node->_pattern->match_route($path =~ s/factory/other/r),
            ref($node) . ' does not rebind &Owned elsewhere');
    }
    for my $case (@mounts) {
        my ($node, $path) = @$case;
        is($node->_pattern->match_mount($path)->{captures}, { id => 'factory' },
            ref($node) . ' mount resolves &Owned in its direct declaration package');
        ok(!defined $node->_pattern->match_mount($path =~ s/factory/other/r),
            ref($node) . ' mount rejects values outside that package predicate');
    }
    is($Local::FactoryDeclaration::CALLS, 9,
        'each public or direct descriptor constructor invokes its provider once');

    $Local::ReexportConsumer::CALLS = 0;
    my $reexported = Local::ReexportConsumer::build();
    is($reexported->_pattern->match_route('/reexport/consumer'), { id => 'consumer' },
        'an ordinary re-export leaves the consuming package as direct caller');
    is($Local::ReexportConsumer::CALLS, 1,
        'the consumer-owned provider ran once through a re-export');

    $Local::RoutingWrapper::CALLS = 0;
    $Local::WrapperConsumer::CALLS = 0;
    my $wrapped = Local::WrapperConsumer::build();
    is($wrapped->_pattern->match_route('/wrapper/wrapper'), { id => 'wrapper' },
        'a real wrapper becomes the declaration-package boundary');
    ok(!defined $wrapped->_pattern->match_route('/wrapper/consumer'),
        'a wrapper does not search outward for the consumer provider');
    is($Local::RoutingWrapper::CALLS, 1, 'the wrapper provider ran once');
    is($Local::WrapperConsumer::CALLS, 0, 'the wrapper consumer provider never ran');

    $Local::RoutingRole::CALLS = 0;
    $Local::RoleConsumer::CALLS = 0;
    my $role_route = Local::RoleConsumer->routing;
    is($role_route->_pattern->match_route('/role/role'), { id => 'role' },
        'a role-defined call expression keeps the role declaration package');
    ok(!defined $role_route->_pattern->match_route('/role/consumer'),
        'invoking a role method on a class does not rebind its provider');
    is($Local::RoutingRole::CALLS, 1, 'the role provider ran once');
    is($Local::RoleConsumer::CALLS, 0, 'the consuming-class provider never ran');

    my $built = Local::FactoryDeclaration::http();
    my $calls_after_build = $Local::FactoryDeclaration::CALLS;
    my $carried = Local::DescriptorCarrier::carry($built);
    my $routing = router(routes => [$carried]);
    is(refaddr($routing->routes->[0]), refaddr($built),
        'another package and Router preserve the completed descriptor identity');
    is($Local::FactoryDeclaration::CALLS, $calls_after_build,
        'placing an unnamed completed descriptor in a Router does not re-resolve it');
    is($routing->routes->[0]->_pattern->match_route('/http/factory'),
        { id => 'factory' }, 'the placed descriptor retains its source predicate');
};

subtest 'route descriptions preserve endpoint identity and normalize HTTP methods' => sub {
    my $handler = sub { return 'context handler' };
    my $config = { enabled => 1 };
    my $mw = middleware('Example::Trace', level => 2, config => $config);
    my $methods = ['post', 'get', 'GET', 'rpc'];
    my $host_constraint = qr/example[.]test/;
    my $constraints = { host => $host_constraint };
    my $node = route '/things/{host}' => $handler,
        name => 'things', desc => '', methods => $methods,
        constraints => $constraints, middleware => [$mw];

    isa_ok($node, 'PAGI::Routing::Route');
    is($node->kind, 'route', 'HTTP route kind');
    is($node->path, '/things/{host}', 'route path');
    is($node->name, 'things', 'route name');
    is($node->desc, '', 'empty description is retained');
    is(refaddr($node->endpoint), refaddr($handler), 'endpoint identity is retained');
    is($node->methods, ['POST', 'GET', 'HEAD', 'RPC'], 'methods normalize, deduplicate, and add HEAD');
    is(refaddr($node->constraints->{host}), refaddr($host_constraint), 'route constraints retain declared checker');
    is($node->middleware, [$mw], 'route middleware descriptors');

    my $plain_route = route('/plain' => sub { });
    is($plain_route->constraints, {},
        'Route exposes omitted explicit constraints as an empty hash');
    my $plain_route_constraints = $plain_route->constraints;
    $plain_route_constraints->{probe} = qr/mutated/;
    is($plain_route->constraints, {},
        'Route omitted constraints accessor remains a fresh empty hash');

    my $empty_route = route('/empty' => sub { }, constraints => {});
    is($empty_route->constraints, {},
        'Route exposes explicit empty constraints with the same shape');
    my $empty_route_constraints = $empty_route->constraints;
    $empty_route_constraints->{probe} = qr/mutated/;
    is($empty_route->constraints, {},
        'Route explicit empty constraints accessor remains a fresh hash');

    ok(!$node->can('target') && !$node->can('is_raw'),
        'retired target modes have no compatibility accessors');
    ok(!$node->can('namespace'), 'public namespace accessor is removed from Route');
    is($node->routes, undef, 'routes are inapplicable to route');

    $methods->[0] = 'DELETE';
    $constraints->{host} = qr/changed[.]test/;
    my $returned_methods = $node->methods;
    my $returned_constraints = $node->constraints;
    my $returned_middleware = $node->middleware;
    push @$returned_methods, 'DELETE';
    $returned_constraints->{host} = qr/mutated[.]test/;
    push @$returned_middleware, middleware('Another');
    is($node->methods, ['POST', 'GET', 'HEAD', 'RPC'], 'method collections are copied');
    is(refaddr($node->constraints->{host}), refaddr($host_constraint), 'constraint hashes are copied');
    is($node->middleware, [$mw], 'middleware arrays are copied');

    my $wildcard = route '/all' => $handler, methods => '*';
    is($wildcard->methods, '*', 'wildcard method remains scalar');
    is(route('/default' => $handler)->methods, ['GET', 'HEAD'], 'HTTP routes default to GET and HEAD');
};

subtest 'application-valued and protocol-specific route descriptions' => sub {
    my $app = sub { return 'native app' };
    my $native = as_app_object($app);
    my $native_route = route '/native' => $native, desc => 'native app';
    is($native_route->kind, 'route', 'native HTTP route kind');
    is(refaddr($native_route->endpoint), refaddr($native),
        'wrapped native app endpoint identity is retained');
    is($native_route->methods, ['GET', 'HEAD'],
        'native HTTP routes retain safe default methods');

    my $component = TestRoutingApp->new($app);
    $TestRoutingApp::CALLS = 0;
    my $component_route = route '/component' => $component;
    is(refaddr($component_route->endpoint), refaddr($component),
        'component endpoint identity is retained for compiler coercion');
    is($TestRoutingApp::CALLS, 0,
        'component is not compiled at description construction');

    my $ws_regex = qr/ws/;
    my $ws_code = sub { return $_[0] eq 'code' };
    my $ws_object = Local::ProtocolConstraint->new('object');
    my $ws_constraints = {
        regex => $ws_regex,
        code => $ws_code,
        object => $ws_object,
    };
    my $websocket = websocket '/socket/{regex}/{code}/{object}' => sub { },
        constraints => $ws_constraints;
    my $native_websocket_endpoint = as_app_object($app);
    my $native_websocket = websocket '/native-socket' => $native_websocket_endpoint;
    my $sse_regex = qr/sse/;
    my $sse_code = sub { return $_[0] eq 'stream' };
    my $sse_object = Local::ProtocolConstraint->new('event');
    my $sse_constraints = {
        regex => $sse_regex,
        code => $sse_code,
        object => $sse_object,
    };
    my $sse = sse '/events/{regex}/{code}/{object}' => sub { },
        constraints => $sse_constraints;
    my $native_sse_endpoint = as_app_object($app);
    my $native_sse = sse '/native-events' => $native_sse_endpoint;
    is($websocket->kind, 'websocket', 'WebSocket kind');
    is($sse->kind, 'sse', 'SSE kind');
    is(refaddr($native_websocket->endpoint), refaddr($native_websocket_endpoint),
        'WebSocket accepts an application-valued endpoint');
    is(refaddr($native_sse->endpoint), refaddr($native_sse_endpoint),
        'SSE accepts an application-valued endpoint');
    is($websocket->methods, undef, 'WebSocket has no methods');
    is(refaddr($websocket->constraints->{regex}), refaddr($ws_regex),
        'WebSocket retains a declared regex constraint');
    is(refaddr($websocket->constraints->{code}), refaddr($ws_code),
        'WebSocket retains a declared coderef constraint');
    is(refaddr($websocket->constraints->{object}), refaddr($ws_object),
        'WebSocket retains a declared check object');
    is($websocket->_pattern->match_route('/socket/ws/code/object'),
        { regex => 'ws', code => 'code', object => 'object' },
        'WebSocket applies all explicit constraint shapes');
    ok(!defined $websocket->_pattern->match_route('/socket/ws/no/object'),
        'WebSocket rejects a failed explicit constraint');

    is(refaddr($sse->constraints->{regex}), refaddr($sse_regex),
        'SSE retains a declared regex constraint');
    is(refaddr($sse->constraints->{code}), refaddr($sse_code),
        'SSE retains a declared coderef constraint');
    is(refaddr($sse->constraints->{object}), refaddr($sse_object),
        'SSE retains a declared check object');
    is($sse->_pattern->match_route('/events/sse/stream/event'),
        { regex => 'sse', code => 'stream', object => 'event' },
        'SSE applies all explicit constraint shapes');
    ok(!defined $sse->_pattern->match_route('/events/sse/stream/no'),
        'SSE rejects a failed explicit constraint');

    $ws_constraints->{regex} = qr/changed/;
    $sse_constraints->{regex} = qr/changed/;
    my $returned_ws_constraints = $websocket->constraints;
    my $returned_sse_constraints = $sse->constraints;
    $returned_ws_constraints->{code} = sub { 0 };
    $returned_sse_constraints->{code} = sub { 0 };
    is(refaddr($websocket->constraints->{regex}), refaddr($ws_regex),
        'WebSocket copies the input constraint hash');
    is(refaddr($websocket->constraints->{code}), refaddr($ws_code),
        'WebSocket returns a defensive constraint hash');
    is(refaddr($sse->constraints->{regex}), refaddr($sse_regex),
        'SSE copies the input constraint hash');
    is(refaddr($sse->constraints->{code}), refaddr($sse_code),
        'SSE returns a defensive constraint hash');
};

subtest 'object and functional Route constructors share the canonical endpoint model' => sub {
    my $endpoint = sub { return 'handler' };
    my $functional = route('/same' => $endpoint,
        name => 'same', desc => 'Same route', methods => ['post']);
    my $object = PAGI::Routing::Route->new(
        path => '/same', endpoint => $endpoint,
        name => 'same', desc => 'Same route', methods => ['post'],
    );

    for my $accessor (qw(kind path name desc methods)) {
        is($object->$accessor, $functional->$accessor,
            "object and functional constructors agree on $accessor");
    }
    is(refaddr($object->endpoint), refaddr($endpoint),
        'object constructor retains the exact endpoint');
    is($object->kind, 'route', 'object constructor always creates HTTP');
};

subtest 'HTTP methods use explicit, capability, then safe-default precedence' => sub {
    my $capable = Local::MethodEndpoint->new(
        qw(get GET post options POST),
    );
    my $from_capability = route('/capability' => $capable);
    is($from_capability->methods, [qw(GET HEAD POST OPTIONS)],
        'capability methods normalize in first-seen order');
    is($capable->calls, 1, 'capability is consulted exactly once');
    is($capable->contexts, ['list'], 'capability is called in list context');

    $capable->replace_methods(qw(DELETE));
    is($from_capability->methods, [qw(GET HEAD POST OPTIONS)],
        'capability methods are an immutable construction-time snapshot');
    is($capable->calls, 1, 'snapshot access does not consult capability again');

    my $scalar_restriction = Local::MethodEndpoint->new(qw(GET POST OPTIONS));
    is(route('/explicit-scalar' => $scalar_restriction, methods => 'GET')->methods,
        [qw(GET HEAD)], 'a scalar restriction narrows an advertised capability');
    is($scalar_restriction->calls, 1,
        'a finite scalar restriction snapshots the endpoint capability once');

    my $array_restriction = Local::MethodEndpoint->new(qw(GET POST OPTIONS));
    is(route('/explicit-array' => $array_restriction, methods => ['POST'])->methods,
        ['POST'], 'an array restriction narrows an advertised capability');
    is($array_restriction->calls, 1,
        'a finite array restriction snapshots the endpoint capability once');

    my $unsupported_restriction = Local::MethodEndpoint->new(qw(GET POST OPTIONS));
    like dies {
        route('/unsupported-restriction' => $unsupported_restriction,
            methods => ['DELETE'])
    }, qr/methods \[DELETE\] are not advertised by route endpoint allowed_methods/,
        'a finite restriction rejects methods absent from the endpoint capability';
    is($unsupported_restriction->calls, 1,
        'an unsupported restriction still snapshots the endpoint capability once');

    my $unsupported_scalar = Local::MethodEndpoint->new(qw(GET POST OPTIONS));
    like dies {
        route('/unsupported-scalar' => $unsupported_scalar,
            methods => 'DELETE')
    }, qr/methods \[DELETE\] are not advertised by route endpoint allowed_methods/,
        'an unsupported finite scalar rejects methods absent from the endpoint capability';
    is($unsupported_scalar->calls, 1,
        'an unsupported scalar snapshots the endpoint capability once');

    my $wildcard_restriction = Local::MethodEndpoint->new(qw(GET POST OPTIONS));
    is(route('/wildcard-restriction' => $wildcard_restriction, methods => '*')->methods,
        '*', 'a scalar wildcard remains unrestricted');
    is($wildcard_restriction->calls, 0,
        'a scalar wildcard never consults the endpoint capability');

    my $response = PAGI::Response::Text->new('file');
    is(route('/file' => $response)->methods, [qw(GET HEAD)],
        'ordinary app objects use the safe default');
    my $native = as_app_object(sub { });
    is(route('/relay' => $native, methods => '*')->methods, '*',
        'only explicit scalar wildcard enables unrestricted dispatch');

    my $protocol_capable = Local::MethodEndpoint->new(qw(POST));
    is(websocket('/socket' => $protocol_capable)->methods, undef,
        'WebSocket routes have no method set');
    is(sse('/events' => $protocol_capable)->methods, undef,
        'SSE routes have no method set');
    is($protocol_capable->calls, 0,
        'protocol routes never consult allowed_methods');
    like dies {
        websocket('/socket-methods' => $protocol_capable, methods => 'GET')
    }, qr/WebSocket routes do not accept methods/,
        'WebSocket rejects methods before capability resolution';
    like dies {
        sse('/event-methods' => $protocol_capable, methods => 'GET')
    }, qr/SSE routes do not accept methods/,
        'SSE rejects methods before capability resolution';
    is($protocol_capable->calls, 0,
        'rejected protocol method declarations do not leak capability calls');
};

subtest 'Mount retains one base app and Router retains declared HTTP defaults' => sub {
    my $handler = sub { };
    my $leaf = route '/leaf' => $handler;
    my $children = [$leaf];
    my $tenant_constraint = qr/[a-z]+/;
    my $constraints = { tenant => $tenant_constraint };
    my $mount_middleware = middleware('Mount');
    my $mount_middleware_input = [$mount_middleware];
    my $inline = mount '/api/{tenant}', routes => $children,
        name      => 'API', desc => '', constraints => $constraints,
        middleware => $mount_middleware_input;
    isa_ok($inline, 'PAGI::Routing::Mount');
    is($inline->kind, 'mount', 'mount kind');
    is($inline->path, '/api/{tenant}', 'mount path');
    is($inline->name, 'API', 'inline mount exposes its local name');
    ok(!$inline->can('namespace'), 'public namespace accessor is removed from Mount');
    is($inline->desc, '', 'mount empty description');
    isa_ok($inline->app, ['PAGI::Routing::Router'],
        'routes shorthand constructs a child Router application');
    is(refaddr($inline->constraints->{tenant}), refaddr($tenant_constraint), 'mount constraints retain declared checker');

    my $plain_mount = mount('/plain-mount', routes => []);
    is($plain_mount->constraints, {},
        'Mount exposes omitted explicit constraints as an empty hash');
    my $plain_mount_constraints = $plain_mount->constraints;
    $plain_mount_constraints->{probe} = qr/mutated/;
    is($plain_mount->constraints, {},
        'Mount omitted constraints accessor remains a fresh empty hash');

    ok(!$inline->can('target') && !$inline->can('router')
        && !$inline->can('is_raw') && !$inline->can('routes'),
        'removed Mount modes have no compatibility accessors');
    is($inline->methods, undef, 'methods are inapplicable to mount');
    is($inline->middleware, [$mount_middleware], 'mount middleware preserves descriptor');

    push @$children, route '/other' => $handler;
    $constraints->{tenant} = qr/b/;
    push @$mount_middleware_input, middleware('MountInputMutation');
    my $returned_constraints = $inline->constraints;
    my $returned_mount_middleware = $inline->middleware;
    $returned_constraints->{tenant} = qr/c/;
    push @$returned_mount_middleware, middleware('MountResultMutation');
    is($inline->app->routes, [$leaf], 'routes shorthand copies the child route array');
    is(refaddr($inline->constraints->{tenant}), refaddr($tenant_constraint), 'mount constraints are copied');
    is($inline->middleware, [$mount_middleware], 'mount middleware arrays are copied');

    my $app = sub { };
    my $raw = mount '/app', app => $app;
    is(refaddr($raw->app), refaddr($app), 'Mount retains its exact base app');
    my $component = TestRoutingApp->new($app);
    my $component_mount = mount '/component', app => $component;
    is(refaddr($component_mount->app), refaddr($component),
        'Mount retains its exact component application');

    my $child = router(routes => [
        route('/' => sub { }, name => 'index'),
    ]);
    my $known = mount('/known',
        desc      => 'Known child',
        name      => 'known',
        app       => $child,
    );
    is(refaddr($known->app), refaddr($child), 'Router application identity is preserved');
    is($known->name, 'known', 'Router mount exposes its local name');

    my $routes = [$leaf];
    my $router_middleware = middleware('Top');
    my $router_middleware_input = [$router_middleware];
    my $router = router(
        routes => $routes,
        middleware => $router_middleware_input,
        desc => 'Root routes',
    );
    isa_ok($router, 'PAGI::Routing::Router');
    is($router->kind, 'router', 'router kind');
    is($router->name, undef, 'name is inapplicable to router');
    is($router->desc, 'Root routes', 'router description');
    is($router->routes, [$leaf], 'router routes');
    is($router->http_default, undef, 'Router omits an HTTP default by default');
    my $default = sub { };
    my $component_default = TestRoutingApp->new($default);
    local $TestRoutingApp::CALLS = 0;
    my $with_default = router(routes => [], http_default => $default);
    my $with_component_default = router(
        routes => [], http_default => $component_default,
    );
    is(refaddr($with_default->http_default), refaddr($default),
        'Router retains HTTP default coderef identity without compilation');
    is(refaddr($with_component_default->http_default), refaddr($component_default),
        'Router retains HTTP default component identity without compilation');
    is($TestRoutingApp::CALLS, 0,
        'Router construction does not compile its declared HTTP default');
    is($router->middleware, [$router_middleware], 'router middleware preserves descriptor');
    push @$routes, $leaf;
    push @$router_middleware_input, middleware('RouterInputMutation');
    my $returned_router_routes = $router->routes;
    my $returned_router_middleware = $router->middleware;
    push @$returned_router_routes, $leaf;
    push @$returned_router_middleware, middleware('RouterResultMutation');
    is($router->routes, [$leaf], 'router route arrays are copied');
    is($router->middleware, [$router_middleware], 'router middleware arrays are copied');
    is($router->path, undef, 'path is inapplicable to router');
    is($router->methods, undef, 'methods are inapplicable to router');
    is($router->constraints, undef, 'constraints are inapplicable to router');
    ok(!$router->can('target') && !$router->can('is_raw'),
        'retired target modes have no Router compatibility accessors');
    ok(!$router->can('namespace'), 'public namespace accessor is removed from Router');
    ok(!$router->can('not_found'), 'Router has no not-found callback accessor');
    ok(!$router->can('method_not_allowed'),
        'Router has no method-not-allowed callback accessor');
};

subtest 'middleware descriptions preserve targets and copy descriptor config' => sub {
    my $factory = sub { };
    my $factory_options = { retry => 1 };
    my $factory_node = middleware($factory, options => $factory_options);
    isa_ok($factory_node, 'PAGI::Routing::Middleware');
    is(refaddr($factory_node->factory), refaddr($factory), 'factory identity is retained');
    is($factory_node->config, { options => $factory_options },
        'factory descriptor config is retained');

    my $options = { retry => 1 };
    my $node = middleware('Configured', options => $options);
    isa_ok($node, 'PAGI::Routing::Middleware');
    is($node->factory, 'Configured', 'class target is retained');
    is($node->config, { options => $options }, 'middleware config');
    $options->{retry} = 2;
    my $returned = $node->config;
    $returned->{new} = 1;
    is($node->config, { options => { retry => 2 } }, 'config hash is copied shallowly on access');
    ok(!$node->can('to_app'), 'middleware descriptors are not application nodes');
};

subtest 'descriptions have no coderef overload and defer compilation' => sub {
    for my $node (
        router(routes => []),
        route('/' => sub { }),
        mount('/app', app => sub { }),
    ) {
        ok(!overload::Method($node, '&{}'), ref($node) . ' has no coderef overload');
        ok($node->can('to_app'), ref($node) . ' has to_app boundary');
    }
};

subtest 'every routing middleware position requires explicit descriptions' => sub {
    my $handler = sub { };
    my @constructors = (
        ['HTTP route', sub { route('/http' => $handler, middleware => $_[0]) }],
        ['WebSocket route', sub { websocket('/socket' => $handler, middleware => $_[0]) }],
        ['SSE route', sub { sse('/events' => $handler, middleware => $_[0]) }],
        ['app Mount', sub { mount('/opaque', app => sub { }, middleware => $_[0]) }],
        ['routes Mount', sub { mount('/inline', routes => [], middleware => $_[0]) }],
        ['Router', sub { router(routes => [], middleware => $_[0]) }],
    );
    my @bare = (
        ['class name', 'RequestId'],
        ['factory', sub { return $_[0] }],
        ['configured object', Local::ConfiguredMiddleware->new],
        ['hashref', {}],
    );

    for my $constructor (@constructors) {
        my ($constructor_label, $construct) = @$constructor;
        for my $bare (@bare) {
            my ($entry_label, $entry) = @$bare;
            like dies { $construct->([$entry]) }, qr/middleware entry 0 must be a PAGI::Routing::Middleware description returned by middleware\(\.\.\.\)/,
                "$constructor_label rejects bare $entry_label middleware";
        }
    }
};

subtest 'every routing middleware position preserves explicit descriptor identity and copies' => sub {
    my $handler = sub { };
    my $first = middleware('RequestId');
    my $second = middleware(sub { return $_[0] });
    my $input = [$first, $second];
    my @nodes = (
        route('/http' => $handler, middleware => $input),
        websocket('/socket' => $handler, middleware => $input),
        sse('/events' => $handler, middleware => $input),
        mount('/opaque', app => sub { }, middleware => $input),
        mount('/inline', routes => [], middleware => $input),
        router(routes => [], middleware => $input),
    );

    push @$input, middleware('InputMutation');
    for my $node (@nodes) {
        my $stored = $node->middleware;
        is([map { refaddr $_ } @$stored], [refaddr($first), refaddr($second)],
            ref($node) . ' retains explicit descriptor identity and order');
        push @$stored, middleware('AccessorMutation');
        is([map { refaddr $_ } @{$node->middleware}], [refaddr($first), refaddr($second)],
            ref($node) . ' accessor returns an independent array');
    }
};

subtest 'constructors reject invalid declarations' => sub {
    my $handler = sub { };
    my $child_router = router(routes => []);
    like dies { route '/missing' }, qr/route requires an endpoint/,
        'functional route requires an endpoint';
    like dies { PAGI::Routing::Route->new(path => '/missing') },
        qr/route requires an endpoint/,
        'object Route constructor requires an endpoint';
    like dies { PAGI::Routing::Route->new(endpoint => $handler) },
        qr/route requires a path/,
        'object Route constructor requires a path';
    like dies { route '/odd' => $handler, 'desc' },
        qr/route option list must be key\/value pairs/,
        'functional route rejects an odd option tail';
    like dies {
        PAGI::Routing::Route->new(path => '/odd', endpoint => $handler, 'desc')
    }, qr/route option list must be key\/value pairs/,
        'object Route constructor rejects an odd option list';
    like dies { route '/duplicate' => $handler, name => 'a', name => 'b' },
        qr/duplicate route option 'name'/,
        'functional route rejects duplicate options before hash construction';
    like dies {
        PAGI::Routing::Route->new(
            path => '/first', endpoint => $handler, path => '/second',
        )
    }, qr/duplicate route option 'path'/,
        'object Route constructor rejects duplicate structural options';
    like dies {
        PAGI::Routing::Route->new(
            path => '/duplicate-endpoint',
            endpoint => $handler, endpoint => $handler,
        )
    }, qr/duplicate route option 'endpoint'/,
        'object Route constructor rejects duplicate endpoints';
    like dies { route '/legacy' => $handler, raw => $handler },
        qr/unknown route option 'raw'/,
        'raw is not parsed as a legacy endpoint mode';
    like dies { route '/unknown' => $handler, nope => 1 }, qr/unknown route option/, 'route rejects unknown option';
    like dies {
        PAGI::Routing::Route->new(
            path => '/unknown', endpoint => $handler, kind => 'sse',
        )
    }, qr/unknown route option 'kind'/,
        'object Route constructor cannot select another protocol kind';
    like dies { route '/bad-methods' => $handler, methods => {} }, qr/methods must be a method string, arrayref, or '\*'/, 'methods require supported shape';
    like dies { route '/empty-methods' => $handler, methods => [] }, qr/methods must be a method string, arrayref, or '\*'/, 'methods may not be empty';
    like dies { route '/array-wildcard' => $handler, methods => ['*'] },
        qr/methods must be a method string, arrayref, or '\*'/,
        'array wildcard is rejected';
    like dies { route '/mixed-wildcard' => $handler, methods => ['GET', '*'] },
        qr/methods must be a method string, arrayref, or '\*'/,
        'mixed wildcard list is rejected';
    like dies { route '/separator' => $handler, methods => 'GET POST' }, qr/methods must be a method string, arrayref, or '\*'/, 'methods reject separators';
    like dies { websocket '/socket' => $handler, methods => 'GET' }, qr/WebSocket routes do not accept methods/, 'WebSocket rejects methods';
    like dies { sse '/events' => $handler, methods => 'GET' }, qr/SSE routes do not accept methods/, 'SSE rejects methods';
    like dies { route '/not-code' => 'not a handler' }, qr/route endpoint must be a native coderef or app object/, 'route rejects package strings';
    like dies { route '/not-component' => [] }, qr/route endpoint must be a native coderef or app object/, 'route rejects unblessed component lookalikes';
    ok(lives { route '/component' => PAGI::Response::Text->new('component') },
        'normal route accepts an app object');
    my $broken_component = bless {}, 'BrokenRouteComponent';
    like dies { route '/broken-component' => $broken_component },
        qr/route endpoint must be a native coderef or app object/,
        'route rejects an instantiated object without to_app';
    for my $case (
        [empty     => [],                 qr/route endpoint allowed_methods returned no methods/],
        [separator => ['GET POST'],       qr/route endpoint allowed_methods must return valid HTTP method strings/],
        [reference => [{}],               qr/route endpoint allowed_methods must return valid HTTP method strings/],
        [future    => [Future->done('GET')], qr/route endpoint allowed_methods must return valid HTTP method strings/],
        [wildcard  => ['*'],              qr/route endpoint allowed_methods must return valid HTTP method strings/],
        [mixed     => ['GET', '*'],        qr/route endpoint allowed_methods must return valid HTTP method strings/],
    ) {
        my ($label, $returned, $error) = @$case;
        my $endpoint = Local::MethodEndpoint->new(@$returned);
        like dies { route "/invalid-capability-$label" => $endpoint },
            $error,
            "$label allowed_methods failure names the endpoint capability";
    }
    for my $case (
        [empty     => [],                   qr/route endpoint allowed_methods returned no methods/],
        [separator => ['GET POST'],         qr/route endpoint allowed_methods must return valid HTTP method strings/],
        [reference => [{}],                 qr/route endpoint allowed_methods must return valid HTTP method strings/],
        [future    => [Future->done('GET')], qr/route endpoint allowed_methods must return valid HTTP method strings/],
        [wildcard  => ['*'],                qr/route endpoint allowed_methods must return valid HTTP method strings/],
        [mixed     => ['GET', '*'],         qr/route endpoint allowed_methods must return valid HTTP method strings/],
    ) {
        my ($label, $returned, $error) = @$case;
        my $endpoint = Local::MethodEndpoint->new(@$returned);
        like dies {
            route "/invalid-restricted-capability-$label" => $endpoint,
                methods => 'GET'
        }, $error,
            "$label allowed_methods failure is preserved through a finite restriction";
        is $endpoint->calls, 1,
            "$label finite restriction consults allowed_methods exactly once";
    }
    like dies { mount '/missing' }, qr/mount requires exactly one of app or routes/, 'mount requires one target form';
    like dies { mount '/both', app => $handler, routes => [] }, qr/mount requires exactly one of app or routes/, 'mount rejects app plus routes';
    like dies { mount '/positional' => $handler }, qr/mount option list must be key\/value pairs/, 'mount rejects positional targets';
    like dies { mount '/router', router => $child_router }, qr/unknown mount option 'router'/, 'mount rejects legacy router option';
    for my $key (qw(methods schema lifespan fallback)) {
        like dies { mount '/removed-option', routes => [], $key => sub { } },
            qr/unknown mount option '\Q$key\E'/,
            "mount rejects removed '$key' option";
    }
    like dies { mount '/undefined-app', app => undef }, qr/mount app must be a native coderef or app object/, 'mount validates app through the strict app validator';
    like dies { mount '/bad-app', app => [] }, qr/mount app must be a native coderef or app object/, 'mount rejects non-app values';
    ok(lives { mount '/valid-name', app => $handler, name => 'x' },
        'named application mounts are accepted');
    like dies { mount('/old-namespace', routes => [], namespace => 'old') }, qr/unknown mount option 'namespace'/, 'legacy namespace option is rejected';
    like dies { mount('/malformed-named', routes => [], 'desc') }, qr/mount option list must be key\/value pairs/, 'malformed named tail is diagnosed before hash construction';
    like dies { mount '/bad-routes', routes => 'nope' }, qr/routes must contain PAGI::Routing nodes/, 'mount routes must be an arrayref';
    like dies { mount '/bad-node', routes => [bless {}, 'Elsewhere'] }, qr/routes must contain PAGI::Routing nodes/, 'mount routes contain only nodes';
    like dies { router(routes => 'nope') }, qr/routes must contain PAGI::Routing nodes/, 'router routes must be an arrayref';
    like dies { mount '/nested-router', routes => [$child_router] },
        qr/mount\('\/prefix', app => \$router\)/,
        'inline mount routes reject a nested Router with application-mount guidance';
    like dies { router(routes => [$child_router]) },
        qr/mount\('\/prefix', app => \$router\)/,
        'router route lists reject a nested Router rather than accepting an inert node';
    for my $removed (qw(default not_found method_not_allowed)) {
        like dies { router($removed => sub { }) },
            qr/unknown router option '\Q$removed\E'/,
            "removed Router option '$removed' is rejected without compatibility";
    }
    for my $invalid (
        [undef, qr/router http_default must be a native coderef or app object/],
        [[], qr/router http_default must be a native coderef or app object/],
        [bless({}, 'RouterDefaultWithoutToApp'), qr/router http_default must be a native coderef or app object/],
    ) {
        my ($value, $pattern) = @$invalid;
        like dies { router(routes => [], http_default => $value) }, $pattern,
            'Router validates its declared HTTP default synchronously';
    }
    like dies { route '/bad-middleware' => $handler, middleware => 'nope' }, qr/middleware must be an arrayref/, 'middleware must be an arrayref';
    my $not_middleware = bless {}, 'NotMiddlewareObject';
    for my $invalid ([], {}, $not_middleware) {
        like dies {
            route '/invalid-middleware' => $handler,
                middleware => [$invalid]
        }, qr/middleware entry 0 must be a PAGI::Routing::Middleware description returned by middleware\(\.\.\.\)/,
            'direct middleware entries require an explicit description';
    }
    like dies { middleware([]) }, qr/middleware requires a coderef, blessed object, or nonempty class name/, 'middleware rejects an unblessed arrayref';
    like dies { middleware({}) }, qr/middleware requires a coderef, blessed object, or nonempty class name/, 'middleware rejects an unblessed hashref';
    like dies { middleware('') }, qr/middleware requires a coderef, blessed object, or nonempty class name/, 'middleware rejects an empty class name';
    like dies { route '/bad-desc' => $handler, desc => {} }, qr/desc must be a string/, 'descriptions cannot be references';
    for my $valid (qw(show v1.1)) {
        is(route('/valid-name' => $handler, name => $valid)->name, $valid, "route name '$valid' is one logical segment");
        is(mount('/valid-name', routes => [], name => $valid)->name, $valid, "mount name '$valid' is one logical segment");
    }
    for my $invalid ('/', '.', '..', 'person/show', '', []) {
        like dies { route '/bad-name' => $handler, name => $invalid }, qr/name must be one logical address segment/, 'route names require one logical segment';
        like dies { mount '/bad-name', routes => [], name => $invalid }, qr/name must be one logical address segment/, 'mount names require one logical segment';
    }
    is(route('/desc-slash' => $handler, desc => '/')->desc, '/', 'route descriptions retain ordinary text validation');
    is(mount('/desc-dot', routes => [], desc => 'person/show')->desc, 'person/show', 'mount descriptions retain ordinary text validation');
    like dies { request_response('not a handler') },
        qr/request_response handler must be a coderef/,
        'Routing request_response validates its handler at construction';
};

done_testing;
