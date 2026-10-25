package PAGI::Middleware::ErrorHandler;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Carp qw(croak);
use Encode qw(encode);
use Future;
use Future::AsyncAwait;
use Scalar::Util 'blessed';
use mro ();
use PAGI::Routing::HeadBoundary ();
use PAGI::ErrorContext ();
use PAGI::Utils ();

# Statuses HTTP says must carry a field the built-in answer cannot supply.
my %FIELD_REQUIRED = (
    401 => 'WWW-Authenticate', 405 => 'Allow',
    407 => 'Proxy-Authenticate', 426 => 'Upgrade',
);

=head1 NAME

PAGI::Middleware::ErrorHandler - Exception handling middleware

=head1 SYNOPSIS

    use PAGI::Tools qw(compose middleware response route);

    my $app = compose(
        routes     => [route('/' => sub { response('Text', 'hello') })],
        middleware => [
            middleware('ErrorHandler',
                development => 1,
                on_error    => sub {
                    my ($error, $scope) = @_;
                    warn "error at $scope->{path}: $error";
                },
            ),
        ],
    );

C<middleware('ErrorHandler', ...)> also goes in a Router's, Mount's or
Route's C<middleware> list. It constructs the middleware and wraps the
application inside it, which you can do yourself:

    use PAGI::Middleware::ErrorHandler;

    my $wrapped = PAGI::Middleware::ErrorHandler->new(development => 1)
        ->wrap($native_app);

Without Compose, L<PAGI::Middleware::Builder> composes middleware the way
Plack::Builder does.

=head1 DESCRIPTION

PAGI::Middleware::ErrorHandler turns exceptions thrown by the inner
application into HTTP responses, at two boundaries, as Starlette's
C<ExceptionMiddleware> and C<ServerErrorMiddleware> do:

=over 4

=item * B<The exception boundary> handles the errors an application expects:
an HTTP error (a value with C<status_code>, such as L<PAGI::Exception::HTTP>),
a thrown page, or an error that has a C<catch> entry. A C<catch> entry answers
it -- by the HTTP error's status, or by the exception's class or an ancestor
-- or else the built-in answer: the status's reason phrase, or a client
error's C<client_message>, in plain text with C<Cache-Control: no-store>, and
in development the error's text after a blank line (see
L<PAGI::ErrorContext/default>). A thrown page answers as itself. A handled
error is an outcome, not a failure: it is not re-raised, whatever its status.

=item * B<The server-error boundary> answers everything else -- an ordinary
bug, a C<status_code> claim it rejected -- with a C<catch> entry for the
configured C<status>, the C<handler>, or the built-in 500. After the response
it re-raises the original exception, so the server reports it through its
own log, as L<PAGI::Spec::Www> "Exceptions after the terminal event"
describes.

=back

An error a route's handler throws is handled at that route, with the route's
own Request (see C<catch>). C<on_error> runs once for every error either
boundary answers. ErrorHandler converts exceptions into responses; reporting
is the server's, and C<on_error>'s for a tracker of your own: see
L<PAGI::Tools::Cookbook/Who reports an application error>.

A thrown page -- a value with C<to_app> and no C<status_code>, such as a
thrown Response -- whose status is below 400 is not an error: it is sent as
it is. That is how to throw a redirect: C<die response('Redirect', '/login')>.
See L</EXCEPTION HANDLING>.

Placed with C<wrap> -- on a Router, a Mount or a Route, or by hand -- one
ErrorHandler is both boundaries around what follows it. In
L<PAGI::Compose>'s C<middleware> it is split, wherever it is listed: the
exception boundary around the router, inside every application middleware,
and the server-error boundary outside them all. See L</BOUNDARIES AND
DATABASE FAILURES>.

A path no route matches, or a method a matched path does not allow: with
C<catch> entries, a Router inside this ErrorHandler raises them as a 404 HTTP
error and a 405 carrying C<Allow>, as Starlette's router raises
C<HTTPException> inside an application, so an entry for the status or for
C<PAGI::Exception::HTTP> answers them. With no entry for them, the default
answer is the router's own plain-text response, byte for byte. Without
C<catch> entries the router answers them itself. A Router's (or Compose's)
explicit C<http_default> answers a missing path before any entry sees it.

The model is Starlette 1.10.0's:

=over 4

=item * C<starlette/applications.py>, C<build_middleware_stack>:
C<ServerErrorMiddleware> outermost, the user middleware, then
C<ExceptionMiddleware> innermost, around the router.

=item * C<starlette/middleware/errors.py>: the 500 handler gets
C<Request(scope)>, with no receive, and the exception is always re-raised.

=item * C<starlette/middleware/exceptions.py> and
C<starlette/_exception_handler.py>: handlers by status and by class, most
specific class first; C<starlette/routing.py> C<request_response> runs them
at the route with the endpoint's own Request
(C<wrap_app_handling_exceptions>).

=item * C<starlette/routing.py>: the router raises C<HTTPException(404)> and
C<HTTPException(405)> with C<Allow> only C<if "app" in scope>, inside an
application; otherwise it sends plain responses.

