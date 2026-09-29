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
use PAGI::Pages ();
use PAGI::Utils ();

my %PUBLIC_OPTION = map { $_ => 1 } qw(development on_error status handler);

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
application and converts them to appropriate HTTP error responses. Its built-in
renderer delegates to L<PAGI::Pages>, so request C<Accept> fields negotiate
HTML, problem JSON, or text. Custom handlers retain full response ownership.

ErrorHandler converts exceptions into responses; it does not report them.
After the error response for a B<server error> (status 500 or above) is
complete, the original exception is re-raised so the server reports it through
its own log, as L<PAGI::Spec::Www> "Exceptions after the terminal event"
describes. A handled exception whose C<status_code> claims a 4xx status is
rendered and not re-raised: it is a response, not an error. Use C<on_error> for
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
the path or a C<request_id> (present when L<PAGI::Middleware::RequestId> is
installed). Immediate values and Futures are both accepted and awaited.
Callback failures are contained and never replace the application error.

It is for reporting of your own, in addition to the server's: a server error
is still re-raised to the server after rendering (see L</DESCRIPTION>).

    on_error => sub  {
        my ($error, $scope) = @_;
        $tracker->capture($error, request_id => $scope->{request_id});
    }

=item * status (default: 500)

HTTP status code for general exceptions. Without a custom C<handler>, this must
be a registered error that Pages can render without missing mandatory response
facts. Statuses such as 401, 405, 407, and 426 therefore require a handler.

=item * handler (default: undef)

Optional renderer invoked as C<< $handler->($request, $original_error) >>.
It must return an immediate or Future-backed concrete L<PAGI::Response> value.
ErrorHandler applies the configured or exception-provided
status through C<status_try> only after the handler returns; an explicit
renderer status wins. It then emits the value through
the Response application contract. A custom renderer owns its response
content type and cache policy unchanged.

Use the handler seam to force a fixed representation:

    use PAGI::Response qw(problem_response);
    handler => sub {
        my ($request, $error) = @_;
        return problem_response({
            title  => 'Internal Server Error',
            status => 500,
        });
    }

The wrapper may inspect C<$request> or C<$error> when it deliberately chooses
safe response fields. ErrorHandler requires a concrete Response from this
custom renderer; source-free Pages application values belong at Route, Mount,
or Router-default application boundaries instead. Pages does not
consume that callback metadata itself.

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
    $self->{handler}     = $config->{handler};

    unless ($self->{handler}) {
        croak 'ErrorHandler configured status cannot be rendered completely; a handler is required'
            unless $self->_pages_accepts_status($self->{status});
    }
}

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

        my $response_started = 0;

        # Intercept send to track if response has started
        my $wrapped_send = async sub  {
            my ($event) = @_;
            if (($event->{type} // '') eq 'http.response.start') {
                $response_started = 1;
            }
            await Future->wrap($send->($event));
        };

        # Try to run the app, preserving the exact exception value.
        my $error;
        my $completed = eval {
            await Future->wrap($app->($scope, $receive, $wrapped_send));
            1;
        };
        $error = $@ unless $completed;

        # Handle error if one occurred
        unless ($completed) {
            await $self->_report_error($error, $scope);

            # If response already started, we can't send error page
            if ($response_started) {
                _reraise($error);
            }

            my $status = $self->_status_for_error($error);
            my $request_scope = defined($scope->{type})
                ? $scope : { %$scope, type => 'http' };
            my $request = PAGI::Request->new($request_scope, $receive);

            my $response;
            if ($self->{handler}) {
                $response = await Future->wrap(
                    $self->{handler}->($request, $error),
                );
                croak 'handler did not return a PAGI::Response'
                    unless blessed($response)
                        && $response->isa('PAGI::Response');
                $response->status_try($status);
            }
            else {
                my $development = await $self->_development_for_request;
                my @detail;
                if ($development) {
                    my $error_text;
                    my $stringified = eval {
                        $error_text = "$error";
                        1;
                    };
                    @detail = (detail => $error_text) if $stringified;
                }

                my $rendered = eval {
                    $response = PAGI::Pages->status(
                        $status, @detail,
                    );
                    1;
                };
                unless ($rendered) {
                    await $self->_send_last_resort($wrapped_send);
                    _reraise($error) if $status >= 500;
                    return;
                }
            }

            await PAGI::Utils::invoke_app(
                $response,
                $request_scope,
                $receive,
                $wrapped_send,
            );

            # The response is complete. A server error still belongs to the
            # server, which logs it; a handled 4xx exception does not.
            _reraise($error) if $status >= 500;
        }
    };
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

sub _pages_accepts_status {
    my ($self, $status) = @_;
    return eval {
        PAGI::Pages->status($status);
        1;
    } ? 1 : 0;
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
    unless ($numeric >= 100 && $numeric <= 599) {
        $self->_diagnose_rejected_status(
            "status $claimed is outside 100-599",
        );
        return 500;
    }
    unless ($self->{handler} || $self->_pages_accepts_status($claimed)) {
        $self->_diagnose_rejected_status(
            "status $claimed is not a complete registered Pages error",
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
C<on_error> settles before the custom or built-in renderer runs, and once the
500 is complete the database exception is re-raised for the server to log.
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
claim is called exception-safely and, for the built-in renderer, is preserved
only when it names a registered error Pages can render completely. Throwing,
Future-valued, reference-valued, malformed, unknown, non-error, and incomplete
claims fall back to 500 without replacing the original exception:

    package My::Exception;
    sub new { bless { status => $_[1], message => $_[2] }, $_[0] }
    sub status_code { $_[0]->{status} }

    # In app:
    die My::Exception->new(404, 'Resource not found');

A preserved 4xx claim is a handled outcome: the response is sent and the
exception is not re-raised. Any status of 500 or above, including a claim that
fell back to 500, is a server error and is re-raised after the response.

An exception object whose boolean or string overload throws cannot be carried
by a failed Future. After the response, such an exception is re-raised as the
fixed message C<PAGI ErrorHandler: the application raised an exception that
cannot be used as a value>, so the server still records that an error
happened.

=head1 NOTES

=over 4

=item * Before response start, C<on_error> settles before the custom or built-in
renderer runs. Built-in HTML, plain-text, and problem-JSON responses are UTF-8
octet strings with byte-correct C<Content-Length> and
C<Cache-Control: no-store>. Custom renderers control their own content and
cache headers.

=item * If built-in Pages construction fails before response start, the
middleware emits one hardcoded UTF-8 plain-text 500 with C<no-store>. That last
resort contains no exception or renderer data. A failure while sending it
propagates without another response attempt. After it is sent, a server error
is re-raised as after any other error response.

=item * If the response has already started when an error occurs, no renderer
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

=item * In development mode, a successfully stringified original exception is
used as detail. In production, Pages' catalog-safe detail is used and the
exception is never stringified for presentation.

=item * A missing scope type is treated as HTTP. Defined non-HTTP requests
(including WebSocket and SSE) pass through, so errors propagate without
transformation.

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Routing>, L<PAGI::Routing::Mount>, and L<PAGI::Compose> - routing,
placement, and application-root ownership

=cut
