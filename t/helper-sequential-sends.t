use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 't/lib';
use PAGITest::Connected qw(ws_scope sse_scope);
use PAGI::WebSocket;
use PAGI::SSE;

# PAGI::Spec::Www 0.7, "Sends Are Sequential": the server keeps a scope's
# sends in the order they were called, so PAGI::WebSocket and PAGI::SSE hand
# each send to the server at once. Code with several producers on one
# connection -- a reply racing a broadcast -- needs no queue, and no helper
# send waits for another.

# A send that records each event and hands back a Future the test settles.
sub controlled_send {
    my @issued;
    my $send = sub {
        my ($event) = @_;
        push @issued, { event => $event, future => Future->new };
        return $issued[-1]{future};
    };
    return ($send, \@issued);
}

my %helper = (
    'PAGI::WebSocket' => {
        open => sub {
            my ($send, $issued) = @_;
            my $ws = PAGI::WebSocket->new(ws_scope(), sub { Future->new }, $send);
            my $accepting = $ws->accept;
            $issued->[-1]{future}->done;
            $accepting->get;
            return $ws;
        },
        # Accepted over a send that completes its accept at once.
        build => sub {
            my ($send) = @_;
            my $ws = PAGI::WebSocket->new(ws_scope(), sub { Future->new }, $send);
            $ws->accept->get;
            return $ws;
        },
        send => sub { my ($ws, $text) = @_; $ws->send_text($text) },
        body => sub { $_[0]{event}{text} },
    },
    'PAGI::SSE' => {
        open => sub {
            my ($send, $issued) = @_;
            my $sse = PAGI::SSE->new(sse_scope(), sub { Future->new }, $send);
            my $starting = $sse->start;
            $issued->[-1]{future}->done;
            $starting->get;
            return $sse;
        },
        build => sub {
            my ($send) = @_;
            my $sse = PAGI::SSE->new(sse_scope(), sub { Future->new }, $send);
            $sse->start->get;
            return $sse;
        },
        send => sub { my ($sse, $text) = @_; $sse->send_event(data => $text) },
        body => sub { $_[0]{event}{data} },
    },
);

for my $class (sort keys %helper) {
    my $h = $helper{$class};
    my $bodies = sub { [map { $h->{body}->($_) } @{ $_[0] }[1 .. $#{ $_[0] }]] };

    subtest "$class: an idle connection sends at once" => sub {
        my ($send, $issued) = controlled_send();
        my $conn = $h->{open}->($send, $issued);
        my $sent = $h->{send}->($conn, 'one');
        is($bodies->($issued), ['one'], 'issued without waiting');
        $issued->[1]{future}->done;
        ok($sent->is_done, 'and completes when the server settles it');
    };

    subtest "$class: every send is issued at once, in call order" => sub {
        my ($send, $issued) = controlled_send();
        my $conn = $h->{open}->($send, $issued);
        my $first  = $h->{send}->($conn, 'one');
        my $second = $h->{send}->($conn, 'two');
        is($bodies->($issued), ['one', 'two'], 'both are with the server, in order');
        ok(!$first->is_ready && !$second->is_ready, 'neither has settled');

        $issued->[2]{future}->done;
        ok($second->is_done && !$first->is_ready, 'each settles when the server settles it');
        $issued->[1]{future}->done;
        ok($first->is_done, 'whatever the order');
    };

    subtest "$class: a failed send does not affect the next" => sub {
        my ($send, $issued) = controlled_send();
        my $conn = $h->{open}->($send, $issued);
        my $first  = $h->{send}->($conn, 'one');
        my $second = $h->{send}->($conn, 'two');
        $issued->[1]{future}->fail("wire broke\n");
        like(dies { $first->get }, qr/wire broke/, 'the failure reaches its own caller');
        $issued->[2]{future}->done;
        ok($second->is_done, 'the next completes');
    };

    subtest "$class: a send the server holds is never cancelled by its caller" => sub {
        my ($send, $issued) = controlled_send();
        my $conn = $h->{open}->($send, $issued);
        my $first = $h->{send}->($conn, 'one');
        $first->cancel;
        ok(!$issued->[1]{future}->is_cancelled, 'the server-owned send is left alone');
        my $second = $h->{send}->($conn, 'two');
        is($bodies->($issued), ['one', 'two'], 'and the next goes out after it');
    };

    subtest "$class: a send cancelled downstream does not affect the next" => sub {
        my ($send, $issued) = controlled_send();
        my $conn = $h->{open}->($send, $issued);
        my $first  = $h->{send}->($conn, 'one');
        my $second = $h->{send}->($conn, 'two');
        $issued->[1]{future}->cancel;    # e.g. a wrapper around $send
        like($first->failure, qr/cancelled/, 'the cancellation reaches its own caller');
        $issued->[2]{future}->done;
        ok($second->is_done, 'the next completes');
    };

    subtest "$class: sends through a send wrapper that waits all arrive" => sub {
        # A middleware's send wrapper that waits before passing each event on,
        # as a rate limiter, a database write or backpressure would. Nothing
        # but the helper's caller holds the wrapper's Future while it waits.
        my (@arrived, @warnings);
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $gate = Future->new;
        my $waiting = async sub {
            my ($event) = @_;
            await $gate unless $event->{type} =~ /\.(?:accept|start)\z/;
            push @arrived, $event;
        };
        my $conn = $h->{build}->($waiting);
        my $first  = $h->{send}->($conn, 'one');
        my $second = $h->{send}->($conn, 'two');
        $gate->done;
        is([map { $h->{body}->({ event => $_ }) } grep { $_->{type} =~ /\.send\z/ } @arrived],
            ['one', 'two'], 'both reach the server, in order');
        ok($first->is_done && $second->is_done, 'and both complete');
        is(\@warnings, [], 'no send is lost on the way');
    };
}

subtest 'PAGI::SSE: sends made before the stream starts issue one sse.start' => sub {
    my ($send, $issued) = controlled_send();
    my $sse = PAGI::SSE->new(sse_scope(), sub { Future->new }, $send);
    my $first  = $sse->send_event(data => 'one');
    my $second = $sse->send_event(data => 'two');
    # Settle each send as it is issued, until none is left waiting.
    while (my ($pending) = grep { !$_->{future}->is_ready } @$issued) {
        $pending->{future}->done;
    }
    is([map { $_->{event}{type} } @$issued], ['sse.start', 'sse.send', 'sse.send'],
        'one start, then both events in order');
    ok($first->is_done && $second->is_done, 'both sends complete');
};

done_testing;
