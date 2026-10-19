package PAGI::Test::_Drive;

use strict;
use warnings;
use Future;
use Time::HiRes ();

# Internal to PAGI's in-process test client. Not public API.

# How long the test client waits for an application that is waiting on real
# I/O before giving up, in seconds.
our $TIMEOUT = 5;

# Returns 1 once $future is ready, driving an event loop for at most $seconds,
# else 0. A Future whose class runs its own loop (an IO::Async::Future from the
# application's own loop) runs that loop, as ->get on it does. ->get on a plain
# pending Future cannot block, so the wait is joined with a Future::IO sleep:
# wait_any builds its result in the class of the first subfuture that is not a
# plain Future -- $future's own, else the sleep's -- and ->get runs that loop.
# The $seconds limit holds when the loop that runs is Future::IO's. Without
# Future::IO only $future's own loop can make progress, so a plain pending
# $future returns 0 at once. A failed $future is the caller's to read.
sub drive {
    my ($future, $seconds) = @_;
    return 1 if $future->is_ready;
    unless (eval { require Future::IO; 1 }) {
        eval { $future->await };
        return $future->is_ready ? 1 : 0;
    }

    my $waiter = Future->wait_any(
        $future->without_cancel,
        Future::IO->sleep($seconds),
    );
    eval { $waiter->get };
    return $future->is_ready ? 1 : 0;
}

# Waits for an answer from $attempt, driving the event loop in between.
# $attempt returns a one-element list to answer (the element may be undef)
# or the empty list to keep waiting. Returns the answer, or the empty list
# once $seconds have passed. While it waits, $owner->{_arrival} holds a
# Future that the owner resolves (signal_arrival) whenever its state
# changes, so each new arrival is looked at as soon as it lands.
sub wait_for {
    my ($owner, $seconds, $attempt) = @_;
    my $deadline = Time::HiRes::time() + $seconds;
    while (1) {
        my @answer = $attempt->();
        return $answer[0] if @answer;
        my $remaining = $deadline - Time::HiRes::time();
        return if $remaining <= 0;
        my $arrival = $owner->{_arrival} = Future->new;
        my $arrived = drive($arrival, $remaining);
        delete $owner->{_arrival};
        return unless $arrived;
    }
}

# Resolves $owner's pending arrival, if any.
sub signal_arrival {
    my ($owner) = @_;
    my $arrival = delete $owner->{_arrival} or return;
    $arrival->done unless $arrival->is_ready;
    return;
}

1;
