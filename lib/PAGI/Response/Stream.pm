package PAGI::Response::Stream;

use strict;
use warnings;

use Carp qw(croak);
use Scalar::Util qw(blessed);
use Future;
use Future::AsyncAwait;

use parent 'PAGI::Response';
use PAGI::Response::Writer ();

=encoding UTF-8

=head1 NAME

PAGI::Response::Stream - reusable backpressured HTTP streaming response

=head1 SYNOPSIS

    use Future::AsyncAwait;
    use PAGI::Response qw(response);

    my $response = response('Stream',
        async sub {
            my ($writer) = @_;
            await $writer->write("one\n");
            await $writer->write_text("two\n");
        },
        content_type => 'text/plain; charset=utf-8',
    );

    # Or the content is a source: any object with next_chunk.
    package Countdown {
        sub new        { my ($class, $n) = @_; return bless { n => $n }, $class }
        sub next_chunk { my ($self) = @_; return $self->{n} ? $self->{n}-- . "\n" : undef }
    }
    my $countdown = response('Stream', Countdown->new(3),
        on_close     => sub { print STDERR "countdown finished\n" },
        content_type => 'text/plain; charset=utf-8',
    );

=head1 DESCRIPTION

Stream stores response configuration and a producer callback. It creates a
fresh L<PAGI::Response::Writer> for every invocation, sends and awaits the
response start before calling the producer, and sends one terminal empty body
event after normal producer completion.

Cancelling the invocation observer requests
C<< pagi.connection->abort('response cancelled by caller') >> once, including
while response start is pending. The cancellation signal is published before
abort, which may settle a send synchronously. Server send Futures and local
cleanup remain owned; only the Stream's producer is cancelled.

The producer must await each Writer C<write> Future. That Future is the
response-side backpressure contract; Stream does not prefetch chunks or hide
an unbounded queue. Starting a second write before the first settles is an
error. Awaiting the send means the server accepted the event into outbound
processing or finished discarding it after disconnect; it never proves client
delivery.

Stream is an ordinary HTTP response. It is not WebSocket or SSE, has no
receive loop and no reconnection, Last-Event-ID, retry, or keepalive semantics.
A later request receives a fresh Writer and producer invocation.

A request-body source can be relayed without raw PAGI:

    my $input = $request->body_stream(max_bytes => 100 * 1024 * 1024);
    return response('Stream', async sub {
        my ($writer) = @_;
        await $writer->pipe_from($input);
        die 'upload was truncated' if $input->truncated;
    });

A format subclass sets C<default_content_type> and overrides L</format_item>;
its producers then call C<< $writer->write_item($item) >> for each item.
L<PAGI::Response::NDJSON> is the shipped example. Stream owns lifecycle,
disconnect handling, terminal delivery, and cleanup; a format owns only how
one item becomes bytes.

=cut

sub new {
    my ($class, $content, @pairs) = @_;
    # on_close is Stream's own option: taken out before the common options
    # are parsed, and run once however the stream ends.
    my $on_close;
    for (my $i = 0; $i < @pairs - 1; $i += 2) {
        next unless defined $pairs[$i] && !ref($pairs[$i]) && $pairs[$i] eq 'on_close';
        (undef, $on_close) = splice @pairs, $i, 2;
        croak 'Stream on_close must be a code reference' unless ref($on_close) eq 'CODE';
        last;
    }
    my $producer = @_ >= 2 && ref($content) eq 'CODE' ? $content
        : blessed($content) && $content->can('next_chunk') ? $class->_source_producer($content)
        : croak "$class->new requires a producer coderef or a source object with next_chunk";
    if ($on_close) {
        my $inner = $producer;
        $producer = sub {
            my ($writer) = @_;
            $writer->on_close($on_close);
            return $inner->($writer);
        };
    }

    my $self = $class->SUPER::new('', @pairs);
    delete $self->{_body};
    $self->{_producer} = $producer;
    return $self;
}

# A source is pulled one value at a time, each written before the next pull,
# and nothing but next_chunk is called on it. On a format subclass (one with
# its own format_item) each value is an item.
sub _source_producer {
    my ($class, $source) = @_;
    my $items = $class->can('format_item') != \&PAGI::Response::Stream::format_item;
    return async sub {
        my ($writer) = @_;
        return await $writer->pipe_from($source) unless $items;
        while (!$writer->is_disconnected) {
            my $item = await Future->wrap($source->next_chunk);
            last unless defined $item;
            await $writer->write_item($item);
        }
        return;
    };
}

sub is_buffered { return 0 }

sub body {
    croak 'Stream response has no buffered body';
}

sub format_item { return $_[1] }

sub _stream_wire_headers {
    my ($self) = @_;
    return $self->_sendable_header_pairs;
}

sub _stream_delivery_plan {
    my ($self) = @_;
    return {
        producer => $self->{_producer},
        status   => $self->status,
        headers  => $self->_stream_wire_headers,
    };
}