=back

=head1 CONFIGURATION

An option not listed here dies at construction.

=over 4

=item * development (default: 0)

If true, include safely stringified exception detail in built-in error
responses. This is a static Boolean and defaults to false; ordinary
construction never consults C<PAGI_ENV>.

=item * on_error (default: undef)

Callback invoked as C<< $on_error->($error, $scope) >> once for every error
ErrorHandler answers, handled or not: the original error, then the request
scope, so a reporter can record the path or a C<pagi.request_id> (present
when L<PAGI::Middleware::RequestId> wraps this ErrorHandler; in Compose, when
it wraps the compiled application). Immediate values and Futures are both
accepted and awaited. Callback failures are contained and never replace the
application error.

It is for reporting of your own, in addition to the server's: an unhandled
error is still re-raised to the server after rendering (see
L</DESCRIPTION>).

    on_error => sub  {
        my ($error, $scope) = @_;
        $tracker->capture($error, request_id => $scope->{'pagi.request_id'});
    }

=item * status (default: 500)

The status for an exception that claims none, from 400 to 599. A status HTTP
says must carry a field the built-in answer cannot supply -- 401
(C<WWW-Authenticate>), 405 (C<Allow>), 407 (C<Proxy-Authenticate>), 426
(C<Upgrade>) -- needs a C<catch> entry that answers it, or an exception whose
C<headers> carry that field. An exception's C<status_code> outside 400-599, or one of those
with neither, answers 500 with a diagnostic.

=item * handler (default: the built-in answer)

The answer to an unhandled error -- an HTTP error or a thrown page never
reaches it -- given the scope with the error as C<pagi.error>; read it with
L<PAGI::ErrorContext>. A coderef is a Request handler: it receives a
L<PAGI::Request> (or the class L<PAGI::Middleware::RequestClass> set, when
that middleware wraps this one; in Compose it never does, as the handler is
outside every application middleware), and returns a Response or an
application.
A returned Response that set no status of its own is sent with the error's
status. An object is an
application; a native C<($scope, $receive, $send)> app is passed as
C<as_app_object($app)>.

    use PAGI::ErrorContext qw(error_context);

    handler => sub {
        my ($request) = @_;
        my $error = error_context($request);
        return $error->default if $error->detail;   # development: the built-in page
        return response('HTML', '<h1>Something went wrong</h1>', status => $error->status);
    }

The handler sees the request as this layer sees it: scope keys added further
in (C<path_params>, a session, CSRF's token, a C<pagi.request_id>) are not
there, and its answer does not pass through inner middleware's send wrappers.
In Compose that is every application middleware: middleware that must cover
the 500 wraps the compiled application instead (see
L<PAGI::Tools::Cookbook/Compose Safety and Application Error Policy>).

The handler's Request has no body to read: the body was the application's,
which may have read it before it failed, and on a real server reading it
again would wait for an event that never comes. So C<body>, C<form_params>,
C<json> and the rest die at once, naming the handler's line -- as
Starlette's C<ServerErrorMiddleware> hands its handler C<Request(scope)>,
with no receive. Headers, cookies, the query and the method read as usual.
The same holds for a C<catch> entry's Request, except at a route (see
C<catch>). An application given as the handler gets the C<$receive> this
layer was given, and owns what it does with it.

=item * catch (default: none)

The errors the application expects, answered by status and by exception
class:

    catch => {
        404 => sub { response('JSON', { error => 'not found' }) },
        'MyApp::Conflict' => sub {
            my ($request, $error) = @_;
            response('JSON', { error => $error->exception->reason }, status => 409);
        },
        500 => sub { response('Text', 'Sorry.') },
    }

A key that is an integer from 400 to 599 is a status; any other key is an
exact package name (no leading C<+>: nothing is loaded). An entry is called
with a Request and the L<PAGI::ErrorContext>, and returns what a C<handler>
returns; a Response that set no status of its own is sent with the error's
status. An entry answers in full: an HTTP error's C<headers> (the C<Allow>
of a routing 405, a C<Retry-After>) are sent only if it passes them on, as
C<< headers => $error->exception->headers >>, as a Starlette exception
handler replaces the default one that sends them.

An entry answering an error a route's handler threw gets that route's own
Request, as Starlette's C<request_response> hands an exception handler the
endpoint's: the form the route read, its C<path_param>s, and the scope keys
of middleware inside the ErrorHandler. This covers the endpoint's lifecycle
-- a coderef route's handler, an L<PAGI::Endpoint::HTTP> method, and a
builder that receives a Request -- which goes beyond Starlette, whose
C<HTTPEndpoint> runs without that wrapper, so the three behave alike here.
An error raised anywhere else (an endpoint's C<new>, a middleware, the
router) gets a Request built from the scope, with no body. The entry that
answers is, in Starlette's order:

=over 4

=item 1. for an HTTP error (a thrown value whose C<status_code> was accepted,
see L</EXCEPTION HANDLING>), its status;

=item 2. for a blessed value, its class, then its ancestors in method
resolution order;

