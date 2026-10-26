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
    my $catch = exists $config->{catch}
        ? PAGI::Middleware::ErrorHandler::_catch_table($config->{catch}, 'Authentication') : undef;
    PAGI::Utils::_reject_unknown_options('Authentication', $config,
        qw(backend catch));
    # What answers the backend's HTTP errors when no ErrorHandler is around
    # this middleware, or always with a catch table: its entries, else the
    # built-in answers a Compose application gives a route's HTTP error.
    $self->{own_catch} = $catch ? 1 : 0;
    $self->{answers} = PAGI::Middleware::ErrorHandler->_new_compose_failsafe(
        ($catch ? (catch => $catch) : ()),
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
            # What the backend throws is handled as the same value thrown
            # from a route is, as Starlette's middleware answers its
            # backend's AuthenticationError with its on_error: by this
            # middleware's catch table, else by the ErrorHandler this request
            # is inside (on a route) or with the built-in answers -- an entry
            # for its class, anything with status_code, a page. Answered from
            # 500 up, or not handled, it is re-raised: a server error.
            # Quiet under an ErrorHandler (on a route): an error re-raised
            # here meets that boundary, which diagnoses a rejected status
            # claim; elsewhere this is the only chance to say why.
            my $outer = $type eq 'http' ? $scope->{'pagi.error_handler'} : undef;
            my $answering = $outer && !$self->{own_catch} ? $outer : $self->{answers};
            my $handled = await $answering->_handle_exception($error, $request, $scope, $receive, $send,
                $outer ? 'quiet' : undef);
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
object implementing C<authenticate>; C<catch> is optional (see L</catch>);
unknown constructor options are errors.
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
C<authenticated> scope is granted implicitly. An application can read the
result with C<auth($scope)> or C<auth($request)>; absence is a configuration
error rather than an implicit guest.

What the backend throws, or fails its Future with, is handled as the same
value thrown from a route is, as Starlette's AuthenticationMiddleware answers
its backend's C<AuthenticationError>: the request goes no further. A
L<PAGI::Exception::HTTP> (or anything with C<status_code>), a value with a
C<catch> entry for its class, or a thrown page is answered; anything else is
a server error. With L</catch>, this middleware's table answers it; without,
on a route inside an L<PAGI::Middleware::ErrorHandler>, that ErrorHandler
does, with its C<catch> entries and C<on_error>; elsewhere -- in Compose's
C<middleware> list, say -- the built-in answer does: an HTTP error's status,
its C<client_message> as plain text, its C<headers> (a 401's
C<WWW-Authenticate>, say). A WebSocket or SSE connection is refused with that
answer. From 500 up it is answered and then re-raised, so the server logs it.
That includes the 400 a
L<PAGI::Request> auth helper throws with C<raise_on_error> when the client
sent a malformed or duplicate C<Authorization> field:

    middleware('Authentication', backend => sub {
        my ($request) = @_;
        my ($user, $password) = $request->basic_auth(raise_on_error => 1);  # 400 if malformed
        return unauth_result() unless defined $user;
        ...
    });

Every error from downstream propagates as it would without this middleware.

=head2 catch

    my %catch = ('PAGI::Exception::HTTP' => sub {
        my ($request, $context) = @_;
        return response('JSON', { error => $context->message },
            status  => $context->status,
            headers => $context->exception->headers);
    });

    compose(
        routes     => [...],
        middleware => [
            middleware('ErrorHandler', catch => \%catch),                        # what the application raises
            middleware('Authentication', backend => $backend, catch => \%catch), # what the backend raises
        ],
    );

How the backend's HTTP errors look. In Compose's C<middleware> list an
ErrorHandler's C<catch> entries never see them: Compose puts its exception
boundary inside the application middleware, as Starlette's
C<exception_handlers> never see an C<AuthenticationMiddleware> error. So the
rule is: ErrorHandler's C<catch> answers what the application raises, and
this middleware answers what its backend raises, with this table -- the
same shape as L<PAGI::Middleware::ErrorHandler/catch>, so one table can serve
both, and an API's 401 is JSON like its 404. Its role is Starlette's
C<on_error>; it is not named C<on_error>, which is ErrorHandler's reporting
hook.

Keys are statuses from 400 to 599 or exact class names; an entry receives
the backend's Request (with no body) and an L<PAGI::ErrorContext>, and
returns a response, as an ErrorHandler entry does. The table is checked when
the middleware is constructed. It answers what the backend throws, wherever
the middleware is placed, before any ErrorHandler around it -- a class key
answers the backend's own error class, as Starlette's C<on_error> answers
C<AuthenticationError> -- and an HTTP error no entry matches gets the
built-in answer. Without C<catch>, the backend's error is answered by the
ErrorHandler this middleware is inside, on a route, and with the built-in
answer elsewhere.

Other scope types are passed through unchanged without constructing a request
or invoking the backend.

=cut
