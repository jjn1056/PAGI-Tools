package PAGI::Middleware;

use strict;
use warnings;
use Future::AsyncAwait;
use Carp qw(croak);

=head1 NAME

PAGI::Middleware - Base class for PAGI middleware

=head1 SYNOPSIS

    # Create a custom middleware
    package My::Middleware;
    use parent 'PAGI::Middleware';

    sub wrap {
        my ($self, $app) = @_;

        return async sub  {
        my ($scope, $receive, $send) = @_;
            # Modify scope for inner app
            my $modified_scope = $self->modify_scope($scope, {
                custom_key => 'custom_value',
            });

            # Call inner app with modified scope
            await $app->($modified_scope, $receive, $send);
        };
    }

    # Use the builder DSL
    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'My::Middleware', option => 'value';
        enable_if { $_[0]->{path} =~ m{^/api/} } 'RateLimit', limit => 100;
        mount '/static' => $static_app;
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware provides a base class for implementing middleware that wraps
PAGI applications. Middleware can modify the request scope, intercept responses,
or perform cross-cutting concerns like logging, authentication, or compression.

=head1 METHODS

=head2 new

    my $middleware = PAGI::Middleware->new(%config);

Create a new middleware instance. Configuration options are stored and
accessible via C<$self-E<gt>{config}>.

=cut

sub new {
    my ($class, %config) = @_;

    my $self = bless {
        config => \%config,
    }, $class;
    $self->_init(\%config);
    return $self;
}

=head2 _init

    $self->_init(\%config);

Hook for subclasses to perform initialization. Called by new().
Default implementation does nothing.

=cut

sub _init {
    my ($self, $config) = @_;

    # Subclasses can override
}

=head2 wrap

    my $wrapped_app = $middleware->wrap($app);

Wrap a PAGI application. Returns a new async sub that handles
the middleware logic. Subclasses MUST override this method.

=cut

sub wrap {
    my ($self, $app) = @_;

    die "Subclass must implement wrap()";
}

=head2 modify_scope

    my $new_scope = $self->modify_scope($scope, \%additions);

Return a new scope -- a shallow copy of C<$scope> with C<%additions> merged in --
B<without mutating the original>. This is the supported way to pass extra data to
inner apps, and the canonical middleware in this distribution use it.

Why copy instead of writing C<< $scope->{key} = ... >> directly? Middleware form a
stack, and the scope you are handed is shared with the layers around you. Mutating
it in place lets your change leak B<upward> to parent and sibling layers (and, for
a long-lived WebSocket scope, persist across every event on the connection).
Copying keeps your additions B<downward only> -- seen by the inner app you call,
invisible to everyone above.

The copy is B<shallow> on purpose. Top-level keys you add are private to the new
scope, but values that are B<references> -- the C<pagi.connection> object, the
lifespan C<state> namespace, the stash -- are shared, so the inner app still sees
the same connection state and shared objects. A deep copy would sever those. One
corollary worth knowing: a plain B<scalar> set as a top-level scope key does not
propagate back to outer layers, so to share mutable state across layers you mutate
B<through a reference> (see L<PAGI::Stash>, and L<PAGI::Middleware::Stash>, which
puts one stash on the scope for every layer below it). The full model -- and why it works
this way -- is in L<PAGI::Building/MIDDLEWARE>.

A L<PAGI::WebSocket> or L<PAGI::SSE> is built once per scope, so an
application builds it inside the innermost middleware, from the scope the
handler receives (see L<PAGI::WebSocket/SUBCLASSING>).

=cut

sub modify_scope {
    my ($self, $scope, $additions) = @_;
    $additions //= {};

    return { %$scope, %$additions };
}

=head2 intercept_send

    my $wrapped_send = $self->intercept_send($send, \&interceptor);

