#!/usr/bin/env perl
# Streaming in and out at once, with PAGI::Response::Stream: the client
# uploads numbers, one per line, and the server answers each with the
# running total while, on its own, it sends a progress tick every second.
# When the upload ends, the ticker stops and the summary goes out.
#
#   pagi-server --app examples/response/streaming-echo.pl --port 5000
#
#   (echo 5; sleep 1.5; echo 10; sleep 1.5; echo -3) | curl -sN -T - http://localhost:5000/
#
# curl prints the replies in bursts, each time it sends more of its upload,
# so the order shows but not the timing: the server answers each number as
# it arrives and ticks every second. A client that reads while it writes
# shows that as it happens.
#
# How each stream ended is logged to the server's STDERR.

use v5.40;
use Future;
use Future::AsyncAwait;
use Future::IO;
use PAGI::Response::Stream;

my $app = async sub ($scope, $receive, $send) {
    die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';

    my $response = PAGI::Response::Stream->new(
        content_type => 'text/plain; charset=utf-8',
        body         => async sub ($writer) {
            my ($total, $count, $buffer) = (0, 0, '');
            $writer->on_close(sub ($writer) {
                warn "running total ended: ", $writer->outcome, " after $count numbers\n";
            });

            # In: the upload, read as it arrives; each number is answered.
            my $read = async sub {
                while (1) {
                    my $event = await $receive->();
                    last if $event->{type} eq 'http.disconnect';
                    $buffer .= $event->{body} // '';
                    while ($buffer =~ s/\A\s*(-?\d+)\s*\n//) {
                        $total += $1;
                        $count++;
                        await $writer->write_text("got $1, total $total\n");
                    }
                    last unless $event->{more};
                }
            };

            # Out: a tick every second, whatever the client is doing.
            my $tick = async sub {
                for (my $n = 1; ; $n++) {
                    await Future::IO->sleep(1);
                    await $writer->write_text("tick $n: $count numbers so far\n");
                }
            };

            # The upload ending finishes the read; wait_any then cancels the
            # ticker. If the client leaves, the body is cancelled, both with it.
            await Future->wait_any($read->(), $tick->());
            await $writer->write_text("done: $count numbers, total $total\n");
        },    # returning ends the stream
    );

    await $response->call($scope, $receive, $send);
};

$app;
