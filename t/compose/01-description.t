#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(refaddr);
use overload ();
use PAGI::Compose qw(compose);
use PAGI::Routing qw(route middleware);

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

my $leaf = route('/' => sub { return $_[0]->text('home') });
my $factory = sub { my ($inner) = @_; return $inner };
my $bare_configured = ComposeConfiguredMiddleware->new;
my $mw = middleware('RequestId', header => 'X-Request-ID');
my $startup = sub { return };
my $routes = [$leaf];
my $middleware = ['RequestId', $factory, $bare_configured, $mw];
my $lifespan = { startup => $startup };
my $composition = compose(
    routes => $routes,
    middleware => $middleware,
    lifespan => $lifespan,
);

isa_ok($composition, 'PAGI::Compose');
is($composition->routes, [$leaf], 'routes accessor returns declared nodes');
is($composition->app, undef, 'app is absent in routes mode');
my $stored = $composition->middleware;
isa_ok($stored->[0], 'PAGI::Routing::Middleware');
is($stored->[0]->factory, 'RequestId', 'bare class target is retained');
is(refaddr($stored->[1]->factory), refaddr($factory),
    'bare factory identity is retained');
is(refaddr($stored->[2]->factory), refaddr($bare_configured),
    'bare configured object identity is retained');
is(refaddr($stored->[3]), refaddr($mw),
    'explicit description identity is retained');
is(refaddr($composition->lifespan->{startup}), refaddr($startup), 'callback identity is retained');
ok(!overload::Method($composition, '&{}'), 'composition has no coderef overload');

push @$routes, route('/mutated' => sub { return $_[0]->text('bad') });
push @$middleware, middleware(sub { return $_[0] });
$lifespan->{shutdown} = sub { return };
push @{$composition->routes}, $leaf;
push @{$composition->middleware}, $mw;
$composition->lifespan->{shutdown} = sub { return };
is($composition->routes, [$leaf], 'routes are defensively copied');
is(scalar @{$composition->middleware}, 4,
    'normalized middleware input and accessor arrays are defensively copied');
is([sort keys %{$composition->lifespan}], ['startup'], 'lifespan hash is defensively copied');

my $app = sub { return };
my $object_form = PAGI::Compose->new(app => $app);
my $function_form = compose(app => $app);
is(refaddr($object_form->app), refaddr($app), 'OO form retains app identity');
is(refaddr($function_form->app), refaddr($app), 'functional form retains app identity');
is($object_form->routes, undef, 'routes are absent in app mode');
is($object_form->middleware, [], 'middleware defaults empty');
is($object_form->lifespan, undef, 'lifespan defaults absent');

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
    ['missing target', [], qr/exactly one of routes or app/],
    ['both targets', [routes => [], app => $app], qr/exactly one of routes or app/],
    ['undefined app', [app => undef], qr/compose app must be defined/],
    ['unblessed app reference', [app => []], qr/coderef, object, or class name/],
    ['invalid class name', [app => 'not-a-package'], qr/coderef, object, or class name/],
    ['routes not array', [routes => {}], qr/routes must contain PAGI::Routing nodes/],
    ['invalid route member', [routes => [{}]], qr/routes must contain PAGI::Routing nodes/],
    ['middleware not array', [routes => [], middleware => {}], qr/middleware must be an arrayref/],
    ['invalid middleware scalar',
        [routes => [], middleware => [42]],
        qr/compose middleware entry 0 must be a middleware class name/],
    ['invalid middleware array',
        [routes => [], middleware => [[]]],
        qr/compose middleware entry 0 must be a middleware class name/],
    ['invalid middleware hash',
        [routes => [], middleware => [{}]],
        qr/compose middleware entry 0 must be a middleware class name/],
    ['empty middleware class name',
        [routes => [], middleware => ['']],
        qr/compose middleware entry 0 must be a middleware class name/],
    ['malformed middleware class name',
        [routes => [], middleware => ['not-a-package']],
        qr/compose middleware entry 0 must be a middleware class name/],
    ['middleware object without wrap',
        [routes => [], middleware => [$object_without_wrap]],
        qr/compose middleware entry 0 must be a middleware class name/],
    ['class configuration supplied bare in a list',
        [routes => [], middleware => ['RequestId', { header => 'X-Request-ID' }]],
        qr/compose middleware entry 1 must be a middleware class name/],
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

my $deferred = compose(app => DeferredComponentCheck->new);
isa_ok($deferred, ['PAGI::Compose'], 'object capability is deferred to compilation');
ok($deferred->can('to_app'), 'description exposes the explicit compile boundary');

done_testing;
