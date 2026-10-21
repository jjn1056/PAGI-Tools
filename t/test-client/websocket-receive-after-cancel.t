use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Future::IO;

use lib 'lib';
use PAGI::Test::Client;

# As on a server (PAGI::Spec::Www, "Meaning per scope"): an application may
# cancel a pending receive -- Future->wait_any cancels the one that loses a
# race -- and that must not affect the scope. The cancelled receive takes no
# message; the next receive gets the next one.

subtest 'a receive after a cancelled one gets the next message' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();                                   # websocket.connect
        await $send->({ type => 'websocket.accept' });
        my $first = $receive->();                             # nothing sent yet: parks
        await Future->wait_any($first, Future::IO->sleep(0.1));
        my $outcome = $first->is_cancelled ? 'cancelled' : 'answered';
        my $event = await $receive->();
        await $send->({ type => 'websocket.send', text => "first receive $outcome; got '$event->{text}'" });
        await $receive->();
    };
    my $ws = PAGI::Test::Client->new(app => $app)->websocket('/');
    Future::IO->sleep(0.3)->get;                              # the app's timer wins meanwhile
    $ws->send_text('hello');
    is($ws->receive_text(2), "first receive cancelled; got 'hello'", 'the later receive got the message');
    $ws->close;
};

subtest 'two receives pending: cancelling one leaves the other' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();
        await $send->({ type => 'websocket.accept' });
        my ($f1, $f2) = ($receive->(), $receive->());
        $f1->cancel;
        my $event = await $f2;
        await $send->({ type => 'websocket.send', text => "other receive got '$event->{text}'" });
        await $receive->();
    };
    my $ws = PAGI::Test::Client->new(app => $app)->websocket('/');
    $ws->send_text('hello');
    is($ws->receive_text(2), "other receive got 'hello'", 'the other receive got the message');
    $ws->close;
};

done_testing;
