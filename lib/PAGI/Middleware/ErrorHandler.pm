package PAGI::Middleware::ErrorHandler;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Carp qw(croak);
use Encode qw(encode);
use Future;
use Future::AsyncAwait;
use Scalar::Util 'blessed';
use PAGI::Context;
use PAGI::Utils ();

=head1 NAME

PAGI::Middleware::ErrorHandler - Exception handling middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'ErrorHandler',
            development => 1,
            on_error    => sub  {
        my ($error) = @_; warn "App error: $error" };
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::ErrorHandler catches exceptions thrown by the inner
application and converts them to appropriate HTTP error responses.

=head1 CONFIGURATION

=over 4

=item * development (default: 0)

If true, include stack trace in built-in error responses. This is a static
Boolean and defaults to false; ordinary construction never consults
C<PAGI_ENV>.

=item * on_error (default: undef)

Callback invoked with the original error when an exception is caught. Useful
for logging. Immediate values and Futures are both accepted and awaited.
Callback failures are contained and never replace the application error.

    on_error => sub  {
        my ($error) = @_; $logger->error($error) }

=item * content_type (default: 'text/html')

Content type for error responses. Supported: 'text/html', 'application/json', 'text/plain'

=item * status (default: 500)

HTTP status code for general exceptions.

=item * handler (default: undef)

Optional renderer invoked as C<< $handler->($context, $original_error) >>.
It must return an immediate or Future-backed PAGI response value. The cached
Context response is seeded with the configured or exception-provided status;
an explicit renderer status wins. A custom renderer owns its response content
type and cache policy unchanged.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    croak "unknown ErrorHandler option '_development_resolver'"
        if exists $config->{_development_resolver};

    $self->{development} = $config->{development} // 0;
    $self->{on_error}    = $config->{on_error};
    $self->{content_type} = $config->{content_type} // 'text/html';
    $self->{status}      = $config->{status} // 500;
    $self->{handler}     = $config->{handler};
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
            if ($event->{type} eq 'http.response.start') {
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
            await $self->_report_error($error);

            # If response already started, we can't send error page
            if ($response_started) {
                die $error;
            }

            # Determine status code
            my $status = $self->{status};

            # Check for specific exception types
            if (blessed($error) && $error->can('status_code')) {
                $status = $error->status_code;
            }

            my $context = PAGI::Context->new($scope, $receive, $send);
            $context->response->status($status);

            my $response;
            if ($self->{handler}) {
                my $returned = $self->{handler}->($context, $error);
                $response = await Future->wrap($returned);
                croak 'handler did not return a response'
                    unless PAGI::Utils::is_response($response);
            }
            else {
                my $development = await $self->_development_for_request;
                my ($body, $content_type) =
                    $self->_generate_error_body($error, $status, $development);
                $response = $context->response
                    ->content_type($content_type)
                    ->header('Cache-Control' => 'no-store')
                    ->send_raw($body);
            }

            await Future->wrap($context->respond($response));
        }
    };
}

async sub _report_error {
    my ($self, $error) = @_;
    return unless $self->{on_error};
    eval { await Future->wrap($self->{on_error}->($error)); 1 };
    return;
}

async sub _development_for_request {
    my ($self) = @_;
    return $self->{development} ? 1 : 0
        unless $self->{_development_resolver};

    my $development;
    my $resolved = eval {
        $development = $self->{_development_resolver}->();
        1;
    };
    unless ($resolved) {
        my $resolver_error = $@;
        await $self->_report_error($resolver_error);
        return 0;
    }
    return $development ? 1 : 0;
}