=item 3. for any other error (a plain C<die>, a claim that was rejected), the
status ErrorHandler gave it (C<status>, 500 by default): that entry answers
at the server-error boundary, in C<handler>'s place, and the error is still
re-raised.

=back

With no entry, an HTTP error gets the built-in answer, and anything else
C<handler> or the built-in 500. A thrown page or Response is an answer, not
an error, and never reaches C<catch>. An entry for a status that must carry a
field (see C<status>) is responsible for the field. An entry that dies, or
returns something that is not an application, fails as itself: its failure
goes on outward as the error -- to the server-error boundary, which answers
and re-raises it -- and one warning names the error it was answering
(C<PAGI ErrorHandler catch entry failed while answering "...": ...>).

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{development} = $config->{development} // 0;
    $self->{on_error}    = $config->{on_error};
    $self->{status}      = $config->{status} // 500;
    croak 'ErrorHandler status must be an integer from 400 to 599'
        unless $self->{status} =~ /\A[45][0-9][0-9]\z/;
    if (exists $config->{handler}) {
        my $handler = $config->{handler};
        PAGI::Utils::_validate_app_value($handler, 'ErrorHandler handler', 'Request handler');
        # A bare coderef is a Request handler, as at a Route; an object is an
        # application, invoked with the scope that carries pagi.error.
        if (ref($handler) eq 'CODE') { $self->{handler_code} = $handler }
        else                         { $self->{handler_app} = PAGI::Utils::to_app($handler) }
    }
    $self->{catch} = _catch_table($config->{catch}) if exists $config->{catch};
    croak "ErrorHandler status $self->{status} must carry "
        . "$FIELD_REQUIRED{$self->{status}}, which the built-in answer cannot "
        . 'supply; a handler is required'
        if $FIELD_REQUIRED{$self->{status}} && !$self->_has_handler
            && !($self->{catch} && $self->{catch}{$self->{status}});
    PAGI::Utils::_reject_unknown_options('ErrorHandler', $config,
        qw(catch development handler on_error status));
}

# The catch table, checked: each key a status from 400 to 599 or an exact
# package name, each entry a code reference. Returns a copy.
sub _catch_table {
    my ($catch) = @_;
    croak 'ErrorHandler catch must be a hash reference of status or class => code'
        unless ref($catch) eq 'HASH';
    my %table;
    for my $key (sort keys %$catch) {
        unless ($key =~ /\A[45][0-9][0-9]\z/ || $key =~ /\A[A-Za-z_]\w*(?:::\w+)*\z/) {
            my $hint = $key =~ /\A\+([A-Za-z_]\w*(?:::\w+)*)\z/
                ? "; a class name is exact, so write '$1'" : '';
            croak "ErrorHandler catch key '$key' is neither a status from 400 to 599 nor a package name$hint";
        }
        croak "ErrorHandler catch entry for '$key' must be a code reference"
            unless ref($catch->{$key}) eq 'CODE';
        $table{$key} = $catch->{$key};
    }
    return \%table;
}

sub _has_handler { $_[0]{handler_code} || $_[0]{handler_app} ? 1 : 0 }

sub _new_compose_failsafe {
    my ($class, %config) = @_;
    my $resolver = delete $config{_development_resolver};
    my $self = $class->new(%config);
    $self->{_development_resolver} = $resolver;
    return $self;
}

# Two boundaries, as Starlette's application stack has: the exception
# boundary, directly around the application, handles an expected error; the
# server-error boundary, around that, answers anything else and always
# rethrows it (PAGI::Middleware::ErrorHandler, "TWO BOUNDARIES").
# Placed locally, both boundaries run in one frame: an error the exception
# boundary does not handle goes on to the server-error boundary as itself,
# never through a Future between them (which could not carry every value).
sub wrap {
    my ($self, $app) = @_;
    return $self->_wrap_server_errors($app, 1);
}