sub _emit {
    my ($self, $scope, $receive, $send) = @_;
    PAGI::Response::_validate_http_triplet($scope, $receive, $send);

    # Check the connection methods this stream will use before anything is
    # sent: the Writer's, and abort for cancellation.
    my $connection = $scope->{'pagi.connection'};
    PAGI::Response::Writer::_check_connection($connection);
    croak 'pagi.connection must provide abort to cancel a streamed response'
        if $connection && !$connection->can('abort');

    my $plan = $self->_stream_delivery_plan;

    my $control = {
        cancel_signal => Future->new,
    };
    my $lifecycle = $self->_run_lifecycle(
        $plan, $scope, $receive, $send, $control->{cancel_signal},
    );
    $control->{lifecycle} = $lifecycle;
    $lifecycle->on_ready(sub {
        my ($ready) = @_;
        delete $control->{lifecycle}
            if $control->{lifecycle} && $control->{lifecycle} == $ready;
    });

    my $observer = $lifecycle->without_cancel;
    my $cancel_signal = $control->{cancel_signal};
    $observer->on_cancel(sub {
        $cancel_signal->done('caller_cancelled')
            unless $cancel_signal->is_ready || $cancel_signal->is_cancelled;
        # Publish first: abort may synchronously settle response.start.
        $scope->{'pagi.connection'}->abort('response cancelled by caller')
            if $scope->{'pagi.connection'};
    });
    return $observer;
}

async sub _run_lifecycle {
    my ($self, $plan, $scope, $receive, $send, $cancel_signal) = @_;

    await Future->wrap($send->({
        type    => 'http.response.start',
        status  => $plan->{status},
        headers => $plan->{headers},
    }));

    my $writer = PAGI::Response::Writer->_new(
        response   => $self,
        send       => $send,
        connection => $scope->{'pagi.connection'},
        transport  => $scope->{'pagi.transport'},
    );
    if ($cancel_signal->is_ready) {
        await $writer->_abort;
        await $writer->_cleanup;
        return;
    }
    if ($writer->is_disconnected) {
        await $writer->_abort;
        await $writer->_cleanup;
        return;
    }

    my $producer_returned;
    my $producer_called = eval {
        $producer_returned = $plan->{producer}->($writer);
        1;
    };
    unless ($producer_called) {
        my $error = $@;
        await $writer->_abort;
        await $writer->_cleanup;
        die $error;
    }

    my $producer = Future->wrap($producer_returned);
    my $producer_outcome = _producer_outcome($producer);
    my $disconnect_outcome = _disconnect_outcome($writer->_disconnect_signal);
    my $cancel_outcome = _cancel_outcome($cancel_signal);
    my $outcome = await Future->wait_any(
        $cancel_outcome,
        $disconnect_outcome,
        $producer_outcome,
    );

    if ($outcome->{kind} eq 'caller_cancelled') {
        my $abort = $writer->_abort;
        $producer->cancel
            if !$producer->is_ready && !$producer->is_cancelled;
        await $abort;
        await $writer->_cleanup;
        return;
    }

    if ($outcome->{kind} eq 'disconnect') {
        await $writer->_abort;
        $producer->cancel
            if !$producer->is_ready && !$producer->is_cancelled;
        await $writer->_cleanup;
        return;
    }

    if ($outcome->{kind} eq 'producer_failed') {
        my $failure = $outcome->{failure};
        my $error = $failure->[0];
        await $writer->_abort;
        await $writer->_cleanup;
        die $error;
    }

    if ($outcome->{kind} eq 'producer_cancelled') {
        await $writer->_abort;
        await $writer->_cleanup;
        die "Stream producer Future was cancelled\n";
    }

    if ($writer->is_disconnected) {
        await $writer->_abort;
        await $writer->_cleanup;
        return;
    }

    my ($closed, $close_error);
    $closed = eval { await $writer->close; 1 };
    $close_error = $@ unless $closed;
    unless ($closed) {
        await $writer->_abort;
        await $writer->_cleanup;
        die $close_error;
    }

    return;
}

sub to_app {
    my ($self) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        await $self->_emit($scope, $receive, $send);
        return;
    };
}

sub _producer_outcome {
    my ($producer) = @_;
    my $outcome = Future->new;
    $producer->on_ready(sub {
        return if $outcome->is_ready || $outcome->is_cancelled;
        if ($producer->is_failed) {
            my @failure = $producer->failure;
            $outcome->done({
                kind    => 'producer_failed',
                failure => \@failure,
            });
        } elsif ($producer->is_cancelled) {
            $outcome->done({ kind => 'producer_cancelled' });
        } else {
            $outcome->done({ kind => 'producer_done' });
        }
    });
    return $outcome;
}

sub _disconnect_outcome {
    my ($signal) = @_;
    my $outcome = Future->new;
    $signal->on_ready(sub {
        my ($ready_signal) = @_;
        return if $outcome->is_ready || $outcome->is_cancelled;
        if ($ready_signal->is_failed) {
            $outcome->fail($ready_signal->failure);
        } elsif ($ready_signal->is_cancelled) {
            $outcome->done({ kind => 'disconnect' });
        } else {
            $outcome->done({ kind => 'disconnect' });
        }
    });
    return $outcome;
}