sub _generate_error_body {
    my ($self, $error, $status, $development) = @_;
    $development = $self->{development} ? 1 : 0
        unless defined $development;

    my $error_text = "$error";
    my $content_type = $self->{content_type};

    # Clean up error for display
    my $display_error = $error_text;
    unless ($development) {
        # In production, don't reveal internal details
        $display_error = $self->_status_message($status);
    }

    if ($content_type eq 'application/json') {
        require JSON::MaybeXS;
        my $body = JSON::MaybeXS::encode_json({
            error  => $display_error,
            status => $status,
            ($development ? (stack => $error_text) : ()),
        });
        return ($body, 'application/json');
    }
    elsif ($content_type eq 'text/plain') {
        my $body = "Error $status: $display_error";
        if ($development && $error_text ne $display_error) {
            $body .= "\n\nStack trace:\n$error_text";
        }
        return (encode('UTF-8', $body), 'text/plain; charset=utf-8');
    }
    else {
        # Default to HTML
        my $safe_error = $self->_html_escape($display_error);
        my $safe_stack = $development ? $self->_html_escape($error_text) : '';

        my $body = <<"HTML";
<!DOCTYPE html>
<html>
<head>
    <title>Error $status</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 40px; }
        h1 { color: #c00; }
        .error { background: #fee; padding: 20px; border-radius: 4px; margin: 20px 0; }
        pre { background: #f4f4f4; padding: 15px; overflow-x: auto; border-radius: 4px; }
    </style>
</head>
<body>
    <h1>Error $status</h1>
    <div class="error">$safe_error</div>
HTML

        if ($development && $safe_stack) {
            $body .= "    <h2>Stack Trace</h2>\n    <pre>$safe_stack</pre>\n";
        }

        $body .= "</body>\n</html>\n";

        return (encode('UTF-8', $body), 'text/html; charset=utf-8');
    }
}

sub _html_escape {
    my ($self, $text) = @_;

    $text =~ s/&/&amp;/g;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    $text =~ s/"/&quot;/g;
    return $text;
}

sub _status_message {
    my ($self, $status) = @_;

    my %messages = (
        400 => 'Bad Request',
        401 => 'Unauthorized',
        403 => 'Forbidden',
        404 => 'Not Found',
        405 => 'Method Not Allowed',
        408 => 'Request Timeout',
        413 => 'Payload Too Large',
        429 => 'Too Many Requests',
        500 => 'Internal Server Error',
        502 => 'Bad Gateway',
        503 => 'Service Unavailable',
        504 => 'Gateway Timeout',
    );
    return $messages{$status} // 'Error';
}

1;

__END__

=head1 BOUNDARIES AND DATABASE FAILURES

ErrorHandler is ordinary middleware and uses the same placement rules as the
routing fallbacks. Application middleware provides whole-application policy:

    compose(
        app => $routing,
        middleware => [
            middleware('ErrorHandler',
                handler  => \&site_server_error,
                on_error => \&report_error),
        ],
    )

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
        router     => $api,
        name       => 'v1',
        middleware => [
            middleware('ErrorHandler',
                handler => \&legacy_server_error),
        ],
    )

Unlike Routing::NotFound and Routing::MethodNotAllowed, ErrorHandler is also
useful on a Route: exceptions happen after that Route is selected, while route
exhaustion does not.

If a database call throws or returns a failed Future before response start,
C<on_error> settles before the custom or built-in renderer runs. If the same
failure happens after a streaming start, rendering is no longer safe:
ErrorHandler settles C<on_error>, emits no second start, and rethrows the
original database exception. Put an author ErrorHandler inside request-ID,
access-log, and security middleware when those wrappers must observe the
official 500. Compose keeps its own plain outer ErrorHandler installed as the
last recovery boundary if author policy itself fails.

=head1 EXCEPTION HANDLING

The middleware supports exception objects with a C<status_code> method
to set custom HTTP status codes:

    package My::Exception;
    sub new { bless { status => $_[1], message => $_[2] }, $_[0] }
    sub status_code { $_[0]->{status} }

    # In app:
    die My::Exception->new(404, 'Resource not found');

=head1 NOTES

=over 4

=item * Before response start, C<on_error> settles before the custom or built-in
renderer runs. Built-in HTML, plain-text, and JSON responses are UTF-8 octet
strings with byte-correct C<Content-Length> and C<Cache-Control: no-store>.
Custom renderers control their own content and cache headers.

=item * If the response has already started when an error occurs, no renderer
is invoked and no replacement response is started. The middleware awaits
C<on_error> and then rethrows the original exception so the server can abort
the incomplete response. This intentionally reverses the earlier behavior
that warned and swallowed post-start failures.

=item * In development mode, the full error message and stack trace are
included in the response. In production, only a generic message is shown.

=item * A missing scope type is treated as HTTP. Defined non-HTTP requests
(including WebSocket and SSE) pass through, so errors propagate without
transformation.

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