Wrap the $send callback to intercept outgoing events.
The interceptor is called with ($event, $original_send) and should
return a Future.

    my $wrapped_send = $self->intercept_send($send, async sub  {
        my ($event, $original_send) = @_;
        if ($event->{type} eq 'http.response.start') {
            # Send a new event: the one given belongs to whoever built it,
            # who may send the same header list again.
            $event = {
                %$event,
                headers => [ @{ $event->{headers} // [] }, ['x-custom', 'value'] ],
            };
        }
        await $original_send->($event);
    });

To change only headers, L<PAGI::Utils::Middleware/wrap_response_headers> does
the copying and hands you a L<PAGI::Headers> to edit.

=cut

# The scope a refusing application receives when the refusal was caused by
# malformed header data: one that builds a PAGI::Request would croak on the
# pairs that caused it, so a structurally invalid header list is replaced by
# its well-formed Accept pairs. A well-formed one is returned unchanged.
sub _refusal_scope_for_authority_error {
    my ($self, $scope) = @_;
    my $pairs = exists $scope->{headers} ? $scope->{headers} : [];
    my $structurally_valid = ref($pairs) eq 'ARRAY';

    if ($structurally_valid) {
        for my $pair (@$pairs) {
            unless (ref($pair) eq 'ARRAY' && @$pair == 2
                    && defined($pair->[0]) && !ref($pair->[0])
                    && defined($pair->[1]) && !ref($pair->[1])) {
                $structurally_valid = 0;
                last;
            }
        }
    }
    return $scope if $structurally_valid;

    my @accept;
    if (ref($pairs) eq 'ARRAY') {
        for my $pair (@$pairs) {
            next unless ref($pair) eq 'ARRAY' && @$pair == 2
                && defined($pair->[0]) && !ref($pair->[0])
                && defined($pair->[1]) && !ref($pair->[1]);
            my $name = $pair->[0];
            $name =~ tr/A-Z/a-z/;
            push @accept, [$pair->[0], $pair->[1]] if $name eq 'accept';
        }
    }

    my $safe_scope = {
        %$scope,
        headers => \@accept,
    };
    return $safe_scope;
}

sub intercept_send {
    my ($self, $send, $interceptor) = @_;

    return async sub  {
        my ($event) = @_;
        await $interceptor->($event, $send);
    };
}

=head2 buffer_request_body

    my ($body, $final_event) = await $self->buffer_request_body($receive);

Collect all request body chunks into a single string.
Returns the complete body and the final http.request event.

This is the read half of the read-ahead pattern
(L<PAGI::Utils::Middleware/Why this helper exists>): the loop that collects
C<http.request> events until one has no C<more>. It croaks if the client
disconnects mid-body rather than returning the partial body as if it were
complete. A disconnect before any byte arrived returns C<''> with the
C<http.disconnect> event as C<$final_event>: check its C<type> to tell a
client that left from a POST with an empty body.

The body is consumed: an inner app given the same C<$receive> afterwards
receives none of it. Complete the pattern by handing the app a receive that
delivers a body (see L</Reading the request body>). To pass on the same
body, read through L<PAGI::Utils::Middleware/record_receive>:

    my ($reading, $replaying) = record_receive($receive);
    my ($body) = await $self->buffer_request_body($reading);
    ...
    await $app->($scope, $replaying, $send);

To pass on a different one, write the receive yourself, delivering the new
body once and then the client's receive, with a C<Content-Length> to match
(examples/modify-form-post). A middleware that answers the request itself
needs neither.

=cut

async sub buffer_request_body {
    my ($self, $receive) = @_;

    my $body = '';
    my $event;

    while (1) {
        $event = await $receive->();

        if ($event->{type} eq 'http.request') {
            $body .= $event->{body} // '';
            last unless $event->{more};
        } elsif ($event->{type} eq 'http.disconnect') {
            last unless length $body;  # no bytes ever arrived -- an empty body, not a truncation
            croak "Request body incomplete: client disconnected mid-body";
        }
    }

    return ($body, $event);
}

=head2 body_event_is_opaque

    if (PAGI::Middleware::body_event_is_opaque($event)) { ... }

Plain function (not a method -- call it fully qualified). True when
C<$event> is an C<http.response.body> event carrying a defined C<file> or
C<fh> key: an opaque body the server streams directly (from disk, or from
a filehandle) rather than one carried in the event's C<body> string.

Body-buffering middleware (ETag, GZip, ContentLength, and similar) MUST
check this before treating C<< $event->{body} >> as "the whole body" --
an opaque event has no C<body> key at all, so buffering it would silently
throw the real content away. The correct response is to disengage:
forward the opaque event verbatim, without attempting to hash, compress,
or re-frame content it never received.

=cut

sub body_event_is_opaque {
    my ($event) = @_;

    return 0 unless ($event->{type} // '') eq 'http.response.body';
    return (defined $event->{file} || defined $event->{fh}) ? 1 : 0;
}

1;

__END__

=head1 WRITING MIDDLEWARE

Middleware follows the decorator pattern. Each middleware wraps an inner
application and can:

=over 4

=item * Modify the scope before passing to the inner app

=item * Intercept and modify the $send callback

=item * Short-circuit the request (return early without calling inner app)

=item * Perform actions before and after the inner app runs

=back

=head2 Reading the request body

A request body can be received only once. Whoever reads it hands the
application a C<$receive> that delivers a body: given the C<$receive> a
middleware read from, an application that reads the body waits for an
event the client will never send.

To look at the body, or change it as it streams, wrap C<$receive> and give
the application the wrapper. The application reads the body through it, and the
middleware sees each C<http.request> event as it goes past -- to count it,
hash it, or hand on a changed one. This is the pattern Starlette documents
("wrapping the receive ASGI callable allows you to access or modify the HTTP
request body").

    async sub wrap_logged_body_size {
        my ($app) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            return await $app->($scope, $receive, $send) unless $scope->{type} eq 'http';
            my $size = 0;
            my $counting = async sub {
                my $event = await $receive->();
                if ($event->{type} eq 'http.request') {
                    $size += length($event->{body} // '');
                    warn "request body: $size bytes\n" unless $event->{more};
                }
                return $event;
            };
            await $app->($scope, $counting, $send);
        };
    }

A middleware that must refuse on the body does it in the wrapper too: it
throws from the read of the chunk that decides (an
L<PAGI::Exception::HTTP>), so the application's read fails instead of
returning, and answers that itself when nothing was sent yet, as
Starlette's body-size limit does. examples/signed-requests checks a
signature over the body that way. A check made this way runs only as far
as the application reads: a route that reads no body is not checked.
A middleware may also read the whole body before the application runs, and
then hand the application a receive that delivers a body:

=over 4

=item * B<The same body>, after reading it to decide something: read
through L<PAGI::Utils::Middleware/record_receive> and give the application
its replay. It keeps the events (in memory unless you give it a buffer),
delivers them once, and then carries on with the client's receive, so the
application still gets the disconnect.

    my ($reading, $replaying) = record_receive($receive);
    my $form = await PAGI::Request->new($scope, $reading)->form_params;
    return await $self->{refuse}->($scope, $replaying, $send)
        unless defined $form->get('ticket');
    await $app->($scope, $replaying, $send);

=item * B<A different body>, to rewrite a small form, say: write the
receive yourself, delivering the new body once and then the client's
receive, with a C<Content-Length> to match (examples/modify-form-post).

=back

Reading ahead holds the body before the application starts, so the
application cannot stream it as it arrives; wrap the receive instead when
it should. Where this pattern comes from, and the mistakes the usual
hand-written versions make, is in
L<PAGI::Utils::Middleware/Why this helper exists>.
L<PAGI::Tools::Cookbook/Watching or changing the request body> has more.

=head2 Example: Logging Middleware

    package PAGI::Middleware::Logger;
    use parent 'PAGI::Middleware';
    use Future::AsyncAwait;
    use Time::HiRes 'time';

    sub _init {
        my ($self, $config) = @_;

        # Take the destination as a coderef, defaulting to warn, so the caller
        # can route output wherever they keep their logs. This is the shape
        # PAGI::Middleware::AccessLog uses. Middleware that calls warn directly
        # cannot be redirected by the application that installed it.
        $self->{logger} = $config->{logger} // sub { warn @_ };
    }

    sub wrap {
        my ($self, $app) = @_;

        return async sub {
            my ($scope, $receive, $send) = @_;
            my $start = time();
            my $status;

            # Intercept send to capture status
            my $wrapped_send = $self->intercept_send($send, async sub {
                my ($event, $orig_send) = @_;
                if ($event->{type} eq 'http.response.start') {
                    $status = $event->{status};
                }
                await $orig_send->($event);
            });

            # Call inner app
            await $app->($scope, $receive, $wrapped_send);

            # Log after completion
            my $duration = time() - $start;
            $self->{logger}->(sprintf("%s %s %d %.3fs\n",
                $scope->{method}, $scope->{path}, $status // 0, $duration));
        };
    }

=head1 SEE ALSO

L<PAGI::Middleware::Builder> - DSL for composing middleware

=cut
