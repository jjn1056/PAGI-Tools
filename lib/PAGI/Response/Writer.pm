package PAGI::Response::Writer;

use strict;
use warnings;

use Carp qw(croak);
use Encode qw(encode FB_CROAK LEAVE_SRC);
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(blessed weaken);

use PAGI::Response ();

=encoding UTF-8

=head1 NAME

PAGI::Response::Writer - sequential per-invocation HTTP Stream writer

=head1 DESCRIPTION

A Writer is created internally for one L<PAGI::Response::Stream> invocation.
It is not a Response, application value, or publicly constructible object;
applications never attach one to a Response.

Every C<write> returns a Future chained to the invocation's PAGI send Future.
Applications must await that Future before producing the next chunk.  Only one
write may be outstanding; Writer never hides a queue or buffers multiple
chunks.

    await $writer->write($bytes);       # primary backpressure boundary
    await $writer->write_text($chars);  # strict UTF-8, same boundary

B<Every write must be awaited before another starts.>

=cut

sub _new {
    my ($class, %args) = @_;
    my $send = $args{send};
    croak 'Writer send must be a coderef' unless ref($send) eq 'CODE';

    my $connection = $args{connection};
    if (defined $connection) {
        croak 'pagi.connection must provide is_connected, disconnect_reason, and on_disconnect'
            unless blessed($connection)
                && $connection->can('is_connected')
                && $connection->can('disconnect_reason')
                && $connection->can('on_disconnect');
    }

    my $transport = $args{transport};
    if (defined $transport) {
        croak 'pagi.transport must provide buffered_amount'
            unless blessed($transport) && $transport->can('buffered_amount');
    }

    my $self = bless {
        _send              => $send,
        _connection        => $connection,
        _transport         => $transport,
        _closed            => 0,
        _aborted           => 0,
        _disconnected      => 0,
        _disconnect_reason => undef,
        _disconnect_signal => Future->new,
        _bytes_written     => 0,
        _active_write      => undef,
        _active_close      => undef,
        _close_future      => undef,
        _abort_future      => undef,
        _on_close          => [],
        _cleanup_future    => undef,
    }, $class;

    if ($connection) {
        my $weak_self = $self;
        weaken($weak_self);
        $connection->on_disconnect(sub {
            my ($reason) = @_;
            return unless $weak_self;
            $weak_self->_record_disconnect($reason);
        });
        $self->_refresh_disconnect;
    }

    return $self;
}

sub write {
    my ($self, $bytes) = @_;
    PAGI::Response::_require_bytes('stream chunk', $bytes);
    croak 'A write is already outstanding; await write before writing again'
        if $self->{_active_write};
    return Future->fail("Writer already closed\n") if $self->{_closed};

    $self->_refresh_disconnect;

    my $delivery = Future->new;
    my $active = {
        delivery => $delivery,
        send     => undef,
    };
    $self->{_active_write} = $active;

    my $send_future;
    my $called = eval {
        $send_future = Future->wrap($self->{_send}->({
            type => 'http.response.body',
            body => $bytes,
            more => 1,
        }));
        1;
    };
    unless ($called) {
        $self->{_active_write} = undef
            if $self->{_active_write} && $self->{_active_write} == $active;
        $delivery->fail($@) unless $delivery->is_ready || $delivery->is_cancelled;
        return $delivery;
    }

    $active->{send} = $send_future;
    $send_future->on_ready(sub {
        $self->{_active_write} = undef
            if $self->{_active_write} && $self->{_active_write} == $active;

        if ($send_future->is_failed) {
            $delivery->fail($send_future->failure)
                unless $delivery->is_ready || $delivery->is_cancelled;
            return;
        }
        if ($send_future->is_cancelled) {
            $delivery->fail("Stream send Future was cancelled\n")
                unless $delivery->is_ready || $delivery->is_cancelled;
            return;
        }

        $self->_refresh_disconnect;
        $self->{_bytes_written} += length $bytes
            unless $self->{_disconnected};
        $delivery->done unless $delivery->is_ready || $delivery->is_cancelled;
    });

    return $delivery;
}

sub write_text {
    my ($self, $characters) = @_;
    croak 'stream text must be a defined unblessed character scalar'
        unless defined($characters) && !ref($characters);
    my $bytes = encode('UTF-8', $characters, FB_CROAK | LEAVE_SRC);
    return $self->write($bytes);
}

sub pipe_from {
    my ($self, $source) = @_;
    croak 'pipe_from source must be an object with next_chunk'
        unless blessed($source) && $source->can('next_chunk');
    return $self->_pipe_from($source);
}

