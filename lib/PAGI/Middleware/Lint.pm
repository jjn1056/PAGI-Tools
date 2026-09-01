package PAGI::Middleware::Lint;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use PAGI::SendValidation;
use PAGI::Utils qw(request_ended_abnormally);

=head1 NAME

PAGI::Middleware::Lint - Validate PAGI application compliance

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'Lint',
            strict => 1,
            on_warning => sub  {
        my ($msg) = @_; warn "PAGI Lint: $msg\n" };
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::Lint validates that wrapped applications follow the
PAGI specification. It checks for common mistakes and spec violations,
helping developers catch issues early -- in their own development loop,
before a request ever reaches a real server.

=head2 Division of labor

Send-sequencing legality (is this event legal given what has already been
sent?) is delegated entirely to the shared L<PAGI::SendValidation> core --
the same validator L<PAGI::Test::Client> uses. Lint does not keep its own
copy of that state machine. A conforming PAGI server enforces sequencing
unconditionally, on every request, whether or not Lint is in the stack; a
CPAN app author cannot rely on Lint being present in production the way
they can rely on the server.

Lint's own remaining checks are the ones an app-side tool can do that a
server cannot: things that need to see the B<application>'s intent, not
just the wire. It is a diagnostician, not an enforcer:

=over 4

=item * A connection-specific header (C<connection>, C<transfer-encoding>)
set by the app on C<http.response.start> -- legal to send, but a
conforming H1 server strips it and owns response framing itself, so
leaving it in application code is a smell worth flagging.

=item * Trailers declared (C<trailers =E<gt> 1>) but never sent by the
time the app returns -- a friendly diagnostic pointing at the exact rule,
rather than a bare wire-legality error.

=item * Overlapping in-flight sends -- a second C<$send> call issued
before the previous one was awaited. PAGI requires sends to be
sequential; this is unspecified-but-suspicious, not spec-illegal, so it
is always advisory.

=back

In B<non-strict> mode (the default), every check -- Lint's own
complementary checks and the shared core's sequencing checks alike --
warns with application-side context and then forwards the event
unchanged; Lint never blocks a response on its own judgment. In
B<strict> mode, a shared-core sequencing violation is rejected outright:
the illegal event is never forwarded to the wrapped C<$send>, and the
call fails (mirroring what a real server would refuse). Lint's own
complementary checks (connection headers, overlapping sends) always just
warn, in both modes -- they are advisory, never fatal, even in strict
mode.

=head1 CONFIGURATION

=over 4

=item * strict (default: 0)

In strict mode, a shared-core sequencing violation is rejected without
being forwarded, instead of warned about and forwarded. Lint's own
advisory-only checks (connection headers, overlapping sends) still just
warn in strict mode -- see L</Division of labor>.

=item * on_warning (optional)

Callback for lint warnings. Receives warning message.

=item * enabled (default: 1)

Set to false to completely disable lint checks.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{strict} = $config->{strict} // 0;
    $self->{on_warning} = $config->{on_warning};
    $self->{enabled} = $config->{enabled} // 1;
}

