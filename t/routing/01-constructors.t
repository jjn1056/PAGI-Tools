#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(refaddr);
use overload ();

use lib 'lib';
use PAGI::Routing qw(:ALL);

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
    sub new { bless { app => $_[1] }, $_[0] }
    sub to_app { $_[0]->{app} }
}

{
    package BareListConfiguredObject;
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
    sub raw_http { return route('/raw/{id:&Owned}', raw => sub { }) }
    sub socket { return websocket('/socket/{id:&Owned}' => sub { }) }
    sub events { return sse('/events/{id:&Owned}' => sub { }) }
    sub inline_mount {
        return mount('/inline/{id:&Owned}', routes => []);
    }
    sub router_mount {
        return mount('/known/{id:&Owned}',
            router => router(routes => []), name      => 'known');
    }
    sub opaque_mount {
        return mount('/opaque/{id:&Owned}' => sub { });
    }
    sub direct_route {
        return PAGI::Routing::Route->new(
            'route', '/direct/{id:&Owned}' => sub { },
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
    for my $name (qw(router route websocket sse mount middleware)) {
        ok(!NoImports->can($name), "no default $name export");
        ok(AllImports->can($name), "ALL exports $name");
    }
    for my $name (qw(router route websocket sse mount)) {
        ok(RouteImports->can($name), "routes tag exports $name");
    }
    ok(!RouteImports->can('middleware'), 'routes tag excludes middleware');
    ok(MiddlewareImports->can('middleware'), 'middleware tag exports middleware');
    ok(!MiddlewareImports->can('route'), 'middleware tag excludes route');
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
        [Local::FactoryDeclaration::raw_http(), '/raw/factory'],
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

subtest 'route descriptions preserve target identity and normalize HTTP methods' => sub {
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
    is(refaddr($node->target), refaddr($handler), 'handler identity is retained');
    is($node->methods, ['POST', 'GET', 'HEAD', 'RPC'], 'methods normalize, deduplicate, and add HEAD');
    is(refaddr($node->constraints->{host}), refaddr($host_constraint), 'route constraints retain declared checker');
    is($node->middleware, [$mw], 'route middleware descriptors');
    ok(!$node->is_raw, 'normal route is not raw');
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

subtest 'raw and protocol-specific route descriptions' => sub {
    my $app = sub { return 'raw app' };
    my $raw = route '/raw', raw => $app, desc => 'raw app';
    is($raw->kind, 'route', 'raw HTTP route kind');
    ok($raw->is_raw, 'raw route is marked raw');
    is(refaddr($raw->target), refaddr($app), 'raw app target identity is retained');
    is($raw->methods, ['GET', 'HEAD'], 'raw HTTP routes retain default methods');

    my $component = TestRoutingApp->new($app);
    my $raw_component = route '/component', raw => $component;
    is(refaddr($raw_component->target), refaddr($component), 'raw component identity is retained for compiler coercion');

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
    my $raw_websocket = websocket '/raw-socket', raw => $app;
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
    my $raw_sse = sse '/raw-events', raw => $app;
    is($websocket->kind, 'websocket', 'WebSocket kind');
    is($sse->kind, 'sse', 'SSE kind');
    ok(!$websocket->is_raw, 'normal WebSocket route is not raw');
    ok($raw_websocket->is_raw, 'raw WebSocket route is raw');
    ok(!$sse->is_raw, 'normal SSE route is not raw');
    ok($raw_sse->is_raw, 'raw SSE route is raw');
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

subtest 'mount and router descriptions copy their collections' => sub {
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
    is($inline->routes, [$leaf], 'inline mount routes');
    is(refaddr($inline->constraints->{tenant}), refaddr($tenant_constraint), 'mount constraints retain declared checker');
    ok(!$inline->is_raw, 'inline mount is not raw');
    is($inline->target, undef, 'inline mount has no target');
    is($inline->methods, undef, 'methods are inapplicable to mount');
    is($inline->middleware, [$mount_middleware], 'mount middleware preserves descriptor');

    push @$children, route '/other' => $handler;
    $constraints->{tenant} = qr/b/;
    push @$mount_middleware_input, middleware('MountInputMutation');
    my $returned_routes = $inline->routes;
    my $returned_constraints = $inline->constraints;
    my $returned_mount_middleware = $inline->middleware;
    push @$returned_routes, route '/third' => $handler;
    $returned_constraints->{tenant} = qr/c/;
    push @$returned_mount_middleware, middleware('MountResultMutation');
    is($inline->routes, [$leaf], 'mount route arrays are copied');
    is(refaddr($inline->constraints->{tenant}), refaddr($tenant_constraint), 'mount constraints are copied');
    is($inline->middleware, [$mount_middleware], 'mount middleware arrays are copied');

    my $app = sub { };
    my $raw = mount '/app' => $app;
    ok($raw->is_raw, 'application mount is raw');
    is(refaddr($raw->target), refaddr($app), 'mount target preserves app identity');
    is($raw->routes, undef, 'application mount has no inline routes');
    my $component_mount = mount '/component' => TestRoutingApp->new($app);
    ok($component_mount->target->isa('TestRoutingApp'), 'application mount preserves component target for compiler coercion');

    my $child = router(routes => [
        route('/' => sub { }, name => 'index'),
    ]);
    my $known = mount('/known',
        desc      => 'Known child',
        name      => 'known',
        router    => $child,
    );
    is(refaddr($known->router), refaddr($child), 'Router target is preserved');
    is($known->target, undef, 'Router mount has no opaque target');
    is($known->routes, undef, 'Router mount has no inline routes');
    is($known->name, 'known', 'Router mount exposes its local name');
    ok(!$known->is_raw, 'Router mount is inspectable');

    my $routes_first = mount('/routes-first',
        routes => [$leaf], desc => 'Routes first', name      => 'first',
    );
    my $routes_middle = mount('/routes-middle',
        desc => 'Routes middle', routes => [$leaf], name      => 'middle',
    );
    my $routes_last = mount('/routes-last',
        desc => 'Routes last', name      => 'last', routes => [$leaf],
    );
    is($routes_first->routes, [$leaf], 'inline routes selector may come first');
    is($routes_middle->routes, [$leaf], 'inline routes selector may come between options');
    is($routes_last->routes, [$leaf], 'inline routes selector may come last');

    my $router_first = mount('/router-first',
        router => $child, desc => 'Router first', name      => 'router-first',
    );
    my $router_middle = mount('/router-middle',
        desc => 'Router middle', router => $child, name      => 'router-middle',
    );
    my $router_last = mount('/router-last',
        desc => 'Router last', name      => 'router-last', router => $child,
    );
    is(refaddr($router_first->router), refaddr($child), 'Router selector may come first');
    is(refaddr($router_middle->router), refaddr($child), 'Router selector may come between options');
    is(refaddr($router_last->router), refaddr($child), 'Router selector may come last');

    my $routes = [$inline, $raw];
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
    is($router->routes, [$inline, $raw], 'router routes');
    is($router->middleware, [$router_middleware], 'router middleware preserves descriptor');
    push @$routes, $leaf;
    push @$router_middleware_input, middleware('RouterInputMutation');
    my $returned_router_routes = $router->routes;
    my $returned_router_middleware = $router->middleware;
    push @$returned_router_routes, $leaf;
    push @$returned_router_middleware, middleware('RouterResultMutation');
    is($router->routes, [$inline, $raw], 'router route arrays are copied');
    is($router->middleware, [$router_middleware], 'router middleware arrays are copied');
    is($router->path, undef, 'path is inapplicable to router');
    is($router->target, undef, 'target is inapplicable to router');
    is($router->is_raw, undef, 'raw status is inapplicable to router');
    is($router->methods, undef, 'methods are inapplicable to router');
    is($router->constraints, undef, 'constraints are inapplicable to router');
    ok(!$router->can('namespace'), 'public namespace accessor is removed from Router');
    ok(!$router->can('not_found'), 'Router has no not-found callback accessor');
    ok(!$router->can('method_not_allowed'),
        'Router has no method-not-allowed callback accessor');
};

subtest 'middleware descriptions preserve targets and copy class config' => sub {
    my $factory = sub { };
    my $factory_node = middleware($factory);
    isa_ok($factory_node, 'PAGI::Routing::Middleware');
    is(refaddr($factory_node->factory), refaddr($factory), 'factory identity is retained');
    is($factory_node->config, {}, 'a closure-configured factory has no descriptor config');

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
        mount('/app' => sub { }),
    ) {
        ok(!overload::Method($node, '&{}'), ref($node) . ' has no coderef overload');
        ok($node->can('to_app'), ref($node) . ' has to_app boundary');
    }
};

subtest 'every routing middleware position normalizes bare factories' => sub {
    my $handler = sub { };
    my $factory = sub { return $_[0] };
    my $explicit = middleware('Configured', enabled => 1);
    my $input = [$factory, $explicit, $factory];

    my @nodes = (
        route('/http' => $handler, middleware => $input),
        websocket('/socket' => $handler, middleware => [$factory]),
        sse('/events' => $handler, middleware => [$factory]),
        mount('/opaque' => sub { }, middleware => [$factory]),
        mount('/inline', routes => [], middleware => [$factory]),
        router(routes => [], middleware => [$factory]),
    );

    for my $node (@nodes) {
        isa_ok($node->middleware->[0], 'PAGI::Routing::Middleware');
        is(refaddr($node->middleware->[0]->factory), refaddr($factory),
            ref($node) . ' retains bare factory identity');
    }

    my $route_middleware = $nodes[0]->middleware;
    is(refaddr($route_middleware->[1]), refaddr($explicit),
        'mixed explicit description is preserved by identity');
    isnt(refaddr($route_middleware->[0]), refaddr($route_middleware->[2]),
        'repeated bare route entries receive distinct descriptions');
    is(
        [map {
            ref($_->factory) eq 'CODE' ? 'bare' : $_->factory
        } @$route_middleware],
        ['bare', 'Configured', 'bare'],
        'mixed list preserves declaration order',
    );

    push @$input, middleware('InputMutation');
    is(scalar @{$nodes[0]->middleware}, 3, 'constructor copied mixed input');
    push @{$nodes[0]->middleware}, middleware('AccessorMutation');
    is(scalar @{$nodes[0]->middleware}, 3, 'accessor returns a fresh array');
};

subtest 'constructors reject invalid declarations' => sub {
    my $handler = sub { };
    my $child_router = router(routes => []);
    like dies { route '/missing' }, qr/route requires exactly one of handler or raw/, 'route requires a target';
    like dies { route '/both' => $handler, raw => $handler }, qr/route requires exactly one of handler or raw/, 'route rejects handler plus raw';
    like dies { route '/unknown' => $handler, nope => 1 }, qr/unknown route option/, 'route rejects unknown option';
    like dies { route '/bad-methods' => $handler, methods => {} }, qr/methods must be a method string, arrayref, or '\*'/, 'methods require supported shape';
    like dies { route '/empty-methods' => $handler, methods => [] }, qr/methods must be a method string, arrayref, or '\*'/, 'methods may not be empty';
    like dies { route '/separator' => $handler, methods => 'GET POST' }, qr/methods must be a method string, arrayref, or '\*'/, 'methods reject separators';
    like dies { websocket '/socket' => $handler, methods => 'GET' }, qr/WebSocket routes do not accept methods/, 'WebSocket rejects methods';
    like dies { sse '/events' => $handler, methods => 'GET' }, qr/SSE routes do not accept methods/, 'SSE rejects methods';
    like dies { route '/not-code' => 'not a handler' }, qr/handler must be a coderef/, 'normal route handler must be a coderef';
    like dies { route '/not-component' => TestRoutingApp->new($handler) }, qr/handler must be a coderef/, 'normal route does not coerce component targets';
    like dies { mount '/missing' }, qr/mount requires exactly one of target, routes, or router/, 'mount requires one selector';
    like dies { mount '/both' => $handler, routes => [] }, qr/mount requires exactly one of target, routes, or router/, 'mount rejects target plus routes';
    like dies { mount '/target-router' => $handler, router => $child_router, name      => 'child' }, qr/mount requires exactly one of target, routes, or router/, 'mount rejects target plus router';
    like dies { mount '/routes-router', routes => [], router => $child_router, name      => 'child' }, qr/mount requires exactly one of target, routes, or router/, 'mount rejects routes plus router';
    like dies { mount '/all' => $handler, routes => [], router => $child_router, name      => 'child' }, qr/mount requires exactly one of target, routes, or router/, 'mount rejects all selectors';
    like dies { mount '/undefined-target', undef }, qr/mount requires exactly one of target, routes, or router/, 'mount rejects an undefined target';
    like dies { mount '/undefined-mixed', undef, routes => [] }, qr/mount requires exactly one of target, routes, or router/, 'mount rejects undefined target plus routes';
    like dies { mount '/unblessed-router', router => [], name      => 'bad' }, qr/router mount target must be a PAGI::Routing::Router/, 'router selector rejects an unblessed target';
    like dies { mount '/bad-router', router => TestRoutingApp->new($handler), name      => 'bad' }, qr/router mount target must be a PAGI::Routing::Router/, 'router selector rejects a non-Router object';
    like dies { mount('/x', router => $child_router) }, qr/router mount requires a name/, 'router selector requires a name';
    like dies { mount('/x' => $handler, name => 'x') }, qr/opaque application mounts do not accept name/, 'opaque mount rejects name';
    like dies { mount('/old-namespace', routes => [], namespace => 'old') }, qr/unknown mount option 'namespace'/, 'legacy namespace option is rejected';
    like dies { mount('/malformed-pos-code', $handler, 'desc') }, qr/mount option list must be key\/value pairs/, 'malformed positional coderef tail is diagnosed before hash construction';
    like dies { mount('/malformed-pos-object', TestRoutingApp->new($handler), 'desc') }, qr/mount option list must be key\/value pairs/, 'malformed positional object tail is diagnosed before hash construction';
    like dies { mount('/malformed-named', routes => [], 'desc') }, qr/mount option list must be key\/value pairs/, 'malformed named tail is diagnosed before hash construction';
    like dies { mount '/bad-routes', routes => 'nope' }, qr/routes must contain PAGI::Routing nodes/, 'mount routes must be an arrayref';
    like dies { mount '/bad-node', routes => [bless {}, 'Elsewhere'] }, qr/routes must contain PAGI::Routing nodes/, 'mount routes contain only nodes';
    like dies { router(routes => 'nope') }, qr/routes must contain PAGI::Routing nodes/, 'router routes must be an arrayref';
    like dies { mount '/nested-router', routes => [$child_router] },
        qr/mount\('\/prefix', router => \$router, name => '\.\.\.'\)/,
        'inline mount routes reject a nested Router with application-mount guidance';
    like dies { router(routes => [$child_router]) },
        qr/mount\('\/prefix', router => \$router, name => '\.\.\.'\)/,
        'router route lists reject a nested Router rather than accepting an inert node';
    my $opaque_router = mount('/opaque' => $child_router);
    is(refaddr($opaque_router->target), refaddr($child_router), 'positional Router remains an opaque application target');
    is($opaque_router->router, undef, 'positional Router is not the explicit Router form');
    ok($opaque_router->is_raw, 'positional Router remains raw');
    for my $removed (qw(not_found method_not_allowed)) {
        like dies { router($removed => sub { }) },
            qr/unknown router option '\Q$removed\E'/,
            "removed Router option '$removed' is rejected without compatibility";
    }
    like dies { route '/bad-middleware' => $handler, middleware => 'nope' }, qr/middleware must be an arrayref/, 'middleware must be an arrayref';
    my $not_middleware = bless {}, 'NotMiddlewareObject';
    for my $invalid ([], {}, $not_middleware) {
        like dies {
            route '/invalid-middleware' => $handler,
                middleware => [$invalid]
        }, qr/middleware class name, coderef factory, object with wrap, or middleware description/,
            'direct middleware entries reject values outside the four supported forms';
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
};

done_testing;
