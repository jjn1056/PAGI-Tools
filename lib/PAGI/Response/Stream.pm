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
an unbounded queue.

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

sub _snapshot {
    my ($self) = @_;
    my %copy = (
        _producer => $self->{_producer},
        _headers  => $self->{_headers}->clone,
    );
    $copy{_status} = $self->{_status} if $self->has_status;
    return bless \%copy, ref($self);
}

sub _stream_wire_headers {
    my ($self) = @_;
    return $self->{_headers}->to_pairs;
}

async sub respond {
    my ($self, $scope, $receive, $send) = @_;
    PAGI::Response::_validate_http_triplet($scope, $receive, $send);
    my $snapshot = $self->_snapshot;

    await Future->wrap($send->({
        type    => 'http.response.start',
        status  => $snapshot->status,
        headers => $snapshot->_stream_wire_headers,
    }));

    my $writer = PAGI::Response::Writer->_new(
        send       => $send,
        connection => $scope->{'pagi.connection'},
        transport  => $scope->{'pagi.transport'},
    );
    if ($writer->is_disconnected) {
        await $writer->_abort;
        return;
    }

    my $producer_returned;
    my $producer_called = eval {
        $producer_returned = $snapshot->{_producer}->($writer);
        1;
    };
    unless ($producer_called) {
        my $error = $@;
        await $writer->_abort;
        die $error;
    }

    my $producer = Future->wrap($producer_returned);
    my $producer_outcome = _producer_outcome($producer);
    my $disconnect_outcome = _disconnect_outcome($writer->_disconnect_signal);
    my $outcome = await Future->wait_any(
        $disconnect_outcome,
        $producer_outcome,
    );

    # wait_any resolves by readiness, not by error priority. A producer/send
    # failure that is already observable in the disconnect turn remains the
    # application outcome even when the disconnect signal won the race.
    if ($outcome->{kind} eq 'disconnect' && $producer->is_failed) {
        my @failure = $producer->failure;
        $outcome = {
            kind    => 'producer_failed',
            failure => \@failure,
        };
    }

    if ($outcome->{kind} eq 'disconnect') {
        await $writer->_abort;
        return;
    }

    if ($outcome->{kind} eq 'producer_failed') {
        my $failure = $outcome->{failure};
        my $error = $failure->[0];
        await $writer->_abort;
        return if PAGI::Response::Writer->_is_disconnect_error($error);
        die $error;
    }

    if ($outcome->{kind} eq 'producer_cancelled') {
        await $writer->_abort;
        die "Stream producer Future was cancelled\n";
    }

    if ($writer->is_disconnected) {
        await $writer->_abort;
        return;
    }

    my ($closed, $close_error);
    $closed = eval { await $writer->close; 1 };
    $close_error = $@ unless $closed;
    unless ($closed) {
        await $writer->_abort;
        return if PAGI::Response::Writer->_is_disconnect_error($close_error);
        die $close_error;
    }

    return;
}

sub to_app {
    my ($self) = @_;
    my $snapshot = $self->_snapshot;
    return async sub {
        my ($scope, $receive, $send) = @_;
        await $snapshot->respond($scope, $receive, $send);
        return;
    };
}

sub _producer_outcome {
    my ($producer) = @_;
    my $outcome = Future->new;
    $outcome->on_cancel(sub {
        $producer->cancel
            if !$producer->is_ready && !$producer->is_cancelled;
    });
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
    $outcome->on_cancel(sub {
        $signal->cancel if !$signal->is_ready && !$signal->is_cancelled;
    });
    $signal->on_ready(sub {
        return if $outcome->is_ready || $outcome->is_cancelled;
        if ($signal->is_failed) {
            $outcome->fail($signal->failure);
        } elsif ($signal->is_cancelled) {
            $outcome->done({ kind => 'disconnect' });
        } else {
            $outcome->done({ kind => 'disconnect' });
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

=head2 is_buffered

Returns false.

=head1 DISCONNECTS AND FAILURES

Connection disconnects cancel pending producer work, run local cleanup, omit
terminal success, and complete as the server-owned connection outcome. Genuine
producer and send errors run the same cleanup but remain application failures.

=cut

1;
