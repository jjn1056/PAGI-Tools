package Tiny;

# A small opinionated web framework built on PAGI-Tools, written to find out
# where the seams are. It is deliberately the shape a Sinatra, Flask or
# FastAPI user expects:
#
#   - verbs (get/post/put/del) with a handler that takes one request;
#   - a Request subclass of the framework's own (param, svc);
#   - handlers may return a hashref (JSON), a string (HTML) or a Response;
#   - `before` hooks, Starlette-style `around` middleware with call_next;
#   - services built at startup and read as $req->svc('db');
#   - exception classes (or statuses) mapped to responses with `on_error`;
#   - a raw ($scope, $receive, $send) escape hatch with `raw`;
#   - plugins; an OpenAPI document generated from the Router.
#
# Each piece is marked with the PAGI-Tools seam it is built on, and with what
# that seam cost. See the README for the findings.

use v5.40;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(blessed);
use PAGI::Request;
use PAGI::Routing qw(route mount middleware request_response);
use PAGI::Compose qw(compose);
use PAGI::Response qw(response);
use PAGI::Utils qw(as_app_object);
use PAGI::Routing::OpenAPI ();

# ----------------------------------------------------------------------
# The framework's own Request. Seam: PAGI::Request is a plain class, so a
# subclass is one `parent` line; middleware('RequestClass') puts it in the
# scope, and every handler below that middleware gets one (see to_compose).

package Tiny::Request {
    use v5.40;
    use parent 'PAGI::Request';

    # One accessor for a path capture or a query parameter, as Dancer2 and
    # Mojolicious offer.
    sub param ($self, $name) {
        return $self->path_params->{$name} // $self->query_param($name);
    }

    # A service built at startup (see Tiny::service).
    sub svc ($self, $name) { return $self->state->get($name) }
}

# The response as an `around` middleware sees it after call_next: the start
# event, with status and headers editable before it is forwarded.

package Tiny::Sent {
    use v5.40;
    use PAGI::Headers;

    sub new ($class, $event) {
        return bless {
            event   => $event,
            status  => $event->{status},
            headers => PAGI::Headers->new($event->{headers} // []),
        }, $class;
    }
    sub status ($self, @v)  { $self->{status} = $v[0] if @v; return $self->{status} }
    sub headers ($self)     { return $self->{headers} }
    sub event ($self) {
        return { %{ $self->{event} }, status => $self->{status}, headers => $self->{headers}->to_pairs };
    }
}

# ----------------------------------------------------------------------
# The DSL. `use Tiny;` gives the calling package these functions and one
# application under construction; `tiny` finishes it.

use Exporter 'import';
our @EXPORT = qw(get post put del raw before around on_error service plugin openapi response tiny);

my %APP;    # calling package => Tiny instance under construction

sub _current { my $package = caller(1); return $APP{$package} //= Tiny->new($package) }

# $package is the application's: where its routes' {id:&Int} providers live.
sub new ($class, $package = scalar caller) {
    return bless {
        package  => $package,
        routes   => [],
        before   => [],
        around   => [],
        on_error => {},    # exception class or status => handler
        services => [],    # [name, builder] pairs, in order
    }, $class;
}

sub get  ($path, @rest) { _current()->add_route('GET',    $path, @rest) }
sub post ($path, @rest) { _current()->add_route('POST',   $path, @rest) }
sub put  ($path, @rest) { _current()->add_route('PUT',    $path, @rest) }
sub del  ($path, @rest) { _current()->add_route('DELETE', $path, @rest) }
sub raw  ($path, $code)  { _current()->add_raw($path, $code) }
sub before ($code)       { push @{ _current()->{before} }, $code }
sub around ($code)       { push @{ _current()->{around} }, $code }
sub on_error ($key, $code)   { _current()->{on_error}{$key} = $code }
sub service ($name, $code)   { push @{ _current()->{services} }, [$name, $code] }
sub plugin ($name, @args) {
    my $class = "Tiny::Plugin::$name";
    (my $file = "$class.pm") =~ s{::}{/}g;
    require $file;
    $class->register(_current(), @args);
}
sub tiny () { return _current()->to_compose }

# A handler that serves the OpenAPI document of the finished application.
sub openapi (%info) {
    my $self = _current();
    return sub ($req) { return $self->openapi_doc(%info) };
}

# ----------------------------------------------------------------------
# Routes

# add_route('GET', '/notes/{id}', [%options,] \&handler)
sub add_route ($self, $method, $path, @rest) {
    my $code = pop @rest;
    my %opt  = @rest;
    push @{ $self->{routes} }, route($path => $self->_endpoint($code),
        methods => [$method],
        # Seam: route() looks up a compact `{id:&Int}` provider in its
        # caller, which is Tiny; declaration_package names the application.
        declaration_package => $self->{package},
        (exists $opt{constraints} ? (constraints => $opt{constraints}) : ()),
        (exists $opt{name} ? (name => $opt{name}) : ()),
        (exists $opt{desc} ? (desc => $opt{desc}) : ()),
        (exists $opt{meta} ? (meta => $opt{meta}) : ()),
    );
    return;
}

# A raw PAGI application at a path: the escape hatch. Seam: as_app_object
# marks a ($scope, $receive, $send) coderef so a Route accepts it.
sub add_raw ($self, $path, $code) {
    push @{ $self->{routes} }, route($path => as_app_object($code), methods => '*');
    return;
}

# One handler, framework style: it gets a Tiny::Request, may return a
# plain value, and runs after the `before` hooks. Seam: request_response
# wraps the handler for the hooks and the plain values; the Request it
# hands over is the scope's class, Tiny::Request.
sub _endpoint ($self, $code) {
    my $before = $self->{before};
    return request_response(
        async sub ($req) {
            for my $hook (@$before) {
                my $early = await Future->wrap($hook->($req));
                return _coerce($early) if defined $early;
            }
            return _coerce(await Future->wrap($code->($req)));
        },
    );
}

# What a handler may return: a Response (or any app object) as it is, a
# hashref or arrayref as JSON, a string as HTML.
sub _coerce ($value) {
    return $value if blessed($value) && $value->can('to_app');
    return response('JSON', $value) if ref($value) eq 'HASH' || ref($value) eq 'ARRAY';
    return response('HTML', $value) if defined $value && !ref $value;
    return $value;    # undef or junk: PAGI::Routing reports it
}

# ----------------------------------------------------------------------
# `around` middleware: Starlette's BaseHTTPMiddleware shape,
#
#     around sub ($req, $next) {
#         my $sent = await $next->();        # runs the rest of the app
#         $sent->headers->set('X-Took', ...);
#         return $sent;                      # or a Response to replace it
#     };
#
# Seam: PAGI middleware wraps $send and sees events, so a call_next that
# returns "the response" has to be built: $next starts the inner app and
# resolves when its http.response.start arrives; the start event is held
# until the hook returns, then forwarded with the hook's edits; body events
# then flow through. Replacing the response fails the held send, which
# unwinds the inner handler. This is the one piece of raw-protocol code in
# the framework, and it is the most delicate.

sub _around_middleware ($hook) {
    return sub ($app) {
        return async sub ($scope, $receive, $send) {
            return await $app->($scope, $receive, $send) if $scope->{type} ne 'http';

            my $req     = Tiny::Request->new($scope, $receive);
            my $started = Future->new;    # the Tiny::Sent view, once the inner app starts its response
            my $release = Future->new;    # done when the hook has returned the view, failed to replace it
            my $inner;                    # the inner application's Future, once $next has started it

            my $held_send = async sub ($event) {
                if ($event->{type} eq 'http.response.start' && !$started->is_ready) {
                    my $sent = Tiny::Sent->new($event);
                    $started->done($sent);
                    await $release;
                    return await $send->($sent->event);
                }
                return await $send->($event);
            };

            my $next = async sub () {
                $inner //= $app->($scope, $receive, $held_send)->on_ready(sub ($f) {
                    # The inner app ended without starting a response: a
                    # failure, or nothing sent. Either way $next must not hang.
                    return if $started->is_ready;
                    $started->fail($f->is_failed ? $f->failure : "no response from the application\n");
                });
                return await $started;
            };

            my $result = await Future->wrap($hook->($req, $next));

            if (!$inner) {
                # The hook answered without calling $next: a short circuit.
                return await _coerce($result)->to_app->($scope, $receive, $send);
            }
            if (blessed($result) && $result->isa('Tiny::Sent')) {
                $release->done;
                return await $inner;
            }
            # The hook replaced the response: unwind the inner app, which is
            # suspended in its send of the start event, and answer instead.
            $release->fail("response replaced by around middleware\n");
            eval { await $inner };
            return await _coerce($result)->to_app->($scope, $receive, $send);
        };
    };
}

