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
use PAGI::Request::_Factory ();
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

PAGI::Middleware::ErrorHandler catches exceptions thrown by the inner
application and converts them to HTTP error responses. Without a C<handler>,
the answer is plain text -- the status's reason phrase, or a client error's
C<client_message> -- with C<Cache-Control: no-store>, and in development the
error's text after a blank line (see L<PAGI::ErrorContext/default>).

A thrown page -- a value with C<to_app> and no C<status_code>, such as a
thrown Response -- whose status is below 400 is not an error: it is sent as
it is. That is how to throw a redirect: C<die response('Redirect', '/login')>.
See L</EXCEPTION HANDLING>.

ErrorHandler converts exceptions into responses; it does not report them.
After the response is complete, the original exception is re-raised so the
server reports it through its own log, as L<PAGI::Spec::Www> "Exceptions after
the terminal event" describes, when the status actually sent is 500 or above:
what the client was sent decides. A 4xx sent is a handled outcome, not an
error. If the handler dies or answers nothing, a last-resort 500 is sent, the
handler's failure is warned, and the original error is re-raised. Use C<on_error> for
reporting of your own, such as an error tracker; see
L<PAGI::Tools::Cookbook/Who reports an application error>.

ErrorHandler sees only what is thrown. A path no route matches, or a method
a matched path does not allow, is not an error: the router answers it with a
plain-text 404 or 405, and the handler never runs. The Router's (or
Compose's) C<http_default> sets the 404; a 405 is changed by a middleware
that rewrites it (see L<PAGI::Routing>).

=head1 CONFIGURATION

An option not listed here dies at construction.

=over 4

=item * development (default: 0)

If true, include safely stringified exception detail in built-in error
responses. This is a static Boolean and defaults to false; ordinary
construction never consults C<PAGI_ENV>.

=item * on_error (default: undef)

Callback invoked as C<< $on_error->($error, $scope) >> when an exception is
caught: the original error, then the request scope, so a reporter can record
the path or a C<pagi.request_id> (present when L<PAGI::Middleware::RequestId> is
installed). Immediate values and Futures are both accepted and awaited.
Callback failures are contained and never replace the application error.

It is for reporting of your own, in addition to the server's: a server error
is still re-raised to the server after rendering (see L</DESCRIPTION>).

    on_error => sub  {
        my ($error, $scope) = @_;
        $tracker->capture($error, request_id => $scope->{'pagi.request_id'});
    }

=item * status (default: 500)

The status for an exception that claims none, from 400 to 599. A status HTTP
says must carry a field the built-in answer cannot supply -- 401
(C<WWW-Authenticate>), 405 (C<Allow>), 407 (C<Proxy-Authenticate>), 426
(C<Upgrade>) -- needs a C<handler>, or an exception whose C<headers> carry
that field. An exception's C<status_code> outside 400-599, or one of those
with neither, answers 500 with a diagnostic.

=item * handler (default: the built-in answer)

The answer to an error, given the scope with the error as C<pagi.error>; read
it with L<PAGI::ErrorContext>. A coderef is a Request handler: it receives a
L<PAGI::Request>, or the class L<PAGI::Middleware::RequestClass> set when that
middleware is listed before this one, and returns a Response or an application.
A returned Response that set no status of its own is sent with the error's
status. An object is an
application; a native C<($scope, $receive, $send)> app is passed as
C<as_app_object($app)>.

    use PAGI::ErrorContext qw(error_context);

    handler => sub {
        my ($request) = @_;
        my $error = error_context($request);
        return $error->default if $error->is_server_error;   # the built-in answer
        return response('JSON', { error => $error->message });
    }

