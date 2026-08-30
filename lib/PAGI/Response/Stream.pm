package PAGI::Response::Stream;

use strict;
use warnings;

use Carp qw(croak);
use Future;
use Future::AsyncAwait;

use parent 'PAGI::Response';
use PAGI::Response::Writer ();

=encoding UTF-8

=head1 NAME

PAGI::Response::Stream - reusable backpressured HTTP streaming response

=head1 SYNOPSIS

    use Future::AsyncAwait;
    use PAGI::Response qw(stream_response);

    my $response = stream_response(
        async sub {
            my ($writer) = @_;
            await $writer->write("one\n");
            await $writer->write_text("two\n");
        },
        content_type => 'text/plain; charset=utf-8',
    );

=head1 DESCRIPTION

Stream stores response configuration and a producer callback. It creates a
fresh L<PAGI::Response::Writer> for every invocation, sends and awaits the
response start before calling the producer, and sends one terminal empty body
event after normal producer completion.

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
    return stream_response(async sub {
        my ($writer) = @_;
        await $writer->pipe_from($input);
        die 'upload was truncated' if $input->truncated;
    });

=cut

sub new {
    my ($class, $producer, @pairs) = @_;
    croak 'PAGI::Response::Stream->new requires a producer coderef'
        unless @_ >= 2 && ref($producer) eq 'CODE';

    my $self = $class->SUPER::new('', @pairs);
    delete $self->{_body};
    $self->{_producer} = $producer;
    return $self;
}

sub is_buffered { return 0 }

sub body {
    croak 'Stream response has no buffered body';
}

sub _stream_wire_headers {
    my ($self) = @_;
    return $self->{_headers}->to_pairs;
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

    PAGI::Response::Stream->new($producer, %common_response_options)

The first argument must be a Writer producer coderef. C<status>,
C<content_type>, and flat C<headers> use the common Response contract. Stream
does not calculate Content-Length; an explicitly supplied value is retained as
the application's delivery promise.

=head2 respond, to_app

These methods implement the native HTTP triplet and reusable Response
application contracts. Disconnect observation uses only the synchronous
C<pagi.connection> capability. Stream never starts a competing receive loop.
Cancelling the returned Future cancels only the caller's observer and signals
the retained Stream lifecycle to stop producer-owned work. That lifecycle
continues to await any active server-owned send before running cleanup.

=head2 is_buffered

Returns false.

=head2 body

Croaks with C<Stream response has no buffered body>. Stream output belongs to
each invocation's producer and is never represented by one buffered scalar.

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
    route('/export' => stream_response(\&produce_export), methods => ['GET']);

Declaration order matters because a GET route also supplies automatic HEAD.

=cut

1;