# The exception boundary. It publishes this ErrorHandler in the scope it hands
# inward, so a route adapter can handle its own error with its own Request
# (pagi.error_handler, internal), and handles what reaches it here with a
# Request that has no body: the application below may have read it.
sub _wrap_exceptions {
    my ($self, $app) = @_;

    return async sub {
        my ($scope, $receive, $send) = @_;
        if (($scope->{type} // 'http') ne 'http') {
            await Future->wrap($app->($scope, $receive, $send));
            return;
        }
        my $inner = $self->_publishing_scope($scope);
        my $started = 0;
        my $watching = async sub {
            my ($event) = @_;
            $started = 1 if ($event->{type} // '') eq 'http.response.start';
            await Future->wrap($send->($event));
        };
        my $completed = eval {
            await Future->wrap($app->($inner, $receive, $watching));
            1;
        };
        return if $completed;
        my $error = $@;
        # After the response started nothing more can be answered: the
        # server-error boundary reports it.
        _reraise($error) if $started;
        my $handled = await $self->_handle_exception($error, undef, $inner, $receive, $watching);
        _reraise($error) unless $handled;
        return;
    };
}

# The scope handed inward, carrying this ErrorHandler as pagi.error_handler
# for the route adapters and the router -- only when it has catch entries, the
# only thing there is to look up at a route. One without (the default, or a
# handler-only one) answers what reaches it here, with built-in answers that
# need no route Request.
sub _publishing_scope {
    my ($self, $scope) = @_;
    return $scope unless $self->{catch} && %{ $self->{catch} };
    return $self->modify_scope($scope, { 'pagi.error_handler' => $self });
}

# Handles an expected error with $request (a route's own; undef for one with
# no body, built from the error's scope): a catch entry for an HTTP error's
# status or for the exception's class (or an ancestor), else the built-in
# answer to an HTTP error or a thrown page. Reports it to on_error, answers it,
# and returns true; the error ends there, whatever the answer's status. Any
# other error returns false, unreported, for the server-error boundary. An
# entry's own failure propagates.
async sub _handle_exception {
    my ($self, $error, $request, $scope, $receive, $send, $quiet) = @_;
    # A thrown page answers as itself when its status is 400 or more; one
    # below 400 (a redirect) is an answer the server-error boundary sends,
    # and one without a usable status is an unhandled error.
    my $page_status = PAGI::ErrorContext::_is_page($error)
        ? PAGI::ErrorContext::_page_status($error) : undef;
    return 0 if defined($page_status) && $page_status < 400;
    my ($status, $headers, $http_error) = $self->_status_for_error($error, $quiet);
    my $entry = $self->_catch_entry($error, $status, $http_error, 'exceptions');
    return 0 unless $entry || $http_error || defined $page_status;

    await $self->_report_error($error, $scope);
    my $error_scope = await $self->_error_scope($scope, $error, $status, $headers, $http_error);
    # Answered outside a Router's HEAD boundary (a routing miss under a bare
    # wrap, say), a HEAD answer must still send no body.
    ($error_scope, $send) = PAGI::Routing::HeadBoundary->prepare($error_scope, $send);
    my $context = PAGI::ErrorContext->new($error_scope);
    my $answered = eval {
        if ($entry) {
            $request //= PAGI::Utils::request_for_scope($error_scope, \&_no_body);
            my $answer = await Future->wrap($entry->($request, $context));
            await _send_answer($answer, $context, 'ErrorHandler catch entry', $error_scope, $receive, $send);
        }
        else {
            await PAGI::Utils::invoke_app($context->default, $error_scope, $receive, $send);
        }
        1;
    };
    unless ($answered) {
        my $failure = $@;    # before the warn's own eval resets $@
        _warn_displaced($entry ? 'catch entry' : 'built-in answer', $error, $failure);
        _reraise($failure);
    }
    return 1;
}

# An answer's own failure goes outward as itself, and the error it was
# answering would leave the server log: one line names both. Perl has no
# exception chaining (Python's __context__ prints both), so this line is the
# record. It goes to warn, ErrorHandler's diagnostic channel (pagi-server's
# --error-log captures it), not on_error, which already had the original.
sub _warn_displaced {
    my ($answerer, $original, $failure) = @_;
    eval {
        my ($was, $now) = map { _describe_error($_) } $original, $failure;
        warn "PAGI ErrorHandler $answerer failed while answering \"$was\": $now\n";
        1;
    };
    return;
}

# An error as one line of text; one whose stringification dies is named by
# its class.
sub _describe_error {
    my ($error) = @_;
    my $text = eval { "$error" };
    $text = ref($error) || 'an error' unless defined $text;
    chomp $text;
    return $text;
}

# Runs a route's work -- $run->($send), returning a Future -- so that an error
# it throws is handled at the route with the route's own $request (spec D2):
# a coderef route, an Endpoint method, a builder given a Request. Called on
# the ErrorHandler the scope carries as pagi.error_handler. Returns
# (1, $result) when the work completed, (0) when its error was handled and
# answered; an error it does not handle, or one after the response started,
# is rethrown unchanged for the boundaries outside.
async sub _run_at_route {
    my ($self, $request, $scope, $receive, $send, $run) = @_;
    my $started = 0;
    my $watched = async sub {
        my ($event) = @_;
        $started = 1 if ($event->{type} // '') eq 'http.response.start';
        await Future->wrap($send->($event));
    };
    my $result;
    my $completed = eval {
        $result = await Future->wrap($run->($watched));
        1;
    };
    return (1, $result) if $completed;
    my $error = $@;
    _reraise($error) if $started;
    my $handled = await $self->_handle_exception($error, $request, $scope, $receive, $watched, 'quiet');
    _reraise($error) unless $handled;
    return (0);
}

# The scope an answer is given: this one, with the error as pagi.error.
async sub _error_scope {
    my ($self, $scope, $error, $status, $headers, $http_error) = @_;
    return {
        %$scope,
        (defined($scope->{type}) ? () : (type => 'http')),
        'pagi.error' => {
            exception   => $error,
            status      => $status,
            headers     => $headers // [],
            http_error  => $http_error ? 1 : 0,
            development => await $self->_development_for_request,
        },
    };
}

# The server-error boundary: an error the exception boundary did not handle
# is answered by catch for the configured status, handler, or the built-in
# answer, and then always rethrown, so the server logs it -- as Starlette's
# ServerErrorMiddleware re-raises after its handler answers.
# With $with_exceptions (a local placement), it is also the exception
# boundary: it publishes this ErrorHandler inward and first tries to handle
# the error; one it does not handle, or an entry's own failure, goes on here.
sub _wrap_server_errors {
    my ($self, $app, $with_exceptions) = @_;

    return async sub {
        my ($scope, $receive, $send) = @_;
        if (($scope->{type} // 'http') ne 'http') {
            await Future->wrap($app->($scope, $receive, $send));
            return;
        }

        my $started = 0;
        my $wrapped_send = async sub {
            my ($event) = @_;
            $started = 1 if ($event->{type} // '') eq 'http.response.start';
            await Future->wrap($send->($event));
        };

        my $inner = $with_exceptions ? $self->_publishing_scope($scope) : $scope;
        my $completed = eval {
            await Future->wrap($app->($inner, $receive, $wrapped_send));
            1;
        };
        return if $completed;
        my $error = $@;

        if ($with_exceptions && !$started) {
            my $handled;
            my $tried = eval {
                $handled = await $self->_handle_exception($error, undef, $inner, $receive, $wrapped_send);
                1;
            };
            return if $tried && $handled;
            $error = $@ unless $tried;    # the entry's own failure, from here on
        }

        # A thrown page with a status below 400 (a redirect, say) is an
        # answer, not an error: it is sent as it is and nothing is reported.
        # If sending it fails, that failure is the error from here on.
        if (!$started && PAGI::ErrorContext::_is_page($error)) {
            my $page_status = PAGI::ErrorContext::_page_status($error);
            if (defined($page_status) && $page_status < 400) {
                my $answered = eval {
                    await PAGI::Utils::invoke_app($error, $scope, $receive, $wrapped_send);
                    1;
                };
                return if $answered;
                $error = $@;
            }
        }

        await $self->_report_error($error, $scope);
        _reraise($error) if $started;

        my $error_scope = await $self->_error_scope($scope, $error, $self->{status}, [], 0);
        # A HEAD answer sends no body, inside a HEAD boundary or not.
        ($error_scope, $wrapped_send) = PAGI::Routing::HeadBoundary->prepare($error_scope, $wrapped_send);
        my $answered = eval {
            await $self->_answer_server_error($error_scope, $receive, $wrapped_send);
            1;
        };
        # The answer's own failure goes outward as itself, as Starlette lets a
        # failing handler's exception escape: the next ErrorHandler out
        # answers it, or the server does. One line names the error it was
        # answering, which would otherwise leave the server log.
        unless ($answered) {
            my $failure = $@;    # before the warn's own eval resets $@
            _warn_displaced($error_scope->{'pagi.error'}{answered_by} // 'handler', $error, $failure);
            _reraise($failure);
        }
        unless ($started) {
            # It finished without answering: the last resort, and the error
            # that started it.
            my $answerer = $error_scope->{'pagi.error'}{answered_by} // 'handler';
            eval { warn "PAGI ErrorHandler $answerer failed: it finished without starting a response\n"; 1 };
            await $self->_send_last_resort($wrapped_send);
        }
        _reraise($error);
    };
}

# The receive behind a handler's or catch entry's Request: the body was the
# application's, and on a real server reading it again would wait for an
# event that never comes, so reading it dies at once -- as Starlette's
# ServerErrorMiddleware hands its handler a Request with no receive. The
# message names the handler's line, not PAGI::Request's.
our @CARP_NOT = ('PAGI::Request');
sub _no_body {
    croak "ErrorHandler handlers read the request's headers, not its body: the body was the application's";
}

# An unhandled error's answer: catch for the configured status, handler, or
# the built-in answer, each with a Request that has no body.
async sub _answer_server_error {
    my ($self, $scope, $receive, $send) = @_;
    my $error = $scope->{'pagi.error'};
    if (my $entry = $self->{catch} && $self->{catch}{ $error->{status} }) {
        $error->{answered_by} = 'catch entry';    # names it if it fails
        my $context = PAGI::ErrorContext->new($scope);
        my $answer = await Future->wrap($entry->(
            PAGI::Utils::request_for_scope($scope, \&_no_body), $context));
        return await _send_answer($answer, $context, 'ErrorHandler catch entry', $scope, $receive, $send);
    }
    if (my $app = $self->{handler_app}) {
        return await Future->wrap($app->($scope, $receive, $send));
    }
    my $context = PAGI::ErrorContext->new($scope);
    if (my $handler = $self->{handler_code}) {
        my $answer = await Future->wrap($handler->(PAGI::Utils::request_for_scope($scope, \&_no_body)));
        return await _send_answer($answer, $context, 'ErrorHandler handler', $scope, $receive, $send);
    }
    $error->{answered_by} = 'built-in answer';
    return await PAGI::Utils::invoke_app($context->default, $scope, $receive, $send);
}

# Sends what a handler or a catch entry answered. A Response that set no
# status of its own answers with the error's, set on a copy of the response
# start: the Response itself may be shared, and must not keep this error's
# status for the next one.
async sub _send_answer {
    my ($answer, $context, $label, $scope, $receive, $send) = @_;
    PAGI::Utils::_validate_app_value($answer, "$label must return a PAGI application:");
    if (blessed($answer) && $answer->isa('PAGI::Response') && !$answer->has_status) {
        my ($status, $inner) = ($context->status, $send);
        $send = async sub {
            my ($event) = @_;
            $event = { %$event, status => $status }
                if ($event->{type} // '') eq 'http.response.start';
            await Future->wrap($inner->($event));
        };
    }
    return await PAGI::Utils::invoke_app($answer, $scope, $receive, $send);
}

# Starlette's order: an HTTP error's status, then the exception's class and
# its ancestors in method resolution order, then the status any other error
# was given. A thrown page or Response is an answer, not an error, and never
# reaches catch.
sub _catch_entry {
    my ($self, $exception, $status, $http_error, $exceptions_only) = @_;
    my $catch = $self->{catch} or return undef;
    return undef if PAGI::ErrorContext::_is_page($exception);
    # The server-error status (500 by default) belongs to the server-error
    # boundary, as Starlette moves a 500 handler to ServerErrorMiddleware: an
    # HTTP error with that status gets the built-in HTTP answer.
    my $status_entry = $exceptions_only && $status == $self->{status} ? undef : $catch->{$status};
    return $status_entry if $http_error && $status_entry;
    if (blessed($exception)) {
        for my $class (@{ mro::get_linear_isa(ref $exception) }) {
            return $catch->{$class} if $catch->{$class};
        }
    }
    return undef if $exceptions_only;    # a plain error's status is the server-error boundary's
    return $catch->{$status} if !$http_error && $catch->{$status};
    return undef;
}

# A failed Future must carry a true exception, and Future tests it for
# truth, so an object whose overloads throw or report false cannot travel.
# Such an object is replaced by a safe message rather than letting its
# overload replace the error with an unrelated one.
sub _reraise {
    my ($error) = @_;
    my $usable = eval { $error ? 1 : 0 };
    die $error if $usable;
    die "PAGI ErrorHandler: the application raised an exception that cannot be used as a value\n";
}

async sub _report_error {
    my ($self, $error, $scope) = @_;
    return unless $self->{on_error};
    eval { await Future->wrap($self->{on_error}->($error, $scope)); 1 };
    return;
}

async sub _development_for_request {
    my ($self) = @_;
    return $self->{development} ? 1 : 0
        unless $self->{_development_resolver};

    my $development;
    my $resolved = eval {
        $development = await Future->wrap(
            $self->{_development_resolver}->(),
        );
        1;
    };
    unless ($resolved) {
        # A configuration problem in ErrorHandler itself, not the application's
        # error, so it is a diagnostic like a rejected status claim.
        chomp(my $reason = $@);
        eval {
            warn "PAGI ErrorHandler could not resolve development mode: $reason\n";
            1;
        };
        return 0;
    }
    return $development ? 1 : 0;
}

sub _status_for_error {
    my ($self, $error, $quiet) = @_;
    # Quiet at a route: the error may go on to a boundary, which diagnoses it.
    my $diagnose = $quiet ? sub { } : sub { $self->_diagnose_rejected_status(@_) };
    return $self->{status} unless blessed($error);

    my ($has_status, $claimed);
    my $obtained = eval {
        $has_status = $error->can('status_code') ? 1 : 0;
        $claimed = $error->status_code if $has_status;
        1;
    };
    unless ($obtained) {
        $diagnose->('status_code accessor failed');
        return 500;
    }
    unless ($has_status) {
        return $self->{status} unless PAGI::ErrorContext::_is_page($error);
        # A page claims its own status; without a usable one it is a 500.
        my $page_status = PAGI::ErrorContext::_page_status($error);
        return $page_status if defined $page_status;
        $diagnose->(
            'it is missing or not an integer from 100 to 599',
            "a thrown page's status",
        );
        return 500;
    }
    unless (defined($claimed)) {
        $diagnose->('undefined result');
        return 500;
    }
    if (ref($claimed)) {
        $diagnose->('reference-valued result');
        return 500;
    }
    unless ($claimed =~ /\A[0-9]+\z/) {
        $diagnose->('nonnumeric scalar result');
        return 500;
    }
    my $numeric = 0 + $claimed;
    unless ($numeric >= 400 && $numeric <= 599) {
        $diagnose->("status $claimed is outside 400-599");
        return 500;
    }
    # Only the built-in answer sends an exception's headers, so only it needs
    # them sendable: a catch entry answers with empty headers. (handler
    # answers only unhandled errors, never an HTTP error.)
    my $answered_elsewhere = $self->_catch_entry($error, $numeric, 1);
    my ($headers, $refused) = _exception_headers($error);
    ($headers, $refused) = ([], undef) if defined $refused && $answered_elsewhere;
    if (defined $refused) {
        $diagnose->($refused, 'exception headers');
        return 500;
    }
    my $field = $FIELD_REQUIRED{$numeric};
    if ($field && !$answered_elsewhere
        && !grep { lc($_->[0]) eq lc($field) } @$headers) {
        $diagnose->(
            "status $claimed must carry $field, which the built-in answer cannot supply",
        );
        return 500;
    }
    return ($numeric, $headers, 1);
}

# The headers an HTTP error carries, from its headers method when it has one:
# (pairs) or (undef, why they cannot be sent).
sub _exception_headers {
    my ($error) = @_;
    my $given;
    my $obtained = eval {
        $given = $error->headers if $error->can('headers');
        1;
    };
    return (undef, 'headers accessor failed') unless $obtained;
    return ([]) unless defined $given;
    return PAGI::Utils::_sendable_headers('exception', $given);
}

# $subject names what was rejected: an exception's status_code claim unless
# given, or a thrown page's own status.
sub _diagnose_rejected_status {
    my ($self, $reason, $subject) = @_;
    $subject //= 'exception status_code claim';
    eval {
        warn "PAGI ErrorHandler rejected $subject: $reason\n";
        1;
    };
    return;
}

async sub _send_last_resort {
    my ($self, $send) = @_;
    my $body = encode('UTF-8', "Internal Server Error\n");
    await Future->wrap($send->({
        type    => 'http.response.start',
        status  => 500,
        headers => [
            ['Content-Type' => 'text/plain; charset=utf-8'],
            ['Content-Length' => length($body)],
            ['Cache-Control' => 'no-store'],
        ],
    }));
    await Future->wrap($send->({
        type => 'http.response.body',
        body => $body,
        more => 0,
    }));
    return;
}

1;

__END__

=head1 BOUNDARIES AND DATABASE FAILURES

ErrorHandler uses the same placement rules as every pure PAGI wrapper, with
one exception: in L<PAGI::Compose>'s C<middleware> the stock ErrorHandler is
split, wherever it is listed, as Starlette builds an application:

  Compose's emergency ErrorHandler (server errors only)
    this ErrorHandler's server-error boundary: handler, on_error, the 500
      the response-completion guard, then the application middleware
        this ErrorHandler's exception boundary: catch, HTTP errors
          the root Router

So an application middleware's error is answered by C<handler>, never by
C<catch>, and nothing an application middleware adds reaches the 500. One
stock ErrorHandler per Compose: a second dies when the application is built
(put section-local ones on a Router, a Mount or a Route). A subclass of
ErrorHandler is not split: it wraps what follows it where it is listed, and
Compose then adds no exception boundary of its own. Application middleware
provides whole-application policy:

    use PAGI::Compose qw(compose);
    use PAGI::Routing qw(middleware mount);

    compose(
        routes => [mount('/' => app => $routing)],
        middleware => [
            middleware('ErrorHandler',
                handler  => \&site_server_error,
                on_error => \&report_error),
        ],
    )

The unnamed root Mount preserves the configured Router's middleware, default,
description, identity, and Resolver. Compose owns a distinct outer root Router
and the application-wide ErrorHandler placement shown here.

Router middleware provides reusable subsystem policy, while a routing-aware
Mount middleware list changes only one mounted occurrence:

    my $api = router(
        routes => \@api_routes,
        middleware => [
            middleware('ErrorHandler',
                handler => \&api_server_error),
        ],
    );

    mount('/api/v1',
        app        => $api,
        name       => 'v1',
        middleware => [
            middleware('ErrorHandler',
                handler => \&legacy_server_error),
        ],
    )

ErrorHandler is also useful on a Route: exceptions happen after that Route is
selected. Router NONE and PARTIAL are 404/405, raised to the nearest
enclosing ErrorHandler that has C<catch> entries, otherwise answered by the
Router in plain text; an explicit C<http_default> answers NONE itself.

If a database call throws or returns a failed Future before response start,
C<on_error> settles before the handler or the built-in answer runs, and once
the 500 is complete the database exception is re-raised for the server to log.
When ErrorHandlers are nested, the outer one sees the inner one's complete
500 as a started response and re-raises in turn, so an C<on_error> configured
on each of them runs for the same error. If the same
failure happens after a streaming start but B<before> the response reaches a
legal terminal state, rendering is no longer safe: ErrorHandler settles
C<on_error>, emits no second start, and rethrows the original database
exception, which forces an abnormal closure (disconnect reason
C<server_error>, C<on_disconnect> fires) since the response was left
incomplete. If instead the failure happens B<after> the response has already
reached a legal terminal state, nothing on the wire was corrupted: the
already-complete response stands as-is (C<on_complete> fires, not
C<on_disconnect>, and with no disconnect reason to report), and ErrorHandler
still settles C<on_error> and rethrows so the exception is not silently
swallowed. When request-ID, access-log and security middleware must observe
the official 500, they wrap the ErrorHandler; in Compose, they wrap the
compiled application:

    my $app = PAGI::Middleware::RequestId->new->wrap($compose->to_app);

Compose keeps its own stock outer ErrorHandler installed as the last recovery
boundary if author policy itself fails.

=head1 EXCEPTION HANDLING

Return a response; throwing is the escape hatch for code far from the
handler. ErrorHandler reads a thrown value by what it can do, never by its
class:

=over 4

=item * B<A value with C<status_code> is an HTTP error.> The claim is called
exception-safely and kept when it is an integer from 400 to 599 (and, for the
built-in answer, not one of the statuses that need a field the built-in
answer lacks, unless its C<headers> carry it; see C<status>). Throwing,
Future-valued, reference-valued, malformed and out-of-range claims fall back
to 500 with a diagnostic, without replacing the original exception. The
built-in answer shows its C<client_message> for a 4xx and sends its
C<headers>, so under it C<headers> that cannot be sent (a wrong shape, a name
that is not an HTTP token, a character above 0xFF, a C<headers> method that
dies) fall back to 500 too. A C<catch> entry's answer is its own and keeps
the claimed status whatever the C<headers> are; it reads them from the
exception if it wants them. Its own C<to_app>, if it has one, is never called.
L<PAGI::Exception::HTTP> is the class PAGI-Tools ships:

    die PAGI::Exception::HTTP->new(404, 'Resource not found');

=item * B<A value with no C<status_code> but a C<to_app> is a page>, such as a
thrown L<PAGI::Response>. Its own C<status> decides. Below 400 the page is
sent as it is, with no C<on_error>, no handler and nothing re-raised: a
thrown redirect. If sending it fails, that failure is handled like any other
error. From 400 to 599 it is a handled error: C<on_error> is called and the
page is the answer, never C<catch> or C<handler>, and nothing is re-raised. A page whose C<status>
is missing, dies, or is not 100-599 is answered with the built-in 500. A
Response that set no status has status 200, so throwing one sends it as a
200.

=item * B<Anything else> is answered with the C<status> option (500).

=back

Writing your own HTTP error class needs only a C<status_code> method, and
optionally C<client_message>:

    package My::Exception;
    sub new { bless { status => $_[1], message => $_[2] }, $_[0] }
    sub status_code { $_[0]->{status} }
    sub client_message { $_[0]->{message} }

Exception classes written for Plack, such as L<HTTP::Exception> (which uses
C<code>) or ones relying on L<Plack::Middleware::HTTPExceptions>' C<as_psgi>
and C<location>, probably will not work as intended: they become a 500 unless
they implement C<status_code>, and their PSGI rendering is never used.

Whether the exception is re-raised follows whether it was handled, not the
status sent: an HTTP error, a thrown page and an error a C<catch> entry
answered are handled and not re-raised, whatever their status; anything
else, a claim that fell back to 500 included, is re-raised after the
response. An early answer is never re-raised.

An exception object whose boolean or string overload throws cannot be carried
by a failed Future. After the response, such an exception is re-raised as the
fixed message C<PAGI ErrorHandler: the application raised an exception that
cannot be used as a value>, so the server still records that an error
happened.

=head1 NOTES

=over 4

=item * Before response start, C<on_error> settles before the handler or the
built-in answer runs. The built-in answer is a UTF-8 octet string with a
byte-correct C<Content-Length> and C<Cache-Control: no-store>. A handler
controls its own content and cache headers.

=item * If the handler or a C<catch> entry dies or returns something that is
not an application, its failure goes on outward as itself, as Starlette lets
a failing handler's exception escape: the next ErrorHandler out answers it
(in Compose, the emergency one), or the server does. One warning names the
error it displaced: C<PAGI ErrorHandler handler failed while answering
"...": ...> (C<catch entry> for an entry). If the handler answers without
starting a response, the middleware emits one hardcoded UTF-8 plain-text 500
with C<no-store>, warns C<PAGI ErrorHandler handler failed: it finished
without starting a response>, and re-raises the original exception. That
last resort contains no exception or handler data. A failure while sending it
propagates without another response attempt.

=item * If the response has already started when an error occurs, no handler
is invoked and no replacement response is started. The middleware awaits
C<on_error> and then rethrows the original exception either way, but what
that rethrow does to the connection depends on whether the response had
already reached a legal terminal state:

=over 4

=item * B<Started but incomplete> -- the response was left mid-stream. The
server can't fabricate a legal ending, so it aborts the connection: an
abnormal closure with disconnect reason C<server_error>, not a clean
C<on_complete>.

=item * B<Started and already complete> -- the response had already reached
its terminal state before the exception. Nothing on the wire was corrupted,
so the already-complete response stands and C<on_complete> fires normally
(no disconnect reason to report); the rethrow surfaces the exception to the
caller/logs without touching what was already sent.

=back

This intentionally reverses the earlier behavior that warned and swallowed
post-start failures.

=item * In development mode, a successfully stringified original exception
follows the built-in answer's message. In production the exception is never
stringified for presentation.

=item * A missing scope type is treated as HTTP. Defined non-HTTP requests
(including WebSocket and SSE) pass through, so errors propagate without
transformation.

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::ErrorContext> - the error a handler answers

L<PAGI::Routing>, L<PAGI::Routing::Mount>, and L<PAGI::Compose> - routing,
placement, and application-root ownership

=cut
