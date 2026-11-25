package PAGI::Response::Stream;

use v5.24;
use warnings;
use parent 'PAGI::Response';
use Carp ();
use Future;
use Future::AsyncAwait;
use PAGI::Response::Writer;

# Whether trailers follow is worked out before the headers, as the start
# declares it.
sub prepare {
    my ($self, $args) = @_;
    $self->{has_trailers} = $self->prepare_has_trailers($args);
    return $self->SUPER::prepare($args);
}

# Trailers follow if you say so.
sub prepare_has_trailers {
    my ($self, $args) = @_;
    return $args->{has_trailers} ? 1 : 0;
}

# The body is code: an async sub, given the writer.
sub prepare_body {
    my ($self, $args) = @_;
    Carp::croak('body must be code: an async sub given the writer, body => async sub { my ($writer) = @_; ... }')
        unless ref $args->{body} eq 'CODE';
    return $args->{body};
}

# The base's headers, without the derived length: a stream's isn't known.
sub prepare_headers {
    my ($self, $args, %prepared) = @_;
    return $self->SUPER::prepare_headers($args, %prepared, body => undef);
}

# The class of the writer the body is given. A subclass names its own.
sub writer_class { return 'PAGI::Response::Writer' }

# The bytes write_item writes for an item: here, the item as it is. A
# format overrides this.
sub format_item {
    my ($self, $item) = @_;
    return $item;
}

# Serving the stream: the body runs with a writer until it returns, then
# the end goes, and the trailers it returned if declared. The body runs in
# run_until_end, so a client leaving cancels it and nothing more is sent.
# The news of a leave comes later, from the loop, and a body may return
# normally before it arrives; whether the client has gone is read from
# disconnect_reason, which knows at once.
async sub call {
    my ($self, $scope, $receive, $send) = @_;
    my $connection = $scope->{'pagi.connection'};
    return if defined $connection->disconnect_reason;   # gone before we began

    my $writer = $self->writer_class->_new(response => $self, send => $send, connection => $connection);
    my $ok = eval {
        # The body's own Future goes to run_until_end, so a cancel of it is
        # reported; its trailers are what the body returned. A call that
        # resolves with the client still there means the body finished.
        my $body_work;
        await $connection->run_until_end(sub {
            $body_work = Future->call($self->body, $writer);
        });
        await $writer->_end($body_work->get) if $connection->is_connected;
        1;
    };
    my $error = $@;
    # The outcome reports the response, not the body: the client can leave
    # while the ending is still being sent.
    await $writer->_ended(!$ok ? 'failed' : defined $connection->disconnect_reason ? 'disconnected' : 'finished');
    die $error unless $ok;
    return;
}

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::Response::Stream - a response whose body is written as it's made

=head1 SYNOPSIS

    use v5.40;
    use utf8;   # the characters in this file are characters, not bytes
    use Future::AsyncAwait;
    use Future::IO;
    use PAGI::Response::Stream;

    my $app = async sub ($scope, $receive, $send) {
        die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';
        my $response = PAGI::Response::Stream->new(
            content_type => 'text/plain; charset=utf-8',
            body         => async sub ($writer) {
                for my $n (1 .. 3) {
                    await $writer->write_text("Line $n of 3 ✔\n");   # characters, as UTF-8
                    await Future::IO->sleep(1);
                }
            },    # returning ends the stream
        );
        await $response->call($scope, $receive, $send);
    };

    $app;

=head1 DESCRIPTION

A L<PAGI::Response> whose body is code: an async sub, given a
L<PAGI::Response::Writer>, that writes the body a chunk at a time, for a
response whose length isn't known before it starts, or that never ends by
itself (a feed). Like Starlette's C<StreamingResponse>.

C<call> runs the body until it returns, and returning ends the stream: the
last body event goes, then the trailers if you declared them. The start goes
with the first write, so a body that dies before writing anything leaves the
server free to answer with its 500.

