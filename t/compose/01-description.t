#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(refaddr);
use overload ();
use PAGI::Compose qw(compose);
use PAGI::Pages ();
use PAGI::Response::Text ();
use PAGI::Routing qw(router route middleware);

{
    package ComposeNoImports;
    use PAGI::Compose ();
}
{
    package ComposeAllImports;
    use PAGI::Compose qw(:ALL);
}
{
    package DeferredComponentCheck;
    sub new { return bless {}, $_[0] }
    sub to_app { return sub { return } }
}
{
    package ComposeConfiguredMiddleware;
    sub new { return bless {}, $_[0] }
    sub wrap { return $_[1] }
}

ok(!ComposeNoImports->can('compose'), 'nothing exports by default');
ok(ComposeAllImports->can('compose'), 'uppercase ALL exports compose');

my ($lowercase_error, $lowercase_stderr);
{
    local *STDERR;
    open STDERR, '>', \$lowercase_stderr or die "capture STDERR: $!";
    $lowercase_error = dies {
        eval q{ package ComposeBadImports; use PAGI::Compose qw(:all); 1 }
            or die $@;
    };
}
like($lowercase_error, qr/Can't continue after import errors/, 'lowercase tag is rejected');
like($lowercase_stderr, qr/"all" is not defined/, 'diagnostic names the invalid tag');

my $leaf = route('/' => sub {
    return PAGI::Response::Text->new('home');
}, name => 'home');

my $default = PAGI::Pages->not_found(detail => 'No root route');
my $routing = router(
    routes       => [$leaf],
    http_default => $default,
    desc         => 'Retained root',
);

my $composition = compose(
    router     => $routing,
    middleware => [middleware('RequestId')],
    lifespan   => { startup => sub { return } },
);

isa_ok($composition, 'PAGI::Compose');
is(refaddr($composition->router), refaddr($routing),
    'router form retains exact Router identity');
is($composition->routes, [$leaf], 'routes delegates to retained Router');
is(refaddr($composition->http_default), refaddr($default),
    'http_default delegates by identity');
is($composition->desc, 'Retained root', 'desc delegates');
is($composition->path_for('/home'), '/', 'path_for delegates');
is(refaddr($composition->route_named('/home')), refaddr($leaf),
    'route_named delegates');
ok(exists $composition->named_routes->{'/home'},
    'named_routes delegates');
ok(!$composition->can('app'), 'retired app accessor is absent');
ok(!overload::Method($composition, '&{}'), 'composition has no coderef overload');

my $factory = sub { my ($inner) = @_; return $inner };
my $bare_configured = ComposeConfiguredMiddleware->new;
my $mw = middleware('RequestId', header => 'X-Request-ID');
my $startup = sub { return };
my $routes = [$leaf];
my $middleware = [
    middleware('RequestId'),
    middleware($factory),
    middleware($bare_configured),
    $mw,
];
my $lifespan = { startup => $startup };
my $shallow = compose(
    router     => $routing,
    middleware => $middleware,
    lifespan   => $lifespan,
);

my $stored = $shallow->middleware;
is(refaddr($stored->[0]), refaddr($middleware->[0]),
    'explicit class description identity is retained');
is(refaddr($stored->[1]), refaddr($middleware->[1]),
    'explicit factory description identity is retained');
is(refaddr($stored->[2]), refaddr($middleware->[2]),
    'explicit configured object description identity is retained');
is(refaddr($stored->[3]), refaddr($mw),
    'explicit description identity is retained');
is(refaddr($shallow->lifespan->{startup}), refaddr($startup),
    'callback identity is retained');

my $from_routes = compose(
    routes       => $routes,
    http_default => $default,
    desc         => 'Constructed root',
);

isa_ok($from_routes->router, 'PAGI::Routing::Router');
is($from_routes->routes, [$leaf], 'routes form retains constructed Router');
is(refaddr($from_routes->http_default), refaddr($default),
    'routes form passes http_default to Router');
is($from_routes->desc, 'Constructed root',
    'routes form passes desc to Router');

push @$routes, route('/mutated' => sub {
    return PAGI::Response::Text->new('bad');
});
push @$middleware, middleware(sub { return $_[0] });
$lifespan->{shutdown} = sub { return };
push @{$from_routes->routes}, $leaf;
push @{$shallow->middleware}, $mw;
$shallow->lifespan->{shutdown} = sub { return };
is($from_routes->routes, [$leaf],
    'Router retains a shallow copy of the supplied routes');
is(scalar @{$shallow->middleware}, 4,
    'normalized middleware input and accessor arrays are defensively copied');
is([sort keys %{$shallow->lifespan}], ['startup'],
    'lifespan hash is defensively copied');

my $object_without_wrap = bless {}, 'ComposeObjectWithoutWrap';

my @invalid = (
    ['odd options', [routes => [], 'dangling'], qr/key\/value pairs/],
    ['unknown option', [routes => [], debug => 1], qr/unknown compose option 'debug'/],
    ['defaults is not a Compose option', [routes => [], defaults => 0],
        qr/unknown compose option 'defaults'/],
    ['without is not a Compose option', [routes => [], without => []],
        qr/unknown compose option 'without'/],
    ['not_found is not a Compose option', [routes => [], not_found => sub { }],
        qr/unknown compose option 'not_found'/],
    ['method_not_allowed is not a Compose option',
        [routes => [], method_not_allowed => sub { }],
        qr/unknown compose option 'method_not_allowed'/],
    ['server_error is not a Compose option',
        [routes => [], server_error => sub { }],
        qr/unknown compose option 'server_error'/],
    ['missing target', [], qr/exactly one of routes or router/],
    ['both targets', [routes => [], router => $routing],
        qr/exactly one of routes or router/],
    ['retired app Router', [app => $routing],
        qr/no longer accepts 'app'.*router =>/s],
    ['retired native app', [app => sub { return }],
        qr/no longer accepts 'app'.*deploy.*directly/s],
    ['router undef', [router => undef],
        qr/instantiated PAGI::Routing::Router/],
    ['router coderef', [router => sub { return }],
        qr/instantiated PAGI::Routing::Router/],
    ['router generic to_app object',
        [router => DeferredComponentCheck->new],
        qr/instantiated PAGI::Routing::Router/],
    ['router with http_default',
        [router => $routing, http_default => $default],
        qr/http_default cannot be combined with router/],
    ['router with undef http_default',
        [router => $routing, http_default => undef],
        qr/http_default cannot be combined with router/],
    ['router with desc', [router => $routing, desc => 'override'],
        qr/desc cannot be combined with router/],
    ['router with undef desc', [router => $routing, desc => undef],
        qr/desc cannot be combined with router/],
    ['routes not array', [routes => {}],
        qr/routes must contain PAGI::Routing nodes/],
    ['invalid route member', [routes => [{}]],
        qr/routes must contain PAGI::Routing nodes/],
    ['middleware not array', [routes => [], middleware => {}], qr/middleware must be an arrayref/],
    ['bare middleware class', [routes => [], middleware => ['RequestId']],
        qr/compose middleware entry 0 must be a PAGI::Routing::Middleware description returned by middleware\(\.\.\.\)/],
    ['bare middleware factory', [routes => [], middleware => [$factory]],
        qr/compose middleware entry 0 must be a PAGI::Routing::Middleware description returned by middleware\(\.\.\.\)/],
    ['bare configured middleware', [routes => [], middleware => [$bare_configured]],
        qr/compose middleware entry 0 must be a PAGI::Routing::Middleware description returned by middleware\(\.\.\.\)/],
    ['invalid middleware hash', [routes => [], middleware => [{}]],
        qr/compose middleware entry 0 must be a PAGI::Routing::Middleware description returned by middleware\(\.\.\.\)/],
    ['middleware object without wrap', [routes => [], middleware => [$object_without_wrap]],
        qr/compose middleware entry 0 must be a PAGI::Routing::Middleware description returned by middleware\(\.\.\.\)/],
    ['lifespan not hash', [routes => [], lifespan => []], qr/lifespan must be a hashref/],
    ['empty lifespan', [routes => [], lifespan => {}], qr/startup or shutdown/],
    ['unknown lifespan key', [routes => [], lifespan => { start => sub { } }], qr/unknown lifespan option 'start'/],
    ['non-code startup', [routes => [], lifespan => { startup => 1 }], qr/startup must be a coderef/],
    ['non-code shutdown', [routes => [], lifespan => { shutdown => {} }], qr/shutdown must be a coderef/],
);
for my $case (@invalid) {
    my ($label, $args, $pattern) = @$case;
    like(dies { PAGI::Compose->new(@$args) }, $pattern, $label);
}

ok($composition->can('to_app'), 'description exposes the explicit compile boundary');

done_testing;
