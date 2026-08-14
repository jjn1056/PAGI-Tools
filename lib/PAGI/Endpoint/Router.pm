package PAGI::Endpoint::Router;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed);

sub new {
    my ($class, @args) = @_;
    croak "$class->new accepts no arguments" if @args;
    return bless {}, $class;
}

sub routes { return }

sub to_router {
    my ($invocant) = @_;
    my $endpoint = _instance_for($invocant);
    require PAGI::App::Router::Materializer;
    my $materializer = PAGI::App::Router::Materializer->new;
    return $materializer->materialize($endpoint, '<root>');
}

sub to_app {
    my ($invocant) = @_;
    my $endpoint = _instance_for($invocant);
    return $endpoint->to_router->to_app;
}

sub _materialize_with {
    my ($self, $materializer) = @_;
    require PAGI::App::Router;
    require PAGI::Endpoint::Router::Builder;
    my $app_router = PAGI::App::Router->new;
    my $facade = PAGI::Endpoint::Router::Builder->new($self, $app_router);
    $self->routes($facade);
    return $app_router->_materialize_with($materializer);
}

sub middleware_as {
    my ($self, $name) = @_;
    my $method = $self->_required_local_method($name, 'middleware');
    return sub { return $method->($self, @_) };
}

sub app_as {
    my ($self, $name) = @_;
    my $method = $self->_required_local_method($name, 'application');
    return sub { return $method->($self, @_) };
}

sub new_context {
    my ($self, $scope, $receive, $send) = @_;
    require PAGI::Context;
    return PAGI::Context->new($scope, $receive, $send);
}

sub app_path {
    my ($invocant, @components) = @_;
    my $class = blessed($invocant) || $invocant;

    (my $module_file = $class) =~ s{::}{/}g;
    $module_file .= '.pm';

    my (undef, $caller_source) = caller;
    my $source = $INC{$module_file};
    $source = $caller_source unless defined $source && length $source;

    require PAGI::Utils;
    return PAGI::Utils::_app_path_from_origin(
        $class, $source, @components,
    );
}

sub _required_local_method {
    my ($self, $name, $kind) = @_;
    croak "$kind method name must be an unqualified name"
        unless defined $name && !ref($name)
            && $name =~ /\A[A-Za-z_]\w*\z/;
    my $method = $self->can($name);
    my $class = blessed($self) || $self;
    croak qq{$class has no $kind method "$name"} unless $method;
    return $method;
}

sub _instance_for {
    my ($invocant) = @_;
    return $invocant if blessed($invocant);
    return $invocant->new;
}

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::Endpoint::Router - Method-oriented frontend for shared PAGI routing

=head1 SYNOPSIS

    package MyApp::Endpoint;
    use parent 'PAGI::Endpoint::Router';
    use Future::AsyncAwait;
    use PAGI::Compose qw(compose);
    use PAGI::Routing qw(middleware);

    sub new {
        my ($class, %args) = @_;
        die 'repository is required' unless $args{repository};
        return bless { repository => $args{repository} }, $class;
    }

    sub routes {
        my ($self, $r) = @_;
        $r->get('/people/{id}' => [
            'RequestId',
            $self->middleware_as('authenticate'),
            $self->{configured_middleware},
            middleware('Session', cookie_name => 'sid'),
        ] => 'show')->name('show');
        $r->get('/download', raw => $self->app_as('download'));
        $r->websocket('/chat/{room}' => 'chat')->name('chat');
        $r->sse('/events' => 'events')->name('events');
        $r->mount('/admin' => $self->app_as('admin_app'));
    }

    sub show {
        my ($self, $c) = @_;
        return $c->json($self->{repository}->find($c->path_param('id')));
    }

    sub authenticate {
        my ($self, $inner_app) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            return await $inner_app->($scope, $receive, $send);
        };
    }

    my $endpoint = MyApp::Endpoint->new(repository => $repository);
    my $static = $endpoint->app_path('static');
    my $app = compose(app => $endpoint->to_router)->to_app;