A client that leaves cancels the body, at the C<await> it's waiting on: the
Future it was waiting for is cancelled too, and code after that C<await>
never runs. A loop with no C<await> in it isn't stopped until it awaits. A
write is an C<await> too: once the client has gone, the server sends
nothing and settles the write on a later turn of the event loop, after the
news, so a loop whose only waits are writes stops as well. That takes a
server implementing PAGI core 0.6 or later (L<PAGI::Spec>, "Send Completion
Contract"); on an older one, such a loop runs to its end.

F<examples/response/stream.pl> serves each of these: lines as they're made,
a file relayed with its digest and length as trailers, NDJSON, and a feed
that runs until the client leaves, or is given up on.

=head1 CONSTRUCTOR ARGUMENTS

As L<PAGI::Response>'s, with these differences.

=over 4

=item body

Required: an async sub, given the writer. Anything else dies at C<new>.
What it returns is ignored, unless C<has_trailers> is declared: then it's
the trailers.

=item has_trailers

True if trailers follow the body. The start has to say so, so you declare
it here; the body returns them, as a list of name and value pairs.

Trailers carry what's only known once the body has been sent, such as a
checksum of it, or its length. A digest goes in C<Content-Digest>
(RFC 9530), which is made to be sent as a trailer. The length goes in a
field of your own, because Content-Length can't be a trailer (RFC 9110,
6.5.1):

    use Digest::SHA ();

    my $response = PAGI::Response::Stream->new(
        has_trailers => 1,
        body         => async sub ($writer) {
            my ($sha, $length) = (Digest::SHA->new(256), 0);
            while (defined(my $chunk = await $source->next_chunk)) {
                $sha->add($chunk);
                $length += length $chunk;
                await $writer->write($chunk);
            }
            return [
                ['content-digest', 'sha-256=:' . $sha->b64digest . '=:'],
                ['x-body-length',  $length],
            ];
        },
    );

To end early, return early, with the trailers you want sent then. A body
that returns none sends an empty list. On a 204 or 304 the server drops
them, as it drops the body.

=item headers

As L<PAGI::Response>'s, except that no Content-Length is worked out: a
stream's length isn't known. One you give is sent as given.

=back

=head1 METHODS

=head2 call

    await $response->call($scope, $receive, $send);

Runs the body with a new writer, then sends the end. A client that left
before C<call> began: the body never runs and nothing is sent. A body that
dies: C<call> dies with its error, unchanged, and no end goes. Either way,
C<on_close> callbacks run before C<call> returns or dies. If you cancel
C<call>'s Future, nothing after that point runs, C<on_close> included; see
L</TIMING OUT A STREAM>.

=head2 writer_class

    sub writer_class { 'My::Writer' }   # a subclass of PAGI::Response::Writer

The class of the writer the body is given: L<PAGI::Response::Writer> here.
A subclass of Stream names a subclass of the writer to change how writing
works; see L</SUBCLASSING>.

=head2 format_item

    sub format_item ($self, $item) { ...; return $bytes }

The bytes L<PAGI::Response::Writer/write_item> writes for an item: here,
the item as it is. A format overrides it; see L</SUBCLASSING>.

=head2 prepare_body

C<body>, checked to be code.

=head2 prepare_has_trailers

    my $declared = $response->prepare_has_trailers($args);

Whether trailers follow: C<has_trailers>, as true or false. It's worked out
before the headers, and a subclass extends it the way it extends any other
C<prepare_*> step (L<PAGI::Response/prepare>).

=head2 prepare_headers

L<PAGI::Response>'s, without the derived Content-Length.

=head1 HOW A STREAM ENDS

The writer's C<outcome> says, by the time C<on_close> callbacks run:

    How it ended                        outcome       call
    ----------------------------------  ------------  ------------------------------
    the body returned                   finished      returns; the end was sent
    the client left                     disconnected  returns; the body was cancelled
    the body died, or a send it         failed        dies with the error
      awaited failed

After a client leaves, nothing more is sent: no end, and no trailers. A
body that returned is still C<disconnected> when the client leaves while the
end is being sent: the outcome reports the response, not the body.

=head1 UTF-8

A stream sends bytes, as every response does (L<PAGI::Response/UTF-8>), and
the writer has a way in for each kind of value:

    use utf8;
    use Encode ();

    body => async sub ($writer) {
        await $writer->write_text("Grüße, 🌍\n");                    # characters, sent as UTF-8
        await $writer->write(Encode::encode('UTF-8', "Grüße\n"));   # the same, encoded yourself
        await $writer->write($bytes_from_a_file);                   # bytes, as they are
    },

