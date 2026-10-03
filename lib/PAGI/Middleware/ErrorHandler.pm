package PAGI::Middleware::ErrorHandler;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Carp qw(croak);
use Encode qw(encode);
use Future;
use Future::AsyncAwait;
use Scalar::Util 'blessed';
use PAGI::Request;
use PAGI::ErrorContext ();
use PAGI::Utils ();

my %PUBLIC_OPTION = map { $_ => 1 } qw(development on_error status handler);

# Statuses HTTP says must carry a field the built-in answer cannot supply.
my %FIELD_REQUIRED = (
    401 => 'WWW-Authenticate', 405 => 'Allow',
    407 => 'Proxy-Authenticate', 426 => 'Upgrade',
);

=head1 NAME

PAGI::Middleware::ErrorHandler - Exception handling middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'ErrorHandler',
            development => 1,
            on_error    => sub  {
                my ($error, $scope) = @_;
                $tracker->capture($error, path => $scope->{path});
            };
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::ErrorHandler catches exceptions thrown by the inner
application and converts them to HTTP error responses. Without a C<handler>,
the answer is plain text -- the status's reason phrase, or a client error's
C<client_message> -- with C<Cache-Control: no-store>, and in development the
error's text after a blank line (see L<PAGI::ErrorContext/default>).

ErrorHandler converts exceptions into responses; it does not report them.
After the response is complete, the original exception is re-raised so the
server reports it through its own log, as L<PAGI::Spec::Www> "Exceptions after
the terminal event" describes, when the status actually sent is 500 or above:
what the client was sent decides. A 4xx sent is a handled outcome, not an
error. If the handler dies or answers nothing, a last-resort 500 is sent, the
handler's failure is warned, and the original error is re-raised. Use C<on_error> for
reporting of your own, such as an error tracker; see
L<PAGI::Tools::Cookbook/Who reports an application error>.

=head1 CONFIGURATION

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
(C<Upgrade>) -- needs a C<handler>. An exception's C<status_code> outside
400-599, or one of those without a handler, answers 500 with a diagnostic.

=item * handler (default: the built-in answer)

The answer to an error, given the scope with the error as C<pagi.error>; read
it with L<PAGI::ErrorContext>. A coderef is a Request handler: it receives a
L<PAGI::Request> and returns a Response or an application. A returned Response
that set no status of its own is sent with the error's status. An object is an
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
in (C<path_params>, a Request subclass, CSRF's token) are not there, and its
answer does not pass through inner middleware's send wrappers.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    for my $key (keys %$config) {
        croak "unknown ErrorHandler option '$key'"
            unless $PUBLIC_OPTION{$key};
    }

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
    croak "ErrorHandler status $self->{status} must carry "
        . "$FIELD_REQUIRED{$self->{status}}, which the built-in answer cannot "
        . 'supply; a handler is required'
        if $FIELD_REQUIRED{$self->{status}} && !$self->_has_handler;
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

        await $self->_report_error($error, $scope);
        _reraise($error) if $started;

        my $error_scope = {
            %$scope,
            (defined($scope->{type}) ? () : (type => 'http')),
            'pagi.error' => {
                exception   => $error,
                status      => $self->_status_for_error($error),
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
            eval { warn "PAGI ErrorHandler handler failed: $reason\n"; 1 };
            await $self->_send_last_resort($wrapped_send) unless $started;
            _reraise($error);
        }
        # What the client was sent decides whether the server logs it.
        _reraise($error) if $sent_status >= 500;
    };
}

async sub _answer {
    my ($self, $scope, $receive, $send) = @_;
    if (my $app = $self->{handler_app}) {
        return await PAGI::Utils::_await_native($app, $scope, $receive, $send);
    }
    my $context = PAGI::ErrorContext->new($scope);
    my $answer = $context->default;
    if (my $handler = $self->{handler_code}) {
        $answer = await Future->wrap($handler->(PAGI::Request->new($scope, $receive)));
        PAGI::Utils::_validate_app_value($answer,
            'ErrorHandler handler must return a PAGI application:');
        # A Response that set no status of its own answers with the error's.
        $answer->status_try($context->status)
            if blessed($answer) && $answer->isa('PAGI::Response');
    }
    return await PAGI::Utils::invoke_app($answer, $scope, $receive, $send);
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
    return $self->{status} unless $has_status;
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
    if ($FIELD_REQUIRED{$numeric} && !$self->_has_handler) {
        $self->_diagnose_rejected_status(
            "status $claimed must carry $FIELD_REQUIRED{$numeric}, which the built-in answer cannot supply",
        );
        return 500;
    }
    return $numeric;
}

sub _diagnose_rejected_status {
    my ($self, $reason) = @_;
    eval {
        warn "PAGI ErrorHandler rejected exception status_code claim: $reason\n";
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

The middleware supports exception objects with a C<status_code> method. The
claim is called exception-safely and kept when it is an integer from 400 to
599 (and, without a handler, not one of the statuses that need a field the
built-in answer lacks; see C<status>). Throwing, Future-valued,
reference-valued, malformed and out-of-range claims fall back to 500 without
replacing the original exception:

    package My::Exception;
    sub new { bless { status => $_[1], message => $_[2] }, $_[0] }
    sub status_code { $_[0]->{status} }

    # In app:
    die My::Exception->new(404, 'Resource not found');

Whether the exception is re-raised follows the status sent: a 4xx is a
handled outcome; 500 or above, including a claim that fell back to 500, is a
server error and is re-raised after the response.

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

=item * If the handler dies, returns something that is not an application, or
answers without starting a response, the middleware emits one hardcoded UTF-8
plain-text 500 with C<no-store>, warns C<PAGI ErrorHandler handler failed: ...>,
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