async sub _pipe_from {
    my ($self, $source) = @_;
    while (1) {
        last if $self->is_disconnected;
        my $returned = $source->next_chunk;
        my $chunk = await Future->wrap($returned);
        last unless defined $chunk;
        next unless length $chunk;
        await $self->write($chunk);
        last if $self->is_disconnected;
    }
    return;
}

sub close {
    my ($self) = @_;
    return $self->{_close_future}->without_cancel
        if $self->{_close_future};
    return Future->done if $self->{_closed};
    croak 'Cannot close while a write is outstanding; await write first'
        if $self->{_active_write};

    $self->_refresh_disconnect;

    $self->{_closed} = 1;
    my $delivery = Future->new;
    my $active = {
        delivery => $delivery,
        send     => undef,
    };
    $self->{_active_close} = $active;

    my $finished = $self->_finish_close($delivery);
    $self->{_close_future} = $finished;
    my $send_future;
    my $called = eval {
        $send_future = Future->wrap($self->{_send}->({
            type => 'http.response.body',
            body => '',
            more => 0,
        }));
        1;
    };
    unless ($called) {
        $self->{_active_close} = undef
            if $self->{_active_close} && $self->{_active_close} == $active;
        $delivery->fail($@) unless $delivery->is_ready || $delivery->is_cancelled;
        return $finished->without_cancel;
    }

    $active->{send} = $send_future;
    $send_future->on_ready(sub {
        $self->{_active_close} = undef
            if $self->{_active_close} && $self->{_active_close} == $active;

        if ($send_future->is_failed) {
            $delivery->fail($send_future->failure)
                unless $delivery->is_ready || $delivery->is_cancelled;
            return;
        }
        if ($send_future->is_cancelled) {
            $delivery->fail("Stream terminal send Future was cancelled\n")
                unless $delivery->is_ready || $delivery->is_cancelled;
            return;
        }

        $self->_refresh_disconnect;
        $delivery->done unless $delivery->is_ready || $delivery->is_cancelled;
    });

    return $finished->without_cancel;
}

async sub _finish_close {
    my ($self, $delivery) = @_;
    my ($delivery_ok, $delivery_error);
    $delivery_ok = eval { await $delivery; 1 };
    $delivery_error = $@ unless $delivery_ok;

    await $self->_cleanup;
    die $delivery_error unless $delivery_ok;
    return;
}

sub _abort {
    my ($self) = @_;
    return $self->{_abort_future}->without_cancel if $self->{_abort_future};

    $self->{_closed} = 1;
    $self->{_aborted} = 1;

    my @active_settlements;
    for my $slot (qw(_active_write _active_close)) {
        my $active = $self->{$slot} or next;
        if ($slot eq '_active_close' && $self->{_close_future}) {
            push @active_settlements, $self->{_close_future}->without_cancel;
        }
        my $send = $active->{send};
        push @active_settlements, $send->without_cancel if $send;
    }

    my $completion = async sub {
        await Future->wait_all(@active_settlements);
        return;
    }->();
    $self->{_abort_future} = $completion;
    return $completion->without_cancel;
}

sub _cleanup {
    my ($self) = @_;
    return $self->{_cleanup_future}->without_cancel
        if $self->{_cleanup_future};

    my $completion = Future->new;
    $self->{_cleanup_future} = $completion;
    my @callbacks = splice @{$self->{_on_close}};

    my $worker = async sub {
        for my $callback (@callbacks) {
            my $ok = eval {
                my $returned = $callback->();
                await Future->wrap($returned);
                1;
            };
            warn "PAGI::Response::Writer on_close callback error: $@" unless $ok;
        }
        return;
    }->();
    $worker->on_ready(sub {
        return if $completion->is_ready || $completion->is_cancelled;
        if ($worker->is_failed) {
            $completion->fail($worker->failure);
        } elsif ($worker->is_cancelled) {
            $completion->fail("Writer cleanup was cancelled\n");
        } else {
            $completion->done;
        }
    });

    return $completion->without_cancel;
}

sub on_close {
    my ($self, $callback) = @_;
    croak 'on_close callback must be a coderef' unless ref($callback) eq 'CODE';
    croak 'Cannot register on_close after Writer is closed' if $self->{_closed};
    push @{$self->{_on_close}}, $callback;
    return $self;
}

sub is_closed { return $_[0]{_closed} ? 1 : 0 }

sub is_disconnected {
    my ($self) = @_;
    return undef unless $self->{_connection};
    $self->_refresh_disconnect;
    return $self->{_disconnected} ? 1 : 0;
}

sub disconnect_reason {
    my ($self) = @_;
    $self->_refresh_disconnect if $self->{_connection};
    return $self->{_disconnect_reason};
}

sub bytes_written { return $_[0]{_bytes_written} }