=over 4

=item *

C<write> sends bytes as given. Given characters, it refuses any above 255 at
the send, but the ones below go out as single bytes: C<write("Grüße")> sends
Latin-1, which a UTF-8 client shows as garbage. Use C<write_text> for text.

=item *

C<format_item> returns bytes, so a format encodes there: the NDJSON example
under L</SUBCLASSING> does, with C<< utf8 => 1 >>, and its items are
characters.

=item *

C<pipe_from> relays the source's chunks as bytes, as given.

=item *

Stream adds no charset to the type, as L<PAGI::Response::Text> does: give
one, C<< content_type => 'text/plain; charset=utf-8' >>.

=back

Text from the request, a query string say, arrives as bytes: decode it
before you treat it as characters. F<examples/response/stream.pl> takes a
message from the query string through to C<write_text>.

=head1 TIMING OUT A STREAM

To give up on a stream, end the connection: abort it. To the stream that's
the client leaving, so the body is cancelled and the C<on_close> callbacks
run, with C<disconnected>:

    my $timer = Future::IO->sleep(30)->on_done(sub {
        $scope->{'pagi.connection'}->abort('timed out');
    });
    await $response->call($scope, $receive, $send);
    $timer->cancel;

Cancelling C<call>'s Future instead, with a C<wait_any> against a timer
say, cancels the body too, but stops C<call> where it was waiting, so its
C<on_close> callbacks never run. Nothing in PAGI cancels C<call>; only code
of yours can.

=head1 A BODY THAT RUNS UNTIL THE CLIENT LEAVES

A feed, say. Write it as a loop that waits on a subscription of the body's
own, so a client leaving cancels only its own wait, and clean up in
C<on_close>:

    body => async sub ($writer) {
        my $subscription = $feed->subscribe;
        $writer->on_close(sub ($writer) { $feed->unsubscribe($subscription) });
        await $writer->write("Following the feed\n");   # the client has the headers now
        while (1) {
            my $message = await $subscription->next;
            await $writer->write_text("$message\n");
        }
    },

Don't wait on a Future other requests share: the client leaving cancels
it, for all of them. The body's own subscription is what the cancel should
reach. The same goes for a source given to
L<PAGI::Response::Writer/pipe_from>.

Cleanup is yours to keep short: C<call> waits for it, and a cleanup that
might hang should limit itself, with
C<< Future->wait_any($stopped, Future::IO->sleep(5)) >> for example.
C<defer> and C<finally> blocks in the body run on a cancel too, but both
are still experimental in Perl.

=head1 SUBCLASSING

A format whose body is a run of items overrides C<format_item>, and the body
writes items:

    package NDJSON {
        use v5.40;
        use parent 'PAGI::Response::Stream';
        use JSON::MaybeXS ();

        sub default_content_type { 'application/x-ndjson' }

        sub format_item ($self, $item) {
            return JSON::MaybeXS->new(utf8 => 1, canonical => 1)->encode($item) . "\n";
        }
    }

    my $response = NDJSON->new(body => async sub ($writer) {
        for my $id (1 .. 3) { await $writer->write_item({ id => $id }) }
    });

To change how the body writes, name a writer of your own with
C<writer_class>. Say you want the body to learn the client has gone from
C<write> itself, rather than be cancelled at its next C<await>:

    package Polite::Writer {
        use v5.40;
        use parent 'PAGI::Response::Writer';

        # False once the client has gone, rather than waiting to be cancelled.
        async sub write ($self, $bytes) {
            return 0 if defined $self->connection->disconnect_reason;
            await $self->SUPER::write($bytes);
            return 1;
        }
    }

    package Polite::Stream {
        use v5.40;
        use parent 'PAGI::Response::Stream';
        sub writer_class { 'Polite::Writer' }
    }

For arguments of your own, extend C<prepare> or the step for the argument,
as for any L<PAGI::Response>.

Overlapping writes, made without waiting for each, need a server that sends
events in the order they were made (PAGI::Spec::Www 0.7), and their Futures
kept and awaited together; see L<PAGI::Response::Writer/DESCRIPTION>.

=head1 SEE ALSO

L<PAGI::Response::Writer>, L<PAGI::Response>

=cut