sub _cancel_outcome {
    my ($signal) = @_;
    my $outcome = Future->new;
    $signal->on_ready(sub {
        my ($ready_signal) = @_;
        return if $outcome->is_ready || $outcome->is_cancelled;
        if ($ready_signal->is_failed) {
            $outcome->fail($ready_signal->failure);
        } else {
            $outcome->done({ kind => 'caller_cancelled' });
        }
    });
    return $outcome;
}

=head1 METHODS

=head2 new

    PAGI::Response::Stream->new($producer, %options)
    PAGI::Response::Stream->new($source, %options)

The first argument is a Writer producer coderef, or a source: an object with
C<next_chunk> (L</Streaming from a source>). C<status>, C<content_type>, and
C<headers> (any shape L<PAGI::Response/new> takes) use the common Response
contract. C<on_close> is Stream's own: a coderef called once however the
stream ends (completion, an error, the client leaving), and waited for if it
returns a Future, as a producer's C<< $writer->on_close >> is. Stream
does not calculate Content-Length; an explicitly supplied value is retained as
the application's delivery promise.

=head2 to_app

Returns the reusable native HTTP application over this exact Stream object.
At an existing triplet boundary, invoke the Stream through
L<PAGI::Utils/invoke_app>. Disconnect observation uses only the synchronous
C<pagi.connection> capability. Stream never starts a competing receive loop.
Cancelling the returned Future cancels only the caller's observer and signals
the retained Stream lifecycle to stop producer-owned work. That lifecycle
continues to await any active server-owned send before running cleanup.

=head2 is_buffered

Returns false.

=head2 body

Croaks with C<Stream response has no buffered body>. Stream output belongs to
each invocation's producer and is never represented by one buffered scalar.

=head2 format_item

    sub format_item { my ($self, $item) = @_; ...; return $bytes }

Turns one item given to L<PAGI::Response::Writer/write_item> into the bytes
that are written. The default returns the item unchanged, so on a plain Stream
C<write_item> is the same as C<write>. A format subclass overrides it (see
L<PAGI::Response::NDJSON>). It must not change the response: one response
value may serve several requests at once.

It must return encoded bytes, as every PAGI body is. C<write> refuses a string
holding wide characters, but it cannot tell a Latin-1 string from binary data,
so encode text yourself (for example with C<Encode::encode('UTF-8', $text)>).

=head2 Streaming from a source

    my $response = response('Stream', $source, on_close => sub { ... });

A source is any object with C<next_chunk>, which returns the next value,
immediately or as a Future, or C<undef> at the end. Stream pulls one value,
writes it, and only then pulls the next, so a slow client slows the source:
the backpressure L<PAGI::Response::Writer/pipe_from> has. It stops pulling
once the client has disconnected. On a plain Stream each value is bytes (an
empty string is skipped); on a format subclass, such as
L<PAGI::Response::NDJSON>, each value is an item, written with
C<write_item>. A C<next_chunk> that dies or fails is a producer error.

Stream calls nothing but C<next_chunk> on a source: a source may be an object
the response does not own, such as a feed other requests share, so a C<close>
of its own is never called. Cleanup is the C<on_close> option.

=head1 DISCONNECTS AND FAILURES

When C<pagi.connection> is present, disconnects are observed through one
private signal built from its required C<on_disconnect> facet. Stream waits for
any active PAGI send,
cancels only remaining producer-owned work, runs local cleanup, omits terminal
success, and completes as the server-owned connection outcome. Genuine
producer and send errors run the same cleanup but remain application failures;
disconnect never manufactures or arbitrates a Writer failure.

Under PAGI 0.002007, a send already pending when disconnect occurs resolves only
after connection state has changed. Writer therefore awaits the send and then
checks C<pagi.connection>. The write returns normally, discarded bytes are not
counted, and the producer's next state check or the runner's disconnect signal
stops further work. Stream may cancel its own still-pending producer Future,
but it never cancels a server-owned send Future. Cleanup callbacks are awaited
once in registration order; cleanup failures are reported without replacing a
primary delivery failure.

PAGI 0.002007 makes each returned C<disconnect_future> observer
cancellation-isolated. Code that uses this optional capability calls it again
to obtain an observer for each race and passes that observer directly to
C<Future-E<gt>wait_any>; no extra C<without_cancel> shield is needed. Stream
itself remains portable by building its signal from mandatory
C<on_disconnect>.

=head1 HEAD REQUESTS

The enclosing Router/Compose HEAD boundary suppresses wire body events outside
application middleware. Stream still runs the complete GET producer so those
layers see equivalent GET and HEAD metadata. That may be expensive. Declare a
lightweight HEAD route before the GET route when producer work should be
avoided:

    route('/export' => \&head_export, methods => ['HEAD']);
    route('/export' => response('Stream', \&produce_export), methods => ['GET']);

Declaration order matters because a GET route also supplies automatic HEAD.

=cut

1;
