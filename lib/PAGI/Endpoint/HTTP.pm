package PAGI::Endpoint::HTTP;

use strict;
use warnings;

use Future;
use Future::AsyncAwait;
use Carp qw(croak);
use PAGI::Pages;
use PAGI::Request;
use PAGI::Response;
use PAGI::Response::Empty ();
use PAGI::Utils qw(is_response);

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

# HTTP methods we support
our @HTTP_METHODS = qw(get post put patch delete head options);

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

    my $response;

    # OPTIONS - return allowed methods (auto-respond unless overridden)
    if ($http_method eq 'options' && !$self->can('options')) {
        my $allow = join(', ', $self->allowed_methods);
        $response = PAGI::Response::Empty->new(
            headers => ['Allow' => $allow],
        );
    }
    # HEAD falls back to GET if not explicitly defined
    elsif ($http_method eq 'head' && !$self->can('head') && $self->can('get')) {
        $response = await Future->wrap($self->get($request));
    }
    # Dispatch to the appropriate method handler
    elsif ($self->can($http_method)) {
        $response = await Future->wrap($self->$http_method($request));
    }
    # 405 Method Not Allowed
    else {
        $response = PAGI::Pages->method_not_allowed(
            $request,
            allow => [$self->allowed_methods],
        );
    }

    croak ref($self) . "->$http_method did not return a response"
        unless is_response($response);
    return $response;
}

sub to_app {
    my ($class) = @_;
    my $endpoint = $class->new;    # ONE instance for the app lifetime (singleton)

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $request = PAGI::Request->new($scope, $receive);
        my $response = await $endpoint->dispatch($request);
        await Future->wrap($response->respond($scope, $receive, $send));
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
    use PAGI::Response::Empty ();
    use PAGI::Response::JSON ();

    async sub get {
        my ($self, $request) = @_;
        my $users = get_all_users();
        return PAGI::Response::JSON->new($users);
    }

    async sub post {
        my ($self, $request) = @_;
        my $data = await $request->json;
        my $user = create_user($data);
        return PAGI::Response::JSON->new($user, status => 201);
    }

    async sub delete {
        my ($self, $request) = @_;
        my $id = $request->path_param('id');
        delete_user($id);
        return PAGI::Response::Empty->new(status => 204);
    }

    # Use with PAGI server
    my $app = MyApp::UserAPI->to_app;

=head1 DESCRIPTION

PAGI::Endpoint::HTTP provides a Starlette-inspired class-based approach
to handling HTTP requests. Define methods named after HTTP verbs (get,
post, put, patch, delete, head, options) and the endpoint automatically
dispatches to them.

When no method handler exists, the automatic 405 response uses
L<PAGI::Pages> to negotiate HTML, problem JSON, or plain text from the original
request and retains the endpoint's complete, sorted C<allowed_methods> result
in C<Allow>. Explicit method handlers and an explicit C<options> method remain
authoritative custom-response seams. Automatic OPTIONS retains its existing
empty response with C<Allow>. Endpoint::HTTP has no Pages configuration
surface.

=head2 Features

=over 4

=item * Automatic method dispatch based on HTTP verb

=item * Negotiated 405 Method Not Allowed for undefined methods

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

Each receives:

=over 4

=item C<$self> - The endpoint instance

=item C<$request> - A L<PAGI::Request> instance

=back

Use C<$request> for request data and L<PAGI::Response> for building response
values.

B<Handler contract:> Every HTTP handler MUST return a L<PAGI::Response> value
(immediately or through a Future). Returning nothing (or a non-response value)
causes dispatch to croak. C<dispatch> returns the response without sending it;
C<to_app> is responsible for emitting it with
C<< $response->respond($scope, $receive, $send) >>.

B<Singleton:> C<to_app> creates a single endpoint instance that serves the
entire application lifetime. State stored in C<$self> persists across
requests (within the same worker process).

B<Do not store per-request state on C<$self>> - one instance is shared by
every request (and concurrent requests), so request-scoped data on C<$self>
will leak between them. Keep configuration and long-lived services on
C<$self>; keep request-scoped data on C<$request> or scope-bound helpers.

=head1 CLASS METHODS

=head2 to_app

    my $app = MyEndpoint->to_app;

Returns a PAGI-compatible async coderef that can be used directly
with PAGI::Server or composed with middleware. Creates a single endpoint
instance at construction time; that instance is reused for every request
(singleton).

=head1 INSTANCE METHODS

=head2 dispatch

    my $response = await $endpoint->dispatch($request);

Dispatches the request to the appropriate HTTP method handler and returns the
resulting response without emitting it. Called automatically by C<to_app>.

=head2 allowed_methods

    my @methods = $endpoint->allowed_methods;

Returns list of HTTP methods this endpoint handles.

=head1 SEE ALSO

L<PAGI::Endpoint::WebSocket>, L<PAGI::Endpoint::SSE>, L<PAGI::Request>,
L<PAGI::Response>

=cut
