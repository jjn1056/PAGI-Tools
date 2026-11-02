package PAGI::App::Compose;
use strict;
use warnings;
use namespace::autoclean;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use parent 'PAGI::App';
use PAGI::Compose ();
use PAGI::Utils ();

# The hooks a subclass writes. Each runs when to_app builds the application,
# never per request.

# Required: the root routing nodes, an arrayref for compose's routes.
sub routes { croak ref($_[0]) . ' must implement routes' }

# Optional: application middleware, an arrayref of middleware(...)
# descriptions. Not "middleware": that name is the imported function.
sub app_middleware { return [] }

# Optional: the root Router's http_default; undef means none.
sub http_default { return undef }

# Optional lifespan, called as ($self, $state, $scope); may be async.
# Compose gets a lifespan callback only for a hook the class overrides,
# because configured callbacks require server state support.
sub on_startup  { return }
sub on_shutdown { return }

# Optional: the application to serve, given the composition; the default
# serves the composition itself. A whole-application feature that needs the
# declaration (openapi) takes the composition and returns a new one here.
sub application { my ($self, $composition) = @_; return $composition }

# The PAGI::Compose description the hooks declare, built afresh on each
# call: to_app compiles it, a test inspects it. The hooks run in this order:
# prepare_app, routes, app_middleware, http_default.
sub composition {
    my ($self) = @_;
    my $class = ref $self;
    croak "$class is a PAGI::App::Compose: it declares routes and never runs"
        . ' call; remove call'
        if $self->can('call') != PAGI::App->can('call');
    $self->prepare_app;

    # Each hook in scalar context, so a list it returns is caught here and
    # named, instead of surfacing as a compose option error.
    my $routes = $self->routes;
    croak "${class}->routes must return an arrayref of routing nodes"
        unless ref $routes eq 'ARRAY';
    my $middleware = $self->app_middleware;
    croak "${class}->app_middleware must return an arrayref of middleware(...) descriptions"
        unless ref $middleware eq 'ARRAY';
    my $http_default = $self->http_default;

    my %lifespan;
    for my $phase (qw(startup shutdown)) {
        my $hook = "on_$phase";
        next if $self->can($hook) == __PACKAGE__->can($hook);
        $lifespan{$phase} = sub { $self->$hook(@_) };
    }
    return PAGI::Compose->new(
        routes     => $routes,
        middleware => $middleware,
        (defined $http_default ? (http_default => $http_default) : ()),
        (%lifespan             ? (lifespan     => \%lifespan)     : ()),
    );
}

sub to_app {
    my ($self) = @_;
    my $class = ref $self;
    my $application = $self->application($self->composition);
    croak "${class}->application must return the application to serve: a Compose, or anything with to_app"
        unless ref($application) eq 'CODE' || (blessed($application) && $application->can('to_app'));
    return PAGI::Utils::to_app($application);
}

1;

__END__

=head1 NAME

PAGI::App::Compose - A PAGI::App whose methods declare a Compose application

=head1 SYNOPSIS

The smallest application, in F<lib/MyApp.pm>:

    package MyApp;
    use strict;
    use warnings;
    use parent 'PAGI::App::Compose';
    use PAGI::Tools qw(response route);

    sub routes { [ route('/' => sub { response('Text', 'hello') }) ] }

    __PACKAGE__->run_if_script;

Every hook:

    package MyApp;
    use strict;
    use warnings;
    use parent 'PAGI::App::Compose';
    use PAGI::Pages qw(not_found);
    use PAGI::Tools qw(middleware response route);

    sub routes {
        my ($self) = @_;
        return [ route('/' => sub { response('Text', 'hello') }) ];
    }

    sub app_middleware { [ middleware('RequestId') ] }

    sub http_default { not_found() }

    sub on_startup {
        my ($self, $state, $scope) = @_;
        $state->{started} = time;
    }

    sub on_shutdown {
        my ($self, $state, $scope) = @_;
        delete $state->{started};
    }

    __PACKAGE__->run_if_script;

Serve it, or try one request from the shell without a server:

    pagi-server -Ilib --app lib/MyApp.pm
    perl -Ilib lib/MyApp.pm GET /

=head1 DESCRIPTION

A L<PAGI::App> for a L<PAGI::Compose> application. The subclass declares
the application in methods, one per Compose option; C<to_app> calls them
once and compiles the result, so nothing about the route table is built per
request. Every application written this way keeps its routes in C<routes>
and its startup in C<on_startup>, and the description stays reachable
through L</composition> for tests.

The hooks and C<composition> are instance methods, called on the object a
server builds with C<new>, so they can read its attributes. A subclass does
not write C<call>.

=head1 HOOKS

=head2 routes

    sub routes { my ($self) = @_; return [ ... ] }

Required. Returns an arrayref of routing nodes (C<route>, C<mount>,
C<websocket>, C<sse>), Compose's C<routes>. Returning a list instead of an
arrayref is an error naming this method.

=head2 app_middleware

    sub app_middleware { [ middleware('RequestId') ] }

Optional. Returns an arrayref of C<middleware(...)> descriptions,
Compose's C<middleware>: application middleware, outside the routes. It is
not called C<middleware>, because a class that imports the C<middleware>
function and defines a method of the same name replaces the function with
the method and recurses. The default is C<[]>.

=head2 http_default

    sub http_default { not_found() }

Optional. Returns the root Router's C<http_default>: a Pages value, a
one-Request handler, or an application (see L<PAGI::Compose/routes>). The
default, C<undef>, means none.

=head2 on_startup, on_shutdown

    sub on_startup {
        my ($self, $state, $scope) = @_;
        ...
    }

