use strict;
use warnings;

use Future;
use Test2::V0;

use PAGI::Response qw(stream_response);
use PAGI::Response::Stream;

{
    package T::StreamSubclass;
    use parent 'PAGI::Response::Stream';

    sub replace_producer {
        my ($self, $producer) = @_;
        die "configured producer must be a coderef\n" unless ref($producer) eq 'CODE';
        $self->{_producer} = $producer;
        return $self;
    }
}

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

subtest 'to_app retains Stream and each invocation captures producer and start values' => sub {
    my @producer_calls;
    my $stream = T::StreamSubclass->new(
        sub { push @producer_calls, 'first'; return $_[0]->write('first') },
        status  => 202,
        headers => ['X-Version' => 'first'],
    );
    my $app = $stream->to_app;
    $stream->status(203)
        ->remove_header('X-Version')
        ->header('X-Version' => 'second');
    $stream->replace_producer(
        sub { push @producer_calls, 'second'; return $_[0]->write('second') },
    );

    my @first;
    my $start = Future->new;
    my $send_calls = 0;
    my $running = $app->(
        http_scope(), receive(),
        sub {
            push @first, $_[0];
            return ++$send_calls == 1 ? $start : Future->done;
        },
    );
    is(\@producer_calls, [], 'producer waits for response-start settlement');

    $stream->status(206)
        ->remove_header('X-Version')
        ->header('X-Version' => 'third');
    $stream->replace_producer(
        sub { push @producer_calls, 'third'; return $_[0]->write('third') },
    );
    $start->done;
    $running->get;

    is(\@producer_calls, ['second'],
        'mutation while start is parked does not replace this invocation producer');
    is(\@first, [
        {
            type    => 'http.response.start',
            status  => 203,
            headers => [
                ['Content-Type' => 'application/octet-stream'],
                ['X-Version' => 'second'],
            ],
        },
        { type => 'http.response.body', body => 'second', more => 1 },
        { type => 'http.response.body', body => '', more => 0 },
    ], 'the first invocation uses one pre-start Stream delivery plan');

    my @second;
    $app->(
        http_scope(), receive(),
        sub { push @second, $_[0]; Future->done },
    )->get;
    is(\@producer_calls, ['second', 'third'],
        'a later invocation observes the later producer change');
    is($second[0], {
        type    => 'http.response.start',
        status  => 206,
        headers => [
            ['Content-Type' => 'application/octet-stream'],
            ['X-Version' => 'third'],
        ],
    }, 'a later invocation observes later status and header changes');
    is($second[1], {
        type => 'http.response.body', body => 'third', more => 1,
    }, 'a later invocation runs the newly configured producer');
};

subtest 'Stream exposes no inherited buffered body, including through subclasses' => sub {
    my $stream = PAGI::Response::Stream->new(sub { $_[0]->write('base') });
    like(dies { $stream->body }, qr/Stream response has no buffered body/,
        'direct Stream body access croaks with the unbuffered diagnostic');

    my $subclass = T::StreamSubclass->new(sub { $_[0]->write('subclass') });
    like(dies { $subclass->body }, qr/Stream response has no buffered body/,
        'a Stream subclass inherits the unbuffered body contract');

    my @events;
    $subclass->to_app->(
        http_scope(), receive(),
        sub { push @events, $_[0]; Future->done },
    )->get;
    is([map { $_->{type} } @events], [
        'http.response.start',
        'http.response.body',
        'http.response.body',
    ], 'compiled Stream application emits without consulting buffered body');
    is($events[1]{body}, 'subclass',
        'compiled subclass still streams its producer bytes');
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