=head1 DESCRIPTION

C<PAGI::Endpoint::Router> is the method-oriented mutable frontend over
L<PAGI::App::Router> and the shared immutable routing compiler. It binds route
handler names to one ordinary Perl object. It does not match requests, build
Contexts for compiled routes, adapt Responses, load handler packages, inject
state, or maintain a separate middleware chain.

=head1 MIGRATING

This release intentionally replaces the previous Endpoint handler,
middleware, state, Context, nesting, and naming contracts without a
compatibility layer. See the
L<standalone router frontend upgrade guide|https://github.com/jjn1056/PAGI-Tools/blob/main/UPGRADING.md>
in the source distribution for concrete before-and-after examples with
exercised shipped replacements.

=head1 CONSTRUCTION AND LIFECYCLE

=head2 new

The base constructor accepts no options and returns an empty blessed hash.
Configured subclasses override C<new> with their own ordinary validation and
accessors. Configuration is simply object data; Endpoint supplies no hidden
state hash.

=head2 to_router

    my $snapshot = MyApp::Endpoint->to_router;
    my $same_object_snapshot = $endpoint->to_router;

A class call constructs exactly one instance with C<new>. An object call
retains that exact object. Each call materializes a fresh immutable
L<PAGI::Routing::Router> snapshot, so later changes to ordinary object fields
do not alter an existing snapshot's declaration graph.

Nested Endpoint objects are mounted with the routing-aware form:

    $r->mount('/people', router => $people_endpoint)->name('people');

All nested mutable frontends materialize in the same root operation. Reusing
one object at sibling placements reuses one child Router identity within that
snapshot while each Mount retains independent path, name, and metadata.
Recursive Endpoint graphs fail with the shared placement-cycle diagnostic.

=head2 to_app

Materializes one fresh snapshot and compiles it through the shared compiler.
Retain the returned native PAGI routing component for its intended lifetime. A
class call constructs one Endpoint instance; an object call keeps its receiver.
Direct C<to_app> is legal low-level compilation, but an exhausted HTTP search
emits no response. Use an enclosing L<PAGI::Compose> for a complete deployed
application, or attach routing fallback middleware at the enclosing Router or
Mount boundary.

=head1 ROUTE DECLARATIONS

C<routes($builder)> receives an Endpoint-aware facade over one public App
Router. It provides C<get>, C<post>, C<put>, C<patch>, C<delete>, C<head>,
C<options>, C<any>, C<route>, C<websocket>, C<sse>, C<group>, C<mount>, and the
last-declaration modifiers C<name>, C<desc>, and C<constraints>. Declarations
remain in exact first-seen order. Groups receive another Endpoint facade bound
to the same object.

The same snapshot and reverse-routing rules as L<PAGI::App::Router> apply.
Names are local logical segments; nested names form canonical slash addresses.
Context C<path_for> resolves relative to the active placement, while an
absolute name starts with C</>.

=head1 HANDLERS

    $r->get('/method' => 'show');
    $r->get('/closure' => sub {
        my ($c) = @_;
        return $c->text('closure');
    });

A plain unqualified string in handler position is validated with C<can> while
the snapshot is built. The exact resulting method CODE is retained and later
called as C<($endpoint, $context)>. Local, inherited, and role-installed or
aliased methods therefore work. Missing methods and qualified strings are
errors; handler strings never load packages.

A handler coderef passes to the shared App Router unmodified. It receives only
the ordinary protocol-specific Context and is never rebound to the Endpoint.
HTTP handlers return an immediate Response or a Future resolving to one.
WebSocket and SSE handlers use their Context operations and may complete
immediately or through a Future. All response validation and protocol events
belong to the shared compiler.

=head1 RAW LEAVES

