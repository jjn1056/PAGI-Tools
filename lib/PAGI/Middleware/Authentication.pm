package PAGI::Middleware::Authentication;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(blessed);
use PAGI::Auth qw(auth);
use PAGI::Request::_Factory ();
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
        my $request = PAGI::Request::_Factory::request_for_scope($scope, \&_no_body);
        my $returned = ref($backend) eq 'CODE'
            ? $backend->($request)
            : $backend->authenticate($request);
        my @results = await Future->wrap($returned);
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
select responses; applications make that decision explicitly. Backend and
downstream exceptions and failed Futures propagate normally. No
C<authenticated> scope is granted implicitly. An application can read the
result with C<auth($scope)> or C<auth($request)>; absence is a configuration
error rather than an implicit guest.

Other scope types are passed through unchanged without constructing a request
or invoking the backend.

=cut
