package PAGI::Middleware::Authentication;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(blessed);
use PAGI::Auth qw(auth);
use PAGI::Middleware::ErrorHandler ();
use PAGI::Utils::Middleware qw(clone_scope);
use PAGI::Utils ();

sub _init {
    my ($self, $config) = @_;

    croak 'Authentication requires backend'
        unless exists $config->{backend};

    my $backend = $config->{backend};
    croak 'Authentication backend must be a coderef or an object implementing authenticate'
        unless ref($backend) eq 'CODE'
            || (blessed($backend) && $backend->can('authenticate'));

    $self->{backend} = $backend;
    croak "Authentication 'body_buffer' was removed: a backend never reads the body"
        if exists $config->{body_buffer};
    PAGI::Utils::_reject_unknown_options('Authentication', $config,
        qw(backend));
    # The built-in answers a Compose application gives a route's HTTP error,
    # for a backend's when no ErrorHandler is around this middleware.
    $self->{built_in_answers} = PAGI::Middleware::ErrorHandler->_new_compose_failsafe(
        _development_resolver => sub { return PAGI::Utils::is_development() },
    );
}

# The receive behind a backend's Request: reading the body there dies, and
# the message names the backend's line, not PAGI::Request's.
our @CARP_NOT = ('PAGI::Request');
sub _no_body {
    croak 'Authentication backends read headers and cookies, not the body; check a signed body in the handler';
}

sub wrap {
    my ($self, $app) = @_;
    my $backend = $self->{backend};

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $type = $scope->{type} // '';
        unless ($type eq 'http' || $type eq 'websocket' || $type eq 'sse') {
            await $app->($scope, $receive, $send);
            return;
        }

        # The backend reads the request's headers and cookies; the body is
        # the application's, so the backend's Request has none to read.
        my $request = PAGI::Utils::request_for_scope($scope, \&_no_body);
        my @results;
        my $authenticated = eval {
            my $returned = ref($backend) eq 'CODE'
                ? $backend->($request)
                : $backend->authenticate($request);
            @results = await Future->wrap($returned);
            1;
        };
        unless ($authenticated) {
            my $error = $@;
            # An HTTP error the backend throws is the client's answer, as
            # Starlette's middleware answers its backend's
            # AuthenticationError: answered as a route's thrown error is, by
            # the ErrorHandler this request is inside (on a route) or with
            # the built-in answer, then re-raised from 500 up. Anything else
            # is a server error, as before.
            die $error unless blessed($error) && $error->isa('PAGI::Exception::HTTP');
            my $answering = ($type eq 'http' && $scope->{'pagi.error_handler'}) || $self->{built_in_answers};
            my $handled = await $answering->_handle_exception($error, $request, $scope, $receive, $send, 'quiet');
            die $error if !$handled || $handled == 2;
            return;
        }
        croak 'Authentication backend must return one Auth result'
            unless @results == 1;

        my $inner = clone_scope($scope, { 'pagi.auth' => $results[0] });
        auth($inner);
        await $app->($inner, $receive, $send);
        return;
    };
}

1;

__END__

=head1 NAME

PAGI::Middleware::Authentication - install request authentication results

=head1 SYNOPSIS

    use PAGI::Auth qw(unauth_result);
    use PAGI::Tools qw(compose middleware response route);

    my $app = compose(
        routes     => [route('/' => sub { response('Text', 'hello') })],
        middleware => [
            middleware('Authentication', backend => sub {
                my ($request) = @_;
                return unauth_result();
            }),
        ],
    );

C<middleware('Authentication', ...)> also goes in a Router's, Mount's or
Route's C<middleware> list. It constructs the middleware and wraps the
application inside it, which you can do yourself:

    use PAGI::Middleware::Authentication;

    my $wrapped = PAGI::Middleware::Authentication->new(backend => sub {
        my ($request) = @_;
        return unauth_result();
    })->wrap($native_app);

Without Compose, L<PAGI::Middleware::Builder> composes middleware the way
Plack::Builder does.

=head1 DESCRIPTION

Construct with C<new(backend =E<gt> $backend)> and call C<wrap($next)> to get a
native application. C<backend> is required and must be exactly a coderef or an
object implementing C<authenticate>; unknown constructor options are errors.
The same backend is reused across invocations. This middleware constructs one
L<PAGI::Request>, or the class L<PAGI::Middleware::RequestClass> set when that
middleware is listed before this one, for each HTTP, WebSocket, or SSE
invocation. The Request a backend receives has no C<pagi.auth> yet, so a
subclass helper that calls C<auth($request)> must not be used from a backend.
A coderef receives
that Request as its only argument; an object's C<authenticate($request)> receives
it after the normal invocant. Either form must return exactly one completed
L<PAGI::Auth::Result>, directly or through a L<Future>. Bare users, C<undef>,
and response values are errors.
A backend reads what the request carries before its body: headers, cookies,
the query, the session. The body is the application's, and reaches it
untouched: reading it through the backend's Request dies. A request signed
over its body is checked in the handler, which reads the body (as
Starlette's AuthenticationMiddleware hands its backend a connection with no
body; see examples/signed-requests).

The result is installed under C<pagi.auth> in a shallow child scope and the
downstream application always continues. Guest and rejected results do not
select responses; applications make that decision explicitly. No
C<authenticated> scope is granted implicitly.

A L<PAGI::Exception::HTTP> the backend throws, or fails its Future with, is
the client's answer, as Starlette's AuthenticationMiddleware answers its
backend's C<AuthenticationError>: the request goes no further, and the error
is answered as one thrown from a route is. On a route, inside an
L<PAGI::Middleware::ErrorHandler>, that ErrorHandler answers it, with its
C<catch> entries and C<on_error>; elsewhere -- in Compose's C<middleware>
list, say -- with the built-in answer: its status, its C<client_message> as
plain text, its C<headers> (a 401's C<WWW-Authenticate>, say). A WebSocket
or SSE connection is refused with that answer. From 500 up it is answered
and then re-raised, so the server logs it. That includes the 400 a
L<PAGI::Request> auth helper throws with C<raise_on_error> when the client
sent a malformed or duplicate C<Authorization> field:

    middleware('Authentication', backend => sub {
        my ($request) = @_;
        my ($user, $password) = $request->basic_auth(raise_on_error => 1);  # 400 if malformed
        return unauth_result() unless defined $user;
        ...
    });

Anything else the backend throws, and every error from downstream,
propagates as a server error. An application can read the
result with C<auth($scope)> or C<auth($request)>; absence is a configuration
error rather than an implicit guest.

Other scope types are passed through unchanged without constructing a request
or invoking the backend.

=cut