sub buffered_amount {
    my ($self) = @_;
    return 0 unless $self->{_transport};
    return $self->{_transport}->buffered_amount;
}

sub high_water_mark {
    my ($self) = @_;
    my $transport = $self->{_transport};
    return undef unless $transport && $transport->can('high_water_mark');
    return $transport->high_water_mark;
}

sub low_water_mark {
    my ($self) = @_;
    my $transport = $self->{_transport};
    return undef unless $transport && $transport->can('low_water_mark');
    return $transport->low_water_mark;
}

sub is_writable {
    my ($self) = @_;
    my $high = $self->high_water_mark;
    return 1 unless defined $high;
    return $self->buffered_amount < $high ? 1 : 0;
}

sub on_high_water {
    my ($self, $callback) = @_;
    my $transport = $self->{_transport};
    $transport->on_high_water($callback)
        if $transport && $transport->can('on_high_water');
    return $self;
}

sub on_drain {
    my ($self, $callback) = @_;
    my $transport = $self->{_transport};
    $transport->on_drain($callback)
        if $transport && $transport->can('on_drain');
    return $self;
}

sub _disconnect_signal { return $_[0]{_disconnect_signal} }

sub _refresh_disconnect {
    my ($self) = @_;
    my $connection = $self->{_connection};
    return unless $connection || $self->{_disconnected};
    return 1 if $self->{_disconnected};
    return 0 if $connection->is_connected;

    if ($connection->can('response_complete')) {
        my $complete = $connection->response_complete;
        return 0 if defined($complete) && $complete;
    }

    $self->{_disconnected} = 1;
    my $reason = $connection->disconnect_reason;
    $self->{_disconnect_reason} = $reason
        if defined($reason) && length($reason);
    return 1;
}

sub _record_disconnect {
    my ($self, $reason) = @_;
    $self->{_disconnected} = 1;
    $self->{_disconnect_reason} = $reason
        if defined($reason) && length($reason);
    $self->_publish_disconnect;
    return;
}

sub _publish_disconnect {
    my ($self) = @_;
    my $signal = $self->{_disconnect_signal};
    $signal->done($self->{_disconnect_reason})
        unless $signal->is_ready || $signal->is_cancelled;
    return;
}

=head1 METHODS

=head2 write, write_text

    await $writer->write($encoded_bytes);
    await $writer->write_text($characters);

C<write> sends one nonterminal body event and settles only when the PAGI send
Future settles. Under PAGI 0.002007 that Future resolves after the server
accepts the event into outbound processing or finishes discarding it after disconnect;
resolution is not proof that the client received it. Writer then checks
connection state and counts bytes only while still connected. A disconnect
never manufactures a write failure. Genuine validation or resource failures
from C<$send> still propagate.
C<write_text> performs strict UTF-8 encoding first. Await each write before
starting another.

=head2 pipe_from

    await $writer->pipe_from($source);

Pulls immediate or Future-backed C<next_chunk> results sequentially. Empty
chunks are skipped, and the next pull never starts before the previous write
settles. The relay stops before another source pull once connection state
reports a disconnect.

=head2 close, is_closed

C<close> sends one terminal empty body event and runs cleanup. It is
idempotent; repeated calls while terminal delivery or cleanup is pending join
that same close completion. Writes after close fail.

=head2 is_disconnected, disconnect_reason, bytes_written

Connection capability is tri-state: C<is_disconnected> is C<undef> without
C<pagi.connection>. C<bytes_written> counts only nonterminal bytes whose send
settled before a detected disconnect.

=head2 on_close

Registers immediate or Future-backed local cleanup in registration order.
Cleanup runs exactly once. Individual failures are warned and do not prevent
later callbacks.

=head2 buffered_amount, high_water_mark, low_water_mark, is_writable

These methods report the invocation transport's current outbound buffer and
watermark state.

=head2 on_high_water, on_drain

These methods expose the invocation's optional C<pagi.transport> flow-control
capability. Without it, buffered amount is zero, watermarks are undefined,
the writer is writable, and registrations are chainable no-ops.

Those operational fallbacks differ deliberately from the top-level
C<transport($request)> helper, which returns C<undef> when the optional
capability is absent. Awaiting every write remains the portable backpressure
mechanism even when transport watermarks are available.

=head1 DISCONNECT OWNERSHIP

Writer never reads C<$receive>, reconnects, cancels an in-flight send, or turns
disconnect into a failed write. PAGI settles a pending send after updating
connection state; Writer's race-free order is await, then check. If the server
discarded that event, C<bytes_written> does not count it. Stream may cancel its
own producer when its separate disconnect signal wins and waits for any
in-flight send before exactly-once cleanup.

=cut

1;