Optional. Called at lifespan startup and shutdown with the server's state
hashref and the lifespan scope, as Compose's C<lifespan> callbacks are
(see L<PAGI::Compose/LIFESPAN OWNERSHIP AND STATE>). Either may be an
C<async sub>; a Future it returns is awaited. Startup writes the resources
handlers read through L<PAGI::State>.

A class gets lifespan only for a hook it overrides, directly, through an
intermediate class, or through a role: Compose's lifespan callbacks require
server state support, and an application without them runs without it.

C<on_startup> may declare values instead of building them -- built on first
use, once per worker, once per request, or on every use, sync or async: see
L<PAGI::State/LIFETIMES>.

=head2 application

    sub application ($self, $composition) {
        return openapi($composition, title => 'Notes', version => '1.0.0');
    }

Optional. Called by C<to_app> with the composition the hooks declare;
returns the application to serve -- a L<PAGI::Compose>, or anything with
C<to_app>. The default returns the composition. A feature that needs the
whole application's declaration, rather than wrapping its requests, takes the
composition here and returns a new one: L<PAGI::Routing::OpenAPI/openapi> adds
the document route this way. Middleware, which wraps requests and needs no
declaration, belongs in C<app_middleware>.

=head1 METHODS

=head2 composition

    my $composition = MyApp->new->composition;
    $composition->named_routes;
    $composition->path_for('/home');

Returns the L<PAGI::Compose> description the hooks declare, built afresh
on each call: C<to_app> compiles it, a test inspects it. It runs
C<prepare_app>, then C<routes>, C<app_middleware> and C<http_default>, in
that order. It dies when the class defines C<call>, or when C<routes> or
C<app_middleware> returns something other than an arrayref.

=head2 to_app

Returns the compiled application: C<application>'s result for the
composition, compiled. It dies when C<application> returns something that is
not an application. A C<to_app> that does not call C<SUPER::to_app> replaces
all of the above; C<application> is the place to change what is served.

L<PAGI::App>'s C<new>, C<prepare_app>, C<run_if_script> and C<run> are
inherited unchanged; C<prepare_app> runs once in C<composition>, before the
hooks.

=head1 WHEN EACH PART RUNS

=over 4

=item * Loading the module (C<use MyApp>, C<pagi-server --app>): nothing;
C<run_if_script> returns an application provider.

=item * C<new>: the arguments are blessed, or Moo or Moose sets the
attributes.

=item * C<composition>: C<prepare_app> and the hooks run, and Compose builds
its root Router; route targets are built here (C<endpoint('Class')> loads
its class, C<< PAGI::App::File->new >> runs). Middleware is not.

=item * C<to_app> (once per server, per L<PAGI::Test::Client>, or per command
line): C<composition>, then C<application> with it, then compilation, which
loads, constructs and wraps the middleware.

=item * Each request: only the compiled application runs; no hook does.

=item * Lifespan startup and shutdown: C<on_startup> and C<on_shutdown>.

=back

=head1 EXTENDING

A subclass layers on its parent's hooks:

    sub on_startup {
        my ($self, $state, $scope) = @_;
        $self->SUPER::on_startup($state, $scope);
        $state->{cache} = {};
    }

A L<Moo> role adds to every application that consumes it:

    package MyCompany::Role::Standard;
    use Moo::Role;
    use PAGI::Tools qw(middleware);

    around app_middleware => sub {
        my ($orig, $self) = @_;
        return [ middleware('RequestId'), @{ $self->$orig } ];
    };

A Moo class reads its attributes in the hooks, which run after C<new> has
set them:

    package MyApp;
    use Moo;
    extends 'PAGI::App::Compose';
    use PAGI::Tools qw(response route);

    has greeting => (is => 'ro', default => sub { $ENV{MYAPP_GREETING} // 'hello' });

    sub routes {
        my ($self) = @_;
        my $greeting = $self->greeting;
        return [ route('/' => sub { response('Text', $greeting) }) ];
    }

A server builds the application with C<new> and no arguments, so an
attribute it needs has a default. A L<Moose> class needs
C<use MooseX::NonMoose>, as for L<PAGI::App>.

=head1 TESTING

    my $composition = MyApp->new->composition;
    is $composition->path_for('/home'), '/';

    PAGI::Test::Client->run(MyApp->new, sub {
        my ($client) = @_;
        is $client->get('/')->status, 200;
    });

An application with C<on_startup> is tested with C<< PAGI::Test::Client->run >>
or C<< lifespan => 1 >>: with the client's default C<< lifespan => 0 >> its
handlers get no state.

=head1 MISTAKES

=over 4

=item * Writing C<call>: C<composition> dies naming it. Building the
application in C<call> rebuilds it, and its middleware, on every request.

=item * Returning a list from C<routes> or C<app_middleware>: return an
arrayref.

=item * Defining C<sub middleware> in a class that imports C<middleware>:
the hook is C<app_middleware>.

=item * Importing C<to_app> from L<PAGI::Utils>: it then answers
C<< $self->to_app >> and recurses.

=item * Side effects in C<routes>: it also runs each time a test calls
C<composition>. Open resources in C<on_startup>.

=item * Mounting one of these applications under another: its lifespan does
not run (L<PAGI::Compose/LIFESPAN OWNERSHIP AND STATE>).

=item * A C<to_app> that does not call C<SUPER::to_app>: none of the above
applies to it. To change what is served, override C<application>.

=back

=head1 SEE ALSO

L<PAGI::App>, L<PAGI::Compose>, L<PAGI::Routing>, L<PAGI::State>,
L<PAGI::Test::Client>

=cut
