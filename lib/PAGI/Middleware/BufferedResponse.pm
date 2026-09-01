package PAGI::Middleware::BufferedResponse;

use strict;
use warnings;
use Exporter qw(import);
use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use PAGI::Middleware ();

our @EXPORT_OK = qw(buffer_whole_response stream_transform_response);

sub buffer_whole_response {
    my ($app, %opts) = @_;
    croak 'buffer_whole_response requires a coderef app'
        unless ref($app) eq 'CODE';
    my $engage    = $opts{engage} || sub { 1 };
    my $transform = $opts{transform} or croak 'transform is required';

    return async sub {
        my ($scope, $receive, $send) = @_;
        if (($scope->{type} // '') ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        my ($status, $headers, $start_event);
        my @body_parts;
        my $passing        = 0;
        my $terminal_seen  = 0;
        my $terminal_event;   # the app's own event, re-emitted with a new body
        my @after_body;       # events that must not overtake the withheld head

        # Flush the withheld head plus whatever we buffered, as non-terminal
        # chunks, then hand the rest of the response straight through.
        my $flush_as_stream = async sub {
            await $send->({ %$start_event, headers => $headers // [] });
            for my $part (@body_parts) {
                await $send->({ type => 'http.response.body',
                                body => $part, more => 1 });
            }
            @body_parts = ();
            for my $held (@after_body) { await $send->($held) }
            @after_body = ();
            $passing = 1;
        };

        my $wrapped_send = async sub {
            my ($event) = @_;
            my $type = $event->{type} // '';

            if ($passing) { await $send->($event); return }

            if ($type eq 'http.response.start') {
                $status      = $event->{status};
                $start_event = $event;
                # Our own copy: the arrayref belongs to the application, which
                # may build it once and reuse it across requests.
                $headers = [ @{ $event->{headers} // [] } ];
                unless ($engage->($status, $headers, $start_event)) {
                    $passing = 1;
                    await $send->($event);
                }
                return;
            }

            if ($type eq 'http.response.body') {
                # Never invent a start the application did not send.
                return unless defined $status;

                # An opaque (file/fh) body has no string to transform. Flush
                # what we withheld and hand over.
                if (PAGI::Middleware::body_event_is_opaque($event)) {
                    await $flush_as_stream->();
                    await $send->($event);
                    return;
                }

                push @body_parts, $event->{body} // '';

                # `more` defaults to 0, so an omitted `more` is terminal.
                if ($event->{more}) {
                    await $flush_as_stream->();
                    return;
                }
                $terminal_seen  = 1;
                $terminal_event = $event;
                return;
            }

            # Anything else -- trailers, extension events. While the head is
            # withheld these must not overtake it: forwarding a trailers event
            # now would put it on the wire before the http.response.start it
            # belongs to. Hold it and emit it after the head and body, in the
            # order the application sent it.
            push @after_body, $event;
        };

        await $app->($scope, $receive, $wrapped_send);

        return if $passing;
        return unless defined $status;   # nothing withheld, nothing to emit

        # No terminal event arrived, so the application never claimed this
        # response was complete. Emit the head it did produce -- swallowing it
        # would tell every outer observer that no response was ever started --
        # and stop. transform() is deliberately not called, which is what
        # makes completeness-dependent metadata over a partial buffer
        # unrepresentable rather than merely discouraged. See PAGI::Spec::Www,
        # "Application Left a Response Incomplete".
        unless ($terminal_seen) {
            await $send->({ %$start_event, headers => $headers // [] });
            for my $part (@body_parts) {
                await $send->({ type => 'http.response.body',
                                body => $part, more => 1 });
            }
            for my $held (@after_body) { await $send->($held) }
            return;
        }

        my ($out_status, $out_headers, $out_body) =
            $transform->($status, $headers // [], join('', @body_parts));

        # The application's own start event, with only what transform changed.
        await $send->({ %$start_event, status  => $out_status,
                                       headers => $out_headers // [] });

        # Re-emit the application's own terminal event with the transformed
        # body substituted, rather than constructing a fresh one. That keeps
        # the event's native shape -- including an omitted `more`, which
        # defaults to 0 and means the same thing but is not the same event.
        # A middleware should change what it needs to and nothing else.
        await $send->({ %$terminal_event, body => $out_body // '' });
        for my $held (@after_body) { await $send->($held) }
        return;
    };
}

sub stream_transform_response {
    my ($app, %opts) = @_;
    croak 'stream_transform_response requires a coderef app'
        unless ref($app) eq 'CODE';
    my $begin = $opts{begin} or croak 'begin is required';

    return async sub {
        my ($scope, $receive, $send) = @_;
        if (($scope->{type} // '') ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Per-response, so concurrent requests never share transformer state.
        my $xform;
        my ($status, $headers, $start_event);
        my $head_sent = 0;

        my $wrapped_send = async sub {
            my ($event) = @_;
            my $type = $event->{type} // '';

            if ($type eq 'http.response.start') {
                $status      = $event->{status};
                $start_event = $event;
                # Our own copy: the arrayref belongs to the application.
                $headers = [ @{ $event->{headers} // [] } ];
                # Held until the first body event, so begin() can see it. That
                # one event is what tells a transformer whether the response
                # streams, and how large it is when it does not -- neither is
                # knowable from the head alone.
                return;
            }

            if ($type eq 'http.response.body' && !$head_sent) {
                return unless defined $status;   # never invent a start

                $xform = PAGI::Middleware::body_event_is_opaque($event)
                       ? undef                   # nothing to transform
                       : $begin->($status, $headers, $event, $start_event);

                await $send->({ %$start_event, headers => $headers // [] });
                $head_sent = 1;
            }

            if ($type eq 'http.response.body' && $xform) {
                # An opaque body here is a protocol fault: a response's body is
                # inline events or one opaque event, never both, and the server
                # fails this send (PAGI::Spec::Www, "Payload kinds do not mix
                # within a response"). Forward it and let the server reject it.
                #
                # Keep the transformer. An application that ignores the failed
                # send may still recover inline, and those bytes must continue
                # to be encoded -- the head already declared an encoding, so
                # emitting raw bytes after it would produce exactly the corrupt
                # response the rule exists to prevent.
                if (PAGI::Middleware::body_event_is_opaque($event)) {
                    await $send->($event);
                    return;
                }

                my $out = $xform->{chunk}->($event->{body} // '');


                # `more` defaults to 0, so an omitted `more` is terminal.
                if ($event->{more}) {
                    await $send->({ type => 'http.response.body',
                                    body => $out, more => 1 })
                        if length $out;
                    return;
                }

                $out .= $xform->{finish}->();
                $xform = undef;
                await $send->({ %$event, body => $out });
                return;
            }

            await $send->($event);
        };

        await $app->($scope, $receive, $wrapped_send);

        # The application committed a status and then stopped without sending
        # any body event. Emit the head it produced -- swallowing it would
        # tell every outer observer that no response was ever started.
        if (!$head_sent && defined $status) {
            await $send->({ %$start_event, headers => $headers // [] });
        }
        return;
    };
}

1;

__END__

=head1 NAME

PAGI::Middleware::BufferedResponse - safe buffer-and-re-emit for middleware

=head1 SYNOPSIS

    use PAGI::Middleware::BufferedResponse qw(buffer_whole_response);

    sub wrap {
        my ($self, $app) = @_;
        return buffer_whole_response($app,
            engage    => sub { my ($status, $headers) = @_; $status == 200 },
            transform => sub {
                my ($status, $headers, $body) = @_;
                push @$headers, ['ETag', '"' . md5_hex($body) . '"'];
                return ($status, $headers, $body);
            },
        );
    }

=head1 DESCRIPTION

Middleware that computes a response header from the whole body -- an C<ETag>,
a C<Content-Length>, a digest -- must buffer the body before it can emit
anything. That pattern has one dangerous case: the event stream can end
without its terminal event, because the client disconnected or because the
application stopped early. A middleware that synthesizes its header anyway
asserts that the bytes it happened to observe are the complete
representation, which
L<PAGI::Spec::Www/"Application Left a Response Incomplete"> forbids to every
producer, not only to servers.

This helper owns that case. Your C<transform> callback runs B<only> when a
terminal body event was actually received, so a validator over a partial body
is not something you can accidentally write. When the stream ends early, the
helper emits the C<http.response.start> the application produced -- unmodified,
with no computed metadata -- followed by any buffered chunks tagged
C<< more => 1 >>, and no terminal event. The response stays observably
incomplete, and outer observers still see that a response was started.

=head2 buffer_whole_response

    my $wrapped = buffer_whole_response($app, engage => \&engage, transform => \&transform);

=over

=item * C<engage> (optional, defaults to always true)

Called once with C<< ($status, $headers, $start_event) >> when
C<http.response.start> arrives. Return false to pass this response through
untouched. C<$headers> is the helper's own copy, so C<engage> may modify it
freely. C<$start_event> is the application's own event, which carries
commitments that are not headers -- C<< trailers => 1 >> in particular. The
spec requires an intermediary to examine the head before transforming a body
(L<PAGI::Spec::Www/"Application Left a Response Incomplete">), and this is
what it examines.

=item * C<transform> (required)

Called with C<< ($status, $headers, $body) >> and must return the same triple.
Runs only for a response that reached its terminal body event. C<$headers> is
a copy; the application's own arrayref is never modified, so an application
that builds its headers once and reuses them across requests is safe.

=back

Responses that turn out to be streaming (a body event with C<< more => 1 >>)
or opaque (a C<file> or C<fh> body) are flushed and passed through;
C<transform> does not run for them, because there is no whole body to give it.

=head2 stream_transform_response

    my $wrapped = stream_transform_response($app, begin => \&begin);

For a transform that works incrementally and so does not need the whole body --
compression, for instance. Body bytes are transformed and forwarded as they
arrive, rather than buffered.

    return stream_transform_response($app, begin => sub {
        my ($status, $headers, $first_body, $start_event) = @_;
        return undef unless $self->_want_to_encode($status, $headers);
        push @$headers, ['Content-Encoding', 'gzip'];
        my $encoder = My::Encoder->new;      # per response, see below
        return {
            chunk  => sub { $encoder->add($_[0]) },
            finish => sub { $encoder->flush },
        };
    });

=over

=item * C<begin> (required)

Called B<once per response>, with C<< ($status, $headers, $first_body,
$start_event) >>. Return C<undef> to pass this response through untransformed,
or a hashref of C<< { chunk => sub {...}, finish => sub {...} } >> holding this
response's transformer. C<$headers> is the helper's own copy and may be
modified in place; the modified head is emitted immediately after C<begin>
returns.

C<begin> is a B<factory>, not a pair of shared callbacks, because a
transformer usually holds mutable state -- a zlib stream, a digest -- while
C<wrap> runs once and requests are concurrent. Callbacks created at wrap time
would share one transformer across every in-flight response and corrupt all of
them.

=item * C<chunk> / C<finish>

C<chunk> receives each body chunk's bytes and returns the transformed bytes,
emitted with C<< more => 1 >> (nothing is emitted if it returns the empty
string). C<finish> takes no arguments and returns any trailing bytes, appended
to the final chunk, which is emitted with the application's own terminal event.

=back

The head is held until the first body event so C<begin> can see it. That one
event is what tells a transformer whether the response streams, and how large
it is when it does not -- neither is knowable from the head alone, and a size
threshold cannot be applied without it. An application that starts a response
and then stops without sending any body event still has its head emitted.

Unlike L</buffer_whole_response>, this helper never withholds the head beyond
that first event, so it cannot swallow a response. It also cannot decline
after the fact: once the head is emitted the declared transform is committed,
which is why an opaque C<file>/C<fh> body may not follow inline bytes (see
L<PAGI::Spec::Www/"Response Body - C<send> event">, "Payload kinds do not mix
within a response"). Such an event is forwarded so the server can reject it,
and the transformer is kept in case the application recovers inline.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Spec::Www> - "Application Left a Response Incomplete"

=cut