my %H1_CONNECTION_SPECIFIC_HEADER = map { $_ => 1 } qw(connection transfer-encoding);

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if (!$self->{enabled}) {
            await $app->($scope, $receive, $send);
            return;
        }

        # Validate scope
        $self->_lint_scope($scope);

        # Shared send-sequencing core -- only wired up for scope types it
        # models a self-contained state machine for without external
        # driving (see PAGI::SendValidation). Lifespan needs enter_phase
        # calls synced to the real driver, which a wrapping middleware
        # doesn't have visibility into, so it is left unwired here.
        my $sv = (($scope->{type} // '') eq 'http')
            ? PAGI::SendValidation->new(scope_type => 'http', extensions => $scope->{extensions})
            : undef;

        my $in_flight = 0;

        # Wrap send to validate outgoing events
        my $wrapped_send = async sub  {
        my ($event) = @_;

            $self->_lint_event($event, $scope->{type});

            if (($event->{type} // '') eq 'websocket.accept' && $scope->{type} ne 'websocket') {
                $self->_warn("websocket.accept sent for non-websocket scope");
            } elsif (($event->{type} // '') eq 'sse.start' && $scope->{type} ne 'sse') {
                $self->_warn("sse.start sent for non-sse scope");
            }

            if (($event->{type} // '') eq 'http.response.start') {
                $self->_lint_response_start($event);
                $self->_lint_connection_headers($event);
            }

            if ($sv) {
                if (my $err = $sv->check($event)) {
                    # non-strict: warn with app context, fall through and
                    # forward anyway (diagnostician, not enforcer). strict:
                    # _warn dies here, so we never reach the forward below
                    # -- the event is rejected, not forwarded.
                    $self->_warn($self->_context_for_send_error($err, $event, $scope->{type}));
                }
            }

            if ($in_flight) {
                $self->_advise(
                    "app issued a new \$send while a previous send was still in flight "
                  . "(not yet awaited). PAGI requires sends to be sequential -- await each "
                  . "\$send->(...) call before issuing the next, or a real server may "
                  . "interleave or reorder bytes on the wire."
                );
            }

            $in_flight = 1;
            await $send->($event);
            $in_flight = 0;
        };

        eval {
            await $app->($scope, $receive, $wrapped_send);
        };
        my $err = $@;

        # If app threw an error, prioritize it but add lint context
        if ($err) {
            my $lint_context = "";
            if ($sv) {
                my $diag = $self->_finalize_diagnosis($sv, $scope);
                if (defined $diag && $diag eq 'disconnected') {
                    my $conn = $scope->{'pagi.connection'};
                    my $reason = $conn->disconnect_reason;
                    $lint_context = "\n(Lint note: the client disconnected ($reason) before the app "
                                   . "finished; an incomplete response here is correct, not a bug)";
                } elsif (defined $diag && $diag eq 'no_start') {
                    $lint_context = "\n(Lint note: app exited without sending http.response.start)";
                } elsif (defined $diag && $diag eq 'no_body') {
                    $lint_context = "\n(Lint note: app exited without sending final http.response.body)";
                } elsif (defined $diag && $diag eq 'trailers') {
                    $lint_context = "\n(Lint note: app exited after declaring trailers but never sending http.response.trailers)";
                }
            }
            die "$err$lint_context";
        }

        # Post-completion checks (only if app completed without throwing)
        if ($sv) {
            my $diag = $self->_finalize_diagnosis($sv, $scope);
            if (defined $diag && $diag eq 'disconnected') {
                my $conn = $scope->{'pagi.connection'};
                my $reason = $conn->disconnect_reason;
                $self->_note(
                    "HTTP app stopped after the client disconnected ($reason); "
                  . "no terminal http.response.body was sent, which is correct."
                );
            } elsif (defined $diag && $diag eq 'no_start') {
                $self->_warn(
                    "HTTP app completed without sending http.response.start. "
                  . "This usually means you forgot to 'await' your \$send calls, "
                  . "or used ->retain for response-affecting work. "
                  . "See PAGI::Tutorial for correct async patterns."
                );
            } elsif (defined $diag && $diag eq 'no_body') {
                $self->_warn(
                    "HTTP app completed without sending final http.response.body (more=0). "
                  . "Did you forget to 'await' the final \$send call?"
                );
            } elsif (defined $diag && $diag eq 'trailers') {
                $self->_warn(
                    "HTTP app completed after declaring trailers (trailers => 1 on "
                  . "http.response.start) but never sent http.response.trailers. Send it "
                  . "before returning, or drop the trailers => 1 declaration if this "
                  . "response doesn't need trailers."
                );
            }
        }
    };
}

sub _lint_scope {
    my ($self, $scope) = @_;

    # Check required scope keys
    unless (defined $scope->{type}) {
        $self->_warn("scope missing required 'type' key");
    }

    if ($scope->{type} eq 'http') {
        my @required = qw(method path scheme);
        for my $key (@required) {
            unless (defined $scope->{$key}) {
                $self->_warn("HTTP scope missing required '$key' key");
            }
        }

        # Check headers format
        if (exists $scope->{headers}) {
            unless (ref $scope->{headers} eq 'ARRAY') {
                $self->_warn("scope headers must be arrayref, got " . ref($scope->{headers}));
            } else {
                for my $h (@{$scope->{headers}}) {
                    unless (ref $h eq 'ARRAY' && @$h == 2) {
                        $self->_warn("scope header must be [name, value] pair");
                    }
                    # Check lowercase header names
                    if ($h->[0] =~ /[A-Z]/) {
                        $self->_warn("header name should be lowercase: '$h->[0]'");
                    }
                }
            }
        }
    }
}

sub _lint_event {
    my ($self, $event, $scope_type) = @_;

    unless (ref $event eq 'HASH') {
        $self->_warn("event must be hashref, got " . ref($event));
        return;
    }

    unless (defined $event->{type}) {
        $self->_warn("event missing required 'type' key");
    }
}

sub _lint_response_start {
    my ($self, $event) = @_;

    unless (defined $event->{status}) {
        $self->_warn("http.response.start missing 'status' key");
    } elsif ($event->{status} !~ /^\d{3}$/) {
        $self->_warn("http.response.start status must be 3-digit code, got '$event->{status}'");
    }

    if (exists $event->{headers}) {
        unless (ref $event->{headers} eq 'ARRAY') {
            $self->_warn("response headers must be arrayref");
        } else {
            for my $h (@{$event->{headers}}) {
                unless (ref $h eq 'ARRAY' && @$h == 2) {
                    $self->_warn("response header must be [name, value] pair");
                }
            }
        }
    }
}

# App-side smell, not a wire violation: a conforming H1 server strips these
# and owns response framing itself (see PAGI::Test::Client's identical
# rule), so leaving them in application code is worth flagging -- but the
# event is legal to send and always gets forwarded regardless of mode; the
# server is what actually enforces the strip.
sub _lint_connection_headers {
    my ($self, $event) = @_;

    return unless ref $event->{headers} eq 'ARRAY';

    for my $h (@{$event->{headers}}) {
        next unless ref $h eq 'ARRAY' && @$h == 2;
        my $name = lc $h->[0];
        next unless $H1_CONNECTION_SPECIFIC_HEADER{$name};

        $self->_advise(
            "app set connection-specific header '$h->[0]' on http.response.start -- PAGI "
          . "response framing (chunking, keep-alive, protocol upgrade) is owned by the "
          . "server, not the app; a conforming server strips this header before writing "
          . "the response, so remove it here rather than relying on it."
        );
    }
}

# Turns a PAGI::SendValidation::Error into application-side guidance: which
# rule, and what to change. The core's bare message is Lint's baseline
# value-add over the server -- restating it verbatim would add nothing.
sub _context_for_send_error {
    my ($self, $err, $event, $scope_type) = @_;

    my $type     = defined $event->{type} ? $event->{type} : '(missing)';
    my $category = $err->category;

    if ($category eq 'malformed') {
        return "app sent a malformed event to \$send (" . $err->message . ") -- check the "
             . "hashref you're passing; every PAGI event needs a 'type' key.";
    }
    if ($category eq 'unknown_type') {
        return "app sent event type '$type', which isn't a recognized PAGI event for a "
             . "'$scope_type' scope (" . $err->message . ") -- check for a typo, or, if "
             . "this belongs to an extension, make sure the scope declares it.";
    }
    if ($category eq 'extension') {
        return $err->message . " -- declare it in the scope's 'extensions' key before "
             . "sending events that require it, or don't send them if it isn't really "
             . "implemented.";
    }
    if ($category eq 'sequence' && $type eq 'http.response.trailers') {
        return "app sent http.response.trailers without declaring trailers on "
             . "http.response.start (trailers => 1) and before the body reached its "
             . "terminal chunk -- declare trailers on the start event if you intend to "
             . "send them, and send http.response.trailers only after the body's "
             . "terminal chunk.";
    }
    return "app sent '$type' out of order (" . $err->message . ") -- check the order your "
         . "app calls \$send in for this response.";
}

# One place that turns $sv->finalize's outcome into which of the four
# post-completion stories applies -- shared by the post-completion warning
# path and the app-threw context note, so they can't drift.
#
# Order matters. $sv->finalize answers WHETHER the response was left
# incomplete; disconnect_reason only answers WHY. Asking why first would
# report a disconnect for a response that was in fact complete -- and an
# application that sends its terminal event after the client is gone is
# exactly the fault this middleware exists to catch, so misreporting it as
# correct silence defeats the purpose. See PAGI::Spec::Www, "Which signal
# answers which question".
sub _finalize_diagnosis {
    my ($self, $sv, $scope) = @_;

    my $err = $sv->finalize;
    return undef unless $err;

    # Incomplete, and the client had already gone: legal silence, not a bug.
    return 'disconnected' if request_ended_abnormally($scope);

    return 'trailers' if $err->message =~ /trailers/;
    return $sv->started ? 'no_body' : 'no_start';
}

sub _warn {
    my ($self, $msg) = @_;

    if ($self->{strict}) {
        die "PAGI Lint Error: $msg\n";
    }

    $self->_advise($msg);
}

# Warns without ever dying, regardless of strict mode -- for Lint's own
# advisory-only checks (connection headers, overlapping sends), which are
# never protocol violations and so are never rejected.
sub _advise {
    my ($self, $msg) = @_;

    if ($self->{on_warning}) {
        $self->{on_warning}->($msg);
    } else {
        warn "PAGI Lint Warning: $msg\n";
    }
}

# Reports without ever dying, regardless of strict mode -- like _advise,
# but for a diagnosis that isn't a smell to maybe fix: it's a true fact
# about correct, spec-required behavior (e.g. an incomplete response
# because the client disconnected) that would otherwise go unreported.
sub _note {
    my ($self, $msg) = @_;

    if ($self->{on_warning}) {
        $self->{on_warning}->($msg);
    } else {
        warn "PAGI Lint Note: $msg\n";
    }
}

1;

__END__

=head1 CHECKS PERFORMED

=head2 Scope Validation

=over 4

=item * Required C<type> key present

=item * HTTP scope has C<method>, C<path>, C<scheme>

=item * Headers are arrayref of [name, value] pairs

=item * Header names are lowercase

=back

=head2 Event Validation

=over 4

=item * Events are hashrefs with C<type> key

=item * C<http.response.start> has C<status>

=item * Send-sequencing legality (event order, duplicates, sends after
completion, trailers legality) is enforced by the shared
L<PAGI::SendValidation> core -- see L</Division of labor>. This is where
C<http.response.body>'s C<more> key is actually interpreted: absent,
false, or a C<file>/C<fh> body all mark a chunk terminal, and a further
body event after that is rejected.

=item * Connection-specific headers (C<connection>, C<transfer-encoding>)
on C<http.response.start> are flagged as an app-side smell (see
L</Division of labor>) -- always forwarded regardless.

=item * Trailers declared (C<trailers =E<gt> 1>) but never sent get a
friendly diagnostic at app return, distinct from the core's bare
"incomplete" error.

=item * Overlapping in-flight sends (a second C<$send> issued before the
previous one was awaited) are flagged, in both strict and non-strict mode.

=back

=head2 Completion Validation

=over 4

=item * HTTP apps send C<http.response.start>

=item * HTTP apps send final C<http.response.body> with C<more=0>

=item * HTTP apps that declared trailers send C<http.response.trailers>
before returning

=item * None of the three checks above are diagnosed when the client
disconnected before the app finished -- see L</Disconnect Reporting>.

=back

=head2 Disconnect Reporting

=over 4

=item * A response left incomplete because the client disconnected
mid-response is never diagnosed as a missing C<http.response.start>, a
missing final C<http.response.body>, or unsent trailers -- the application
is required not to send the terminal event once it knows its client is
gone, so an "incomplete" response here is correct, not a bug.

=item * It is still reported, as its own advisory note naming the
disconnect reason, so the signal isn't lost -- and, like Lint's own
complementary checks (see L</Division of labor>), this note is never
fatal, even in strict mode.

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::Debug> - Development debug panel

L<PAGI::SendValidation> - The shared send-sequencing core this middleware
consumes; read its C<RULES> section for exactly what is and isn't legal.

=cut