The handler sees the request as this layer sees it: scope keys added further
in (C<path_params>, CSRF's token) are not there, and its
answer does not pass through inner middleware's send wrappers.

=item * catch (default: none)

Answers by status and by exception class, before C<handler>:

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
with the Request a C<handler> gets and the L<PAGI::ErrorContext>, and returns
what a C<handler> returns; a Response that set no status of its own is sent
with the error's status. The entry that answers is, in Starlette's order:

=over 4

=item 1. for an HTTP error (a thrown value whose C<status_code> was accepted,
see L</EXCEPTION HANDLING>), its status;

=item 2. for a blessed value, its class, then its ancestors in method
resolution order;

=item 3. for any other error (a plain C<die>, a claim that was rejected), the
status ErrorHandler gave it (C<status>, 500 by default).

=back

With no entry, C<handler> answers, or the built-in answer. A thrown page or
Response is an answer, not an error, and never reaches C<catch>. An entry for
a status that must carry a field (see C<status>) answers it as a C<handler>
does, and is responsible for the field. An entry that dies or returns
something that is not an application is a handler failure: the last-resort
500, the original error reported and re-raised.

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

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        # Only handle HTTP requests
        if (($scope->{type} // 'http') ne 'http') {
            await Future->wrap($app->($scope, $receive, $send));
            return;
        }

        my ($started, $sent_status) = (0, undef);
        my $wrapped_send = async sub {
            my ($event) = @_;
            if (($event->{type} // '') eq 'http.response.start') {
                $started = 1;
                $sent_status = $event->{status};
            }
            await Future->wrap($send->($event));
        };

        my $completed = eval {
            await Future->wrap($app->($scope, $receive, $wrapped_send));
            1;
        };
        return if $completed;
        my $error = $@;

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

        my ($status, $headers, $http_error) = $self->_status_for_error($error);
        my $error_scope = {
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
        my $answered = eval {
            await $self->_answer($error_scope, $receive, $wrapped_send);
            1;
        };
        my $handler_failure = $answered ? undef : $@;
        if (!$answered || !$started) {
            # The handler failed, or finished without answering: send the
            # last resort if nothing went out, and report the error that
            # started it, not the renderer's.
            my $reason = defined($handler_failure)
                ? "$handler_failure" : "it finished without starting a response\n";
            chomp $reason;
            my $answerer = $error_scope->{'pagi.error'}{answered_by} // 'handler';
            eval { warn "PAGI ErrorHandler $answerer failed: $reason\n"; 1 };
            await $self->_send_last_resort($wrapped_send) unless $started;
            _reraise($error);
        }
        # What the client was sent decides whether the server logs it.
        _reraise($error) if $sent_status >= 500;
    };
}

async sub _answer {
    my ($self, $scope, $receive, $send) = @_;
    my $error = $scope->{'pagi.error'};
    if (my $entry = $self->_catch_entry($error->{exception}, $error->{status}, $error->{http_error})) {
        $error->{answered_by} = 'catch entry';    # names it if it fails
        my $context = PAGI::ErrorContext->new($scope);
        my $answer = await Future->wrap($entry->(
            PAGI::Request::_Factory::request_for_scope($scope, $receive), $context));
        return await _send_answer($answer, $context, 'ErrorHandler catch entry', $scope, $receive, $send);
    }
    if (my $app = $self->{handler_app}) {
        return await Future->wrap($app->($scope, $receive, $send));
    }
    my $context = PAGI::ErrorContext->new($scope);
    if (my $handler = $self->{handler_code}) {
        my $answer = await Future->wrap($handler->(PAGI::Request::_Factory::request_for_scope($scope, $receive)));
        return await _send_answer($answer, $context, 'ErrorHandler handler', $scope, $receive, $send);
    }
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
    my ($self, $exception, $status, $http_error) = @_;
    my $catch = $self->{catch} or return undef;
    return undef if PAGI::ErrorContext::_is_page($exception);
    return $catch->{$status} if $http_error && $catch->{$status};
    if (blessed($exception)) {
        for my $class (@{ mro::get_linear_isa(ref $exception) }) {
            return $catch->{$class} if $catch->{$class};
        }
    }
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
    my ($self, $error) = @_;
    return $self->{status} unless blessed($error);

    my ($has_status, $claimed);
    my $obtained = eval {
        $has_status = $error->can('status_code') ? 1 : 0;
        $claimed = $error->status_code if $has_status;
        1;
    };
    unless ($obtained) {
        $self->_diagnose_rejected_status('status_code accessor failed');
        return 500;
    }
    unless ($has_status) {
        return $self->{status} unless PAGI::ErrorContext::_is_page($error);
        # A page claims its own status; without a usable one it is a 500.
        my $page_status = PAGI::ErrorContext::_page_status($error);
        return $page_status if defined $page_status;
        $self->_diagnose_rejected_status(
            'it is missing or not an integer from 100 to 599',
            "a thrown page's status",
        );
        return 500;
    }
    unless (defined($claimed)) {
        $self->_diagnose_rejected_status('undefined result');
        return 500;
    }
    if (ref($claimed)) {
        $self->_diagnose_rejected_status('reference-valued result');
        return 500;
    }
    unless ($claimed =~ /\A[0-9]+\z/) {
        $self->_diagnose_rejected_status('nonnumeric scalar result');
        return 500;
    }
    my $numeric = 0 + $claimed;
    unless ($numeric >= 400 && $numeric <= 599) {
        $self->_diagnose_rejected_status("status $claimed is outside 400-599");
        return 500;
    }
    # Only the built-in answer sends an exception's headers, so only it needs
    # them sendable: a handler or catch entry answers with empty headers.
    my $answered_elsewhere = $self->_has_handler || $self->_catch_entry($error, $numeric, 1);
    my ($headers, $refused) = _exception_headers($error);
    ($headers, $refused) = ([], undef) if defined $refused && $answered_elsewhere;
    if (defined $refused) {
        $self->_diagnose_rejected_status($refused, 'exception headers');
        return 500;
    }
    my $field = $FIELD_REQUIRED{$numeric};
    if ($field && !$answered_elsewhere
        && !grep { lc($_->[0]) eq lc($field) } @$headers) {
        $self->_diagnose_rejected_status(
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

ErrorHandler is ordinary middleware and uses the same placement rules as every
pure PAGI wrapper. Application middleware provides whole-application policy:

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
selected. Router NONE and PARTIAL are already ordinary 404/405 responses, not
exceptions; customize NONE with Router C<http_default>.

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
swallowed. Put an author ErrorHandler inside request-ID, access-log, and
security middleware when those wrappers must observe the official 500.
Compose keeps its own stock outer ErrorHandler installed as the last recovery
boundary if author policy itself fails.

=head1 EXCEPTION HANDLING

Return a response; throwing is the escape hatch for code far from the
handler. ErrorHandler reads a thrown value by what it can do, never by its
class:

=over 4

=item * B<A value with C<status_code> is an HTTP error.> The claim is called
exception-safely and kept when it is an integer from 400 to 599 (and, without
a handler, not one of the statuses that need a field the built-in answer
lacks, unless its C<headers> carry it; see C<status>). Throwing,
Future-valued, reference-valued, malformed and out-of-range claims fall back
to 500 with a diagnostic, without replacing the original exception. The
built-in answer shows its C<client_message> for a 4xx and sends its
C<headers>, so under it C<headers> that cannot be sent (a wrong shape, a name
that is not an HTTP token, a character above 0xFF, a C<headers> method that
dies) fall back to 500 too. A C<handler>'s or C<catch> entry's answer is its
own and keeps the claimed status whatever the C<headers> are; it reads them
from the exception if it wants them. Its own C<to_app>, if it has one, is never called.
L<PAGI::Exception::HTTP> is the class PAGI-Tools ships:

    die PAGI::Exception::HTTP->new(404, 'Resource not found');

=item * B<A value with no C<status_code> but a C<to_app> is a page>, such as a
thrown L<PAGI::Response>. Its own C<status> decides. Below 400 the page is
sent as it is, with no C<on_error>, no handler and nothing re-raised: a
thrown redirect. If sending it fails, that failure is handled like any other
error. From 400 to 599 it is an error like any other: C<on_error>
is called, the handler sees it, and C<< $error->default >> is the page
itself, so without a handler the page is the answer. A page whose C<status>
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

Whether the exception is re-raised follows the status sent: a 4xx is a
handled outcome; 500 or above, including a claim that fell back to 500, is a
server error and is re-raised after the response. An early answer is never
re-raised.

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

=item * If the handler or a C<catch> entry dies, returns something that is not
an application, or answers without starting a response, the middleware emits
one hardcoded UTF-8 plain-text 500 with C<no-store>, warns C<PAGI ErrorHandler
handler failed: ...> (C<catch entry failed> for an entry),
and re-raises the original exception. That last resort contains no exception
or handler data. A failure while sending it propagates without another
response attempt.

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