# ----------------------------------------------------------------------
# Errors. Seam: ErrorHandler's `catch` maps statuses and exception classes
# to answers, most specific class first, as Starlette's exception_handlers
# do; Tiny only adapts each one to its own handler shape and plain values.
# The entry sees the request as that layer sees it: a Tiny::Request,
# because RequestClass is outside it, but no path_params, which Starlette's
# handlers also lack.

sub _catch ($self) {
    my %on_error = %{ $self->{on_error} };
    return { map {
        my $code = $on_error{$_};
        ($_ => sub ($req, $error) { _coerce($code->($req, $error->exception)) });
    } keys %on_error };
}

# ----------------------------------------------------------------------
# Compose it. Services run in lifespan startup, in declaration order, each
# builder getting the state so far.

sub to_compose ($self) {
    my @services = @{ $self->{services} };
    my $compose  = compose(
        routes => $self->{routes},
        # The around hooks wrap the error handler, as Starlette's user middleware
        # wraps its ExceptionMiddleware, so a mapped error response passes
        # through them too. An error in a hook itself reaches Compose's own
        # last-resort ErrorHandler.
        middleware => [
            middleware('RequestClass', class => 'Tiny::Request'),
            (map { middleware(_around_middleware($_)) } @{ $self->{around} }),
            middleware('ErrorHandler', catch => $self->_catch),
        ],
        (@services ? (lifespan => {
            startup => async sub ($state, $scope) {
                for my $pair (@services) {
                    my ($name, $builder) = @$pair;
                    $state->{$name} = await Future->wrap($builder->($state));
                }
            },
        }) : ()),
    );
    $self->{compose} = $compose;
    return $compose;
}

# ----------------------------------------------------------------------
# An OpenAPI document. Seam: PAGI::Routing::OpenAPI reads route_table, so
# Tiny describes the application it built with no code of its own. Tiny
# holds its Compose, so the served route documents it from inside (and is
# listed itself).

sub openapi_doc ($self, %info) {
    return PAGI::Routing::OpenAPI->new(title => 'Tiny', version => '0', %info)
        ->document($self->{compose});
}

1;
