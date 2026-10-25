package PAGI::Endpoint::HTTP;

use strict;
use warnings;

use Future;
use Future::AsyncAwait;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use PAGI::Response::Empty ();
use PAGI::Response::Text ();
use PAGI::Utils qw(invoke_app);
use PAGI::Utils::Middleware ();

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

# HTTP methods we support
our @HTTP_METHODS = qw(get post put patch delete head options query);

sub allowed_methods {
    my ($self) = @_;
    my @allowed;
    for my $method (@HTTP_METHODS) {
        push @allowed, uc($method) if $self->can($method);
    }
    # HEAD is allowed if GET is defined
    push @allowed, 'HEAD' if $self->can('get') && !$self->can('head');
    # OPTIONS is always allowed
    push @allowed, 'OPTIONS' unless grep { $_ eq 'OPTIONS' } @allowed;
    return sort @allowed;
}

async sub dispatch {
    my ($self, $request) = @_;
    my $http_method = lc($request->method // 'GET');
    my @allowed_methods = $self->allowed_methods;
    my %allowed = map { lc($_) => 1 } @allowed_methods;

    my $application;

    # OPTIONS - return allowed methods (auto-respond unless overridden)
    if ($http_method eq 'options' && $allowed{options} && !$self->can('options')) {
        my $allow = join(', ', @allowed_methods);
        $application = PAGI::Response::Empty->new(
            headers => ['Allow' => $allow],
        );
    }
    # HEAD falls back to GET if not explicitly defined
    elsif ($http_method eq 'head' && $allowed{head}
        && !$self->can('head') && $self->can('get')) {
        $application = await Future->wrap($self->get($request));
    }
    # Dispatch to the appropriate method handler
    elsif ($allowed{$http_method} && $self->can($http_method)) {
        $application = await Future->wrap($self->$http_method($request));
    }
    # 405 Method Not Allowed: the endpoint owns Allow, whatever answers
    else {
        my $answer = await Future->wrap(
            $self->method_not_allowed($request, @allowed_methods));
        $application = _with_allow($answer, join(', ', @allowed_methods));
    }

    PAGI::Utils::_validate_app_value(
        $application,
        ref($self) . "->$http_method must return a PAGI application:",
    );
    return $application;
}

sub method_not_allowed {
    my ($self, $request, @allowed) = @_;
    return PAGI::Response::Text->new('Method Not Allowed', status => 405);
}

# Wraps an application so its response start carries exactly one Allow
# field, ours, on a copy of the event.
sub _with_allow {
    my ($application, $allow) = @_;
    PAGI::Utils::_validate_app_value($application,
        'method_not_allowed must return a PAGI application:');
    my $app = PAGI::Utils::to_app($application);
    return PAGI::Utils::as_app_object(async sub {
        my ($scope, $receive, $send) = @_;
        await $app->($scope, $receive,
            PAGI::Utils::Middleware::wrap_response_headers($send, sub {
                $_[0]->set('Allow', $allow);
            }));
    });
}

sub to_app {
    my ($endpoint) = @_;
    croak "to_app is called on an endpoint object; use endpoint('$endpoint') or $endpoint->new->to_app"
        unless blessed($endpoint);

    return async sub {
        my ($scope, $receive, $send) = @_;
        # The Request a BUILD_APP builder was given for this request, left
        # here by PAGI::Endpoint::_PerRequest, so the builder and the handler
        # share one Request. Taken before any await, so even a builder that
        # returns one object for every request hands each its own.
        my $given = delete $endpoint->{_pagi_builder_request};
        my $type = ref($scope) eq 'HASH' ? $scope->{type} : undef;
        croak 'PAGI::Endpoint::HTTP scope type is required'
            unless defined($type) && !ref($type) && length($type);
        croak "PAGI::Endpoint::HTTP requires HTTP scope; received '$type'"
            unless $type eq 'http';
        my $request = $given // PAGI::Utils::request_for_scope($scope, $receive);
        my $run = async sub {
            my ($send) = @_;
            my $application = await $endpoint->dispatch($request);
            await invoke_app($application, $scope, $receive, $send);
        };
        # A handler method's error is answered at the route, with this
        # Request, by the ErrorHandler the scope carries (if any).
        my $error_handler = $scope->{'pagi.error_handler'};
        return await $run->($send) unless $error_handler;
        await $error_handler->_run_at_route($request, $scope, $receive, $send, $run);
        return;
    };
}

1;

__END__

=head1 NAME

PAGI::Endpoint::HTTP - Class-based HTTP endpoint handler

=head1 SYNOPSIS

    package MyApp::UserAPI;
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;
    use PAGI::Tools qw(endpoint response route);

    async sub get {
        my ($self, $request) = @_;
        my $users = get_all_users();
        return response('JSON', $users);
    }

    async sub post {
        my ($self, $request) = @_;
        my $data = await $request->json;
        my $user = create_user($data);
        return response('JSON', $user, status => 201);
    }

    async sub delete {
        my ($self, $request) = @_;
        my $id = $request->path_param('id');
        delete_user($id);
        return response('Empty', status => 204);
    }

    # Name the class; endpoint() loads and builds it.
    route('/users/{id}' => endpoint('MyApp::UserAPI', repo => $repo));

=head1 DESCRIPTION

PAGI::Endpoint::HTTP provides a Starlette-inspired class-based approach
to handling HTTP requests. Define methods named after HTTP verbs (get,
post, put, patch, delete, head, options, query) and the endpoint
automatically dispatches to them.

When no method handler exists, L</method_not_allowed> answers -- by default a
plain-text C<405 Method Not Allowed> -- and the endpoint sets C<Allow> to its
complete, sorted C<allowed_methods> result. Explicit method handlers and an
explicit C<options> method remain authoritative custom-response seams.
Automatic OPTIONS retains its existing empty response with C<Allow>.

An Endpoint is placed at a Route with C<endpoint> (or as an instance placed
directly). With no explicit Route C<methods>, the Router snapshots
C<allowed_methods> once at Route construction, including GET-derived HEAD and OPTIONS. The Router then
owns unsupported-method 405 and the authoritative C<Allow> union; a matched
OPTIONS reaches this Endpoint. Mounted, standalone, or deliberately broader
Route placement retains the Endpoint's own method outcomes.

A finite Route C<methods> string or arrayref is validated as a restriction of
that same one-time capability snapshot. Use scalar C<< methods => '*' >> only
when the Endpoint should bypass Router method qualification and own all method
dispatch and 405 responses itself.

=head2 Features

=over 4

=item * Automatic method dispatch based on HTTP verb

=item * Plain-text 405 Method Not Allowed, with C<Allow>, for undefined methods
(override C<method_not_allowed> to answer differently)

=item * OPTIONS handling with Allow header

=item * HEAD falls back to GET if not defined

=back

=head1 HTTP METHODS

Define any of these async methods to handle requests:

    async sub get { my ($self, $request) = @_; ... }
    async sub post { my ($self, $request) = @_; ... }
    async sub put { my ($self, $request) = @_; ... }
    async sub patch { my ($self, $request) = @_; ... }
    async sub delete { my ($self, $request) = @_; ... }
    async sub head { my ($self, $request) = @_; ... }
    async sub options { my ($self, $request) = @_; ... }
    async sub query { my ($self, $request) = @_; ... }

Each receives:

=over 4

=item C<$self> - The endpoint instance

=item C<$request> - A L<PAGI::Request>, or the class L<PAGI::Middleware::RequestClass> set

=back

Use C<$request> for request data and return an application value, such as a
L<PAGI::Response>, a Pages application, C<as_app_object>-wrapped native coderef, or
another app object.

B<Handler contract:> Every HTTP handler MUST return an application value
(immediately or through a Future). Returning nothing or a scalar/hash value
causes C<dispatch> to croak. C<dispatch> returns that exact application
without sending it; C<to_app> delegates its invocation through the shared
application contract.

The selected handler runs inline. Immediate results are normalized with
C<Future-E<gt>wrap>, but blocking synchronous work still blocks the event-loop
thread. A returned object's C<to_app> is invoked once for that request.

B<A fresh object per request by default:> named at a route with
C<endpoint>, the class is built with C<new> for each request, so C<$self>
belongs to that one request and may keep its state.

A class that shares one object across every request says so with
C<BUILD_APP> (L<PAGI::Endpoint>). B<Do not store per-request state on
C<$self>> of a shared object: request-scoped data on it would leak between
concurrent requests. Keep configuration and long-lived services on such an
object, and request-scoped data on C<$request> or scope-bound helpers.

=head1 INSTANCE METHODS

=head2 to_app

    my $app = endpoint('MyEndpoint')->to_app;

Returns a PAGI-compatible async coderef that can be used directly with
PAGI::Server or composed with middleware. C<to_app> is an instance
method: called on an endpoint object, it retains that exact object for
the returned application's lifetime. Calling it on a class name dies
with "to_app is called on an endpoint object; use
endpoint('MyEndpoint') or MyEndpoint->new->to_app". To place a class at
a route, name it with L<PAGI::Routing/endpoint>, which builds it as the
class decides (L<PAGI::Endpoint>).

The returned application accepts HTTP scopes only. Other protocol scopes are
rejected before a handler runs or either I/O callback is invoked.

=head2 dispatch

    my $application = await $endpoint->dispatch($request);

Dispatches the request to the appropriate HTTP method handler and returns the
resulting application without emitting it. Called automatically by C<to_app>.

=head2 method_not_allowed

    sub method_not_allowed ($self, $request, @allowed) {
        return response('JSON', { detail => 'Not supported here' }, status => 405);
    }

Answers a request for a method this endpoint does not implement. The default
is a plain-text C<405 Method Not Allowed>. Override it to answer differently;
it receives the request and the allowed methods, and may return a Response,
an application, or a Future of one. The endpoint sets the response's one
C<Allow> field to the allowed methods, replacing any the answer carries.

At a Route without C<< methods => '*' >> the Router answers methods this
endpoint does not advertise, from C<allowed_methods>, so this hook runs
only when the endpoint is mounted or routed with C<< methods => '*' >>.

=head2 allowed_methods

    my @methods = $endpoint->allowed_methods;

Returns list of HTTP methods this endpoint handles. Works on the class as
well as an instance; a per-request endpoint's Route asks the class.

=head1 SEE ALSO

L<PAGI::Endpoint::WebSocket>, L<PAGI::Endpoint::SSE>, L<PAGI::Request>,
L<PAGI::Response>

=cut