Endpoint accepts the same explicit native leaf grammar as App Router, after
the optional positional middleware array:

    $r->get('/raw-http' => [
        $self->middleware_as('audit'),
    ], raw => $native_http_app);
    $r->websocket('/raw-ws', raw => $native_ws_app);
    $r->sse('/raw-events', raw => $native_sse_app);

The C<raw> marker and native application coderef pass unchanged to the shared
App builder. The target receives exactly C<($scope, $receive, $send)> and owns
its protocol events; route middleware still wraps that native application.
Malformed raw declarations fail synchronously with raw-target diagnostics.

An ordinary method-name target continues to bind C<($endpoint, $context)>.
An ordinary handler coderef continues to pass through unchanged and receive
one Context. Neither form becomes raw without the explicit marker.

=head1 MIDDLEWARE

Every router, group, mount, and route middleware array uses the universal four
forms:

=over 4

=item * a middleware class string;

=item * a factory coderef;

=item * a configured object with C<wrap>;

=item * a C<PAGI::Routing::Middleware> description, commonly built with
C<middleware($class, %configuration)>.

=back

Descriptions normalize during declaration and resolve at app compilation.
Factories and C<wrap> methods must return a native app coderef synchronously.
The first item listed is outermost. The resulting native middleware controls
whether it calls downstream, which scope it passes, and how it wraps
C<receive> and C<send>. This contract is identical for HTTP, WebSocket, and
SSE; there is no response-valued C<($context, $next)> Endpoint middleware.

=head2 middleware_as

    my $factory = $endpoint->middleware_as('authenticate');

Validates an unqualified local, inherited, or role-installed method and
returns a normal middleware factory closure. At compilation the method
receives C<($endpoint, $inner_app)> and must return the wrapped native app
immediately. Constructing the helper performs no protocol I/O.

=head2 app_as

    my $app = $endpoint->app_as('native_app');
    $r->get('/download', raw => $endpoint->app_as('native_app'));
    $r->mount('/legacy' => $endpoint->app_as('native_app'));

Validates the method and returns a native application closure. When invoked,
the method receives C<($endpoint, $scope, $receive, $send)>. The helper is
useful as the target of an exact raw leaf, an opaque mount, or another native
composition boundary, and does no work merely by being constructed. A raw
leaf remains method-aware and keeps its matched path; an opaque mount owns and
rewrites a matched prefix.

=head1 CONTEXT AND STATE

=head2 new_context

    my $c = $endpoint->new_context($scope, $receive, $send);

This explicit convenience method calls C<PAGI::Context-E<gt>new> and therefore
selects the built-in HTTP, WebSocket, or SSE subclass. It is not the routing
compiler's Context factory. Overriding it affects only explicit calls to the
helper, never compiled route dispatch.

=head2 app_path

    my $home   = $endpoint->app_path();
    my $static = $endpoint->app_path('static');

Returns an absolute, platform-canonical application path using the same
component validation and output contract as L<PAGI::Utils/app_path>. Object
and class calls use their concrete Endpoint class. A loaded class obtains its
source from the corresponding C<%INC> module entry, while an inline class
falls back to the source of the explicit helper call.

C<PAGI_HOME>, when defined and nonempty, has first precedence. The override
affects only explicit C<app_path> calls; it does not affect route compilation
or dispatch.

Endpoint object fields and request lifespan state are separate mechanisms.
Use validated constructor fields for object configuration. C<$c-E<gt>state>
reads the C<state> supplied in the server-owned request scope, including state
prepared through L<PAGI::Compose> lifespan callbacks. Endpoint neither creates
nor injects that key and has no C<state> or C<context_class> method.

=head1 SNAPSHOTS AND ORDER

Each C<to_router> returns a fresh immutable snapshot, and each C<to_app>
compiles one retained snapshot. Matching, middleware folds, nonterminal HTTP
exhaustion, first-seen method evidence, route metadata, reverse resolution, and
request-local scope cloning are exactly those documented by
L<PAGI::App::Router>. Endpoint adds only method binding over that machinery and
does not add Router fallback callback options or accessors.

=cut
