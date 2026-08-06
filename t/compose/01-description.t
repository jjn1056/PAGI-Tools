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
my $mw = middleware(sub { my ($app) = @_; return $app });
my $startup = sub { return };
my $routes = [$leaf];
my $middleware = [$mw];
my $lifespan = { startup => $startup };
my $composition = compose(
    routes => $routes,
    middleware => $middleware,
    lifespan => $lifespan,
);

isa_ok($composition, 'PAGI::Compose');
is($composition->routes, [$leaf], 'routes accessor returns declared nodes');
is($composition->app, undef, 'app is absent in routes mode');
is($composition->middleware, [$mw], 'middleware accessor returns descriptors');
is(refaddr($composition->lifespan->{startup}), refaddr($startup), 'callback identity is retained');
ok(!overload::Method($composition, '&{}'), 'composition has no coderef overload');

push @$routes, route('/mutated' => sub { return $_[0]->text('bad') });
push @$middleware, middleware(sub { return $_[0] });
$lifespan->{shutdown} = sub { return };
push @{$composition->routes}, $leaf;
push @{$composition->middleware}, $mw;
$composition->lifespan->{shutdown} = sub { return };
is($composition->routes, [$leaf], 'routes are defensively copied');
is($composition->middleware, [$mw], 'middleware is defensively copied');
is([sort keys %{$composition->lifespan}], ['startup'], 'lifespan hash is defensively copied');

my $app = sub { return };
my $object_form = PAGI::Compose->new(app => $app);
my $function_form = compose(app => $app);
is(refaddr($object_form->app), refaddr($app), 'OO form retains app identity');
is(refaddr($function_form->app), refaddr($app), 'functional form retains app identity');
is($object_form->routes, undef, 'routes are absent in app mode');
is($object_form->middleware, [], 'middleware defaults empty');
is($object_form->lifespan, undef, 'lifespan defaults absent');

my @invalid = (
    ['odd options', [routes => [], 'dangling'], qr/key\/value pairs/],
    ['unknown option', [routes => [], debug => 1], qr/unknown compose option 'debug'/],
    ['missing target', [], qr/exactly one of routes or app/],
    ['both targets', [routes => [], app => $app], qr/exactly one of routes or app/],
    ['undefined app', [app => undef], qr/compose app must be defined/],
    ['unblessed app reference', [app => []], qr/coderef, object, or class name/],
    ['invalid class name', [app => 'not-a-package'], qr/coderef, object, or class name/],
    ['routes not array', [routes => {}], qr/routes must contain PAGI::Routing nodes/],
    ['invalid route member', [routes => [{}]], qr/routes must contain PAGI::Routing nodes/],
    ['middleware not array', [routes => [], middleware => {}], qr/middleware must be an arrayref/],
    ['invalid middleware member', [routes => [], middleware => [sub { }]], qr/PAGI::Routing::Middleware/],
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
