use strict;
use warnings;
use Test2::V0;
use Future;

use lib 't/lib';
use PAGITest::Connected qw(ws_scope sse_scope);
use PAGI::WebSocket;
use PAGI::SSE;

# PAGI::Spec::Www, "Sends Are Sequential": an application must not issue a
# send before the previous one has resolved. PAGI::WebSocket and PAGI::SSE
# serialize their own sends, so code with several producers on one
# connection -- a reply racing a broadcast -- needs no queue of its own.

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
        $h->{send}->($conn, 'one');
        is($bodies->($issued), ['one'], 'issued without waiting');
    };

    subtest "$class: a second send waits for the first to settle" => sub {
        my ($send, $issued) = controlled_send();
        my $conn = $h->{open}->($send, $issued);
        my $first  = $h->{send}->($conn, 'one');
        my $second = $h->{send}->($conn, 'two');
        is($bodies->($issued), ['one'], 'only the first is in flight');
        ok(!$second->is_ready, 'the second waits');

        $issued->[1]{future}->done;
        is($bodies->($issued), ['one', 'two'], 'then the second goes');
        ok($first->is_done, 'the first caller sees its send complete');
        $issued->[2]{future}->done;
        ok($second->is_done, 'and so does the second');
    };

    subtest "$class: a failed send does not block the next" => sub {
        my ($send, $issued) = controlled_send();
        my $conn = $h->{open}->($send, $issued);
        my $first  = $h->{send}->($conn, 'one');
        my $second = $h->{send}->($conn, 'two');
        $issued->[1]{future}->fail("wire broke\n");
        like(dies { $first->get }, qr/wire broke/, 'the failure reaches its own caller');
        is($bodies->($issued), ['one', 'two'], 'the next send is still issued');
        $issued->[2]{future}->done;
        ok($second->is_done, 'and completes');
    };

    subtest "$class: a waiting send its caller cancels is never issued" => sub {
        my ($send, $issued) = controlled_send();
        my $conn = $h->{open}->($send, $issued);
        $h->{send}->($conn, 'one');
        my $second = $h->{send}->($conn, 'two');
        my $third  = $h->{send}->($conn, 'three');
        $second->cancel;
        $issued->[1]{future}->done;
        is($bodies->($issued), ['one', 'three'], 'the cancelled send is skipped, order kept');
    };

    subtest "$class: an issued send is never cancelled by its caller" => sub {
        my ($send, $issued) = controlled_send();
        my $conn = $h->{open}->($send, $issued);
        my $first = $h->{send}->($conn, 'one');
        my $second = $h->{send}->($conn, 'two');
        $first->cancel;
        ok(!$issued->[1]{future}->is_cancelled, 'the server-owned send is left alone');
        is($bodies->($issued), ['one'], 'and the next still waits for it to settle');
        $issued->[1]{future}->done;
        is($bodies->($issued), ['one', 'two'], 'before going out');
    };
}

done_testing;
