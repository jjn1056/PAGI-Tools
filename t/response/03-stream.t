use strict;
use warnings;

use Future;
use Test2::V0;

use PAGI::Response qw(stream_response);
use PAGI::Response::Stream;

sub http_scope {
    my (%changes) = @_;
    return {
        type    => 'http',
        method  => 'GET',
        headers => [],
        %changes,
    };
}

sub receive {
    return sub { Future->done({ type => 'http.request', body => '', more => 0 }) };
}

subtest 'Stream is a reusable Response value with one fresh Writer per invocation' => sub {
    my @writers;
    my $producer_calls = 0;
    my $stream = stream_response(
        sub {
            my ($writer) = @_;
            ++$producer_calls;
            push @writers, $writer;
            return $writer->write("chunk-$producer_calls");
        },
        status       => 201,
        content_type => 'application/x-stream',
        headers      => ['Content-Length' => 99, 'X-Stream' => 'yes'],
    );

    isa_ok($stream, ['PAGI::Response::Stream', 'PAGI::Response']);
    ok(!$stream->is_buffered, 'Stream explicitly reports non-buffered output');

    my @invocations;
    for (1 .. 2) {
        my @events;
        my $app = $stream->respond(
            http_scope(),
            receive(),
            sub { push @events, $_[0]; Future->done },
        );
        $app->get;
        push @invocations, \@events;
    }

    is($producer_calls, 2, 'the producer runs independently for each invocation');
    isnt($writers[0], $writers[1], 'each invocation receives a fresh Writer');
    for my $index (0 .. 1) {
        is($invocations[$index], [
            {
                type    => 'http.response.start',
                status  => 201,
                headers => [
                    ['Content-Length' => 99],
                    ['X-Stream' => 'yes'],
                    ['Content-Type' => 'application/x-stream'],
                ],
            },
            {
                type => 'http.response.body',
                body => 'chunk-' . ($index + 1),
                more => 1,
            },
            { type => 'http.response.body', body => '', more => 0 },
        ], 'Stream preserves explicit framing metadata and terminates normally');
    }
};

subtest 'start settles before producer invocation and producer Future completion is awaited' => sub {
    my @events;
    my $start = Future->new;
    my $producer_done = Future->new;
    my $producer_calls = 0;
    my $send_calls = 0;
    my $stream = PAGI::Response::Stream->new(sub {
        ++$producer_calls;
        return $producer_done;
    });

    my $running = $stream->respond(
        http_scope(),
        receive(),
        sub {
            push @events, $_[0];
            return ++$send_calls == 1 ? $start : Future->done;
        },
    );

    is($producer_calls, 0, 'producer is not invoked while response start is pending');
    ok(!$running->is_ready, 'Stream awaits the response start Future');
    $start->done;
    is($producer_calls, 1, 'producer is invoked after response start settles');
    is(scalar @events, 1, 'no body event is emitted while producer work is pending');
    ok(!$running->is_ready, 'Stream awaits a Future-backed producer');
    $producer_done->done('ignored producer result');
    $running->get;
    is($events[-1], { type => 'http.response.body', body => '', more => 0 },
        'producer completion triggers one automatic terminal event');
};

subtest 'immediate producer completion and to_app configuration snapshots are supported' => sub {
    my $producer_calls = 0;
    my $stream = PAGI::Response::Stream->new(
        sub { ++$producer_calls; return 'immediate completion' },
        status  => 202,
        headers => ['X-Snapshot' => 'old'],
    );
    my $app = $stream->to_app;
    $stream->status(203)->remove_header('X-Snapshot')->header('X-Snapshot' => 'new');

    my @events;
    $app->(http_scope(), receive(), sub { push @events, $_[0]; Future->done })->get;
    is($producer_calls, 1, 'an immediate producer result is wrapped and awaited');
    is($events[0]{status}, 202, 'to_app retains the compiled status snapshot');
    is($events[0]{headers}, [
        ['X-Snapshot' => 'old'],
        ['Content-Type' => 'application/octet-stream'],
    ], 'to_app retains the compiled header snapshot without calculating Content-Length');
};

subtest 'Stream validates construction and the native HTTP triplet before sending' => sub {
    like(dies { PAGI::Response::Stream->new('not a producer') }, qr/producer.*coderef/i,
        'producer must be a coderef');
    like(dies { PAGI::Response::Stream->new(sub { }, status => 200, status => 201) },
        qr/duplicate/i, 'common response options keep duplicate validation');

    my $stream = PAGI::Response::Stream->new(sub { });
    for my $bad_scope (undef, {}, { type => 'websocket' }, bless({}, 'T::Scope')) {
        my @events;
        like(dies {
            $stream->respond(
                $bad_scope,
                receive(),
                sub { push @events, $_[0]; Future->done },
            )->get;
        }, qr/(?:scope|HTTP)/i, 'non-HTTP scope is rejected');
        is(\@events, [], 'invalid protocol use sends no events');
    }
    like(dies { $stream->respond(http_scope(), 'receive', sub { Future->done })->get },
        qr/receive.*coderef/i, 'receive must be a coderef');
    like(dies { $stream->respond(http_scope(), receive(), 'send')->get },
        qr/send.*coderef/i, 'send must be a coderef');
};

done_testing;
