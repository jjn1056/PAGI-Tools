#!/usr/bin/env perl
use strict;
use warnings;

use File::Temp qw(tempfile);
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);
use Test2::V0;

use lib 'lib';
use PAGI::Response;
use PAGI::Response::Empty;
use PAGI::Response::File;
use PAGI::Response::HTML;
use PAGI::Response::JSON;
use PAGI::Response::Problem;
use PAGI::Response::Redirect;
use PAGI::Response::Stream;
use PAGI::Response::Text;
use PAGI::SSE;
use PAGI::Test::ConnectionState;

sub sse_scope {
    my (%changes) = @_;
    return {
        type    => 'sse',
        method  => 'POST',
        path    => '/events',
        headers => [],
        state   => { shared => 'state' },
        marker  => ['nested'],
        %changes,
    };
}

sub receive { return sub { Future->new } }

sub sse {
    my ($scope, $send) = @_;
    return PAGI::SSE->new($scope, receive(), $send);
}

my $redirect_body = '<!doctype html><html><head><title>Found</title></head><body><p>Redirecting to <a href="/next">/next</a>.</p></body></html>';

my @matrix = (
    [
        base => PAGI::Response->new('raw', status => 418, headers => ['X-Kind' => 'base']),
        [
            {
                type => 'sse.http.response.start', status => 418,
                headers => [
                    ['X-Kind' => 'base'],
                    ['Content-Type' => 'application/octet-stream'],
                    ['content-length' => 3],
                ],
            },
            { type => 'sse.http.response.body', body => 'raw', more => 0 },
        ],
    ],
    [
        Text => PAGI::Response::Text->new('text'),
        [
            {
                type => 'sse.http.response.start', status => 200,
                headers => [
                    ['Content-Type' => 'text/plain; charset=utf-8'],
                    ['content-length' => 4],
                ],
            },
            { type => 'sse.http.response.body', body => 'text', more => 0 },
        ],
    ],
    [
        HTML => PAGI::Response::HTML->new('<b>x</b>'),
        [
            {
                type => 'sse.http.response.start', status => 200,
                headers => [
                    ['Content-Type' => 'text/html; charset=utf-8'],
                    ['content-length' => 8],
                ],
            },
            { type => 'sse.http.response.body', body => '<b>x</b>', more => 0 },
        ],
    ],
    [
        JSON => PAGI::Response::JSON->new([1]),
        [
            {
                type => 'sse.http.response.start', status => 200,
                headers => [
                    ['Content-Type' => 'application/json'],
                    ['content-length' => 3],
                ],
            },
            { type => 'sse.http.response.body', body => '[1]', more => 0 },
        ],
    ],
    [
        Problem => PAGI::Response::Problem->new({ status => 409 }),
        [
            {
                type => 'sse.http.response.start', status => 409,
                headers => [
                    ['Content-Type' => 'application/problem+json'],
                    ['content-length' => 14],
                ],
            },
            { type => 'sse.http.response.body', body => '{"status":409}', more => 0 },
        ],
    ],
    [
        Redirect => PAGI::Response::Redirect->new('/next'),
        [
            {
                type => 'sse.http.response.start', status => 302,
                headers => [
                    ['Content-Type' => 'text/html; charset=utf-8'],
                    ['Location' => '/next'],
                    ['content-length' => length($redirect_body)],
                ],
            },
            { type => 'sse.http.response.body', body => $redirect_body, more => 0 },
        ],
    ],
    [
        Empty => PAGI::Response::Empty->new,
        [
            { type => 'sse.http.response.start', status => 204, headers => [] },
            { type => 'sse.http.response.body', body => '', more => 0 },
        ],
    ],
    [
        Stream => PAGI::Response::Stream->new(async sub {
            my ($writer) = @_;
            await $writer->write('one');
            await $writer->write('two');
        }, content_type => 'application/x-stream'),
        [
            {
                type => 'sse.http.response.start', status => 200,
                headers => [['Content-Type' => 'application/x-stream']],
            },
            { type => 'sse.http.response.body', body => 'one', more => 1 },
            { type => 'sse.http.response.body', body => 'two', more => 1 },
            { type => 'sse.http.response.body', body => '', more => 0 },
        ],
    ],
);

subtest 'decline adapts the complete concrete Response matrix exactly' => sub {
    for my $case (@matrix) {
        my ($name, $response, $expected) = @$case;
        subtest $name => sub {
            my @sent;
            my $sse = sse(sse_scope(), sub { push @sent, $_[0]; Future->done });

            my $returned = $sse->decline($response)->get;
            ok($returned == $sse, 'returns the SSE connection');
            is(\@sent, $expected, 'maps start/body fields, order, and more exactly');
            ok($sse->is_closed, 'decline closes the request');
            ok(!$sse->is_started, 'decline never starts a live stream');
        };
    }
};

subtest 'one Response value can be reused for independent declines' => sub {
    my $response = PAGI::Response::Text->new('reused', status => 401);
    my @invocations;

    for (1 .. 2) {
        my @sent;
        my $sse = sse(sse_scope(), sub { push @sent, $_[0]; Future->done });
        $sse->decline($response)->get;
        push @invocations, \@sent;
    }

    is($invocations[0], $invocations[1], 'unchanged response emits identically twice');
    is($response->status, 401, 'response status remains reusable');
    is($response->body, 'reused', 'response body remains reusable');
};

{
    package T::SSEScopeResponse;
    use Future::AsyncAwait;
    use parent -norequire, 'PAGI::Response';
    our $seen_scope;
    async sub respond {
        my ($self, $scope, $receive, $send) = @_;
        $seen_scope = $scope;
        await $self->SUPER::respond($scope, $receive, $send);
        return;
    }
}

subtest 'Response receives a shallow HTTP scope clone without protocol mutation' => sub {
    my $scope = sse_scope();
    my $state = $scope->{state};
    my $marker = $scope->{marker};
    my @sent;
    my $sse = sse($scope, sub { push @sent, $_[0]; Future->done });

    $sse->decline(T::SSEScopeResponse->new('scope'))->get;

    isnt(refaddr($T::SSEScopeResponse::seen_scope), refaddr($scope),
        'Response sees a distinct top-level hash');
    is($T::SSEScopeResponse::seen_scope->{type}, 'http', 'clone type is HTTP');
    is($T::SSEScopeResponse::seen_scope->{method}, 'GET', 'clone method is GET');
    is($T::SSEScopeResponse::seen_scope->{path}, '/events', 'unrelated scalar fields are retained');
    is(refaddr($T::SSEScopeResponse::seen_scope->{state}), refaddr($state),
        'nested state reference is identical');
    is(refaddr($T::SSEScopeResponse::seen_scope->{marker}), refaddr($marker),
        'other nested references are identical');
    is($scope->{type}, 'sse', 'live protocol scope type is unchanged');
    is($scope->{method}, 'POST', 'live protocol scope method is unchanged');
};

{
    package T::InheritedSSEStream;
    use parent -norequire, 'PAGI::Response::Stream';
}

subtest 'an inherited Stream reaches mapped sends incrementally and commits at start settlement' => sub {
    my @sent;
    my @settlements;
    my $producer_calls = 0;
    my $close_calls = 0;
    my $stream = T::InheritedSSEStream->new(async sub {
        my ($writer) = @_;
        ++$producer_calls;
        await $writer->write('first');
        await $writer->write('second');
    });
    my $sse = sse(sse_scope(), sub {
        push @sent, $_[0];
        return Future->done unless $_[0]{type} =~ /^sse\.http\.response\./;
        my $settlement = Future->new;
        push @settlements, $settlement;
        return $settlement;
    });
    $sse->on_close(sub { ++$close_calls; return Future->done });
    $sse->keepalive(21, 'pending')->get;

    my $decline = $sse->decline($stream);
    is([map { $_->{type} } @sent], ['sse.http.response.start'],
        'only response start is sent initially');
    is($producer_calls, 0, 'producer waits for mapped start settlement');
    ok(!$decline->is_ready, 'decline awaits response start');

    $settlements[0]->done;
    is($sse->connection_state, 'closed',
        'successful mapped start settlement commits the response slot immediately');
    ok(!exists $sse->{_pending_keepalive}, 'start commitment discards deferred keepalive');
    is($close_calls, 0, 'close cleanup waits for response completion or failure');
    is($producer_calls, 1, 'producer starts after response start settles');
    is([map { $_->{body} // '<start>' } @sent], ['<start>', 'first'],
        'first chunk follows start');

    my $before_start = scalar @sent;
    ok($sse->start->get == $sse, 'live start is a no-op after decline commitment');
    is(scalar @sent, $before_start, 'no live start or keepalive follows committed decline');

    $settlements[1]->done;
    is([map { $_->{body} // '<start>' } @sent], ['<start>', 'first', 'second'],
        'second chunk waits for first chunk settlement');

    $settlements[2]->done;
    is($sent[-1], { type => 'sse.http.response.body', body => '', more => 0 },
        'terminal chunk waits for second chunk settlement');
    ok(!$decline->is_ready, 'decline awaits terminal send');
    $settlements[3]->done;
    my $returned = $decline->get;
    ok($returned == $sse, 'decline resolves after every send settles');
    is($close_calls, 1, 'successful decline runs close cleanup exactly once');
};

{
    package T::InvalidSSEResponse;
    use Future::AsyncAwait;
    use parent -norequire, 'PAGI::Response';
    sub new { return bless { events => $_[1] }, $_[0] }
    async sub respond {
        my ($self, $scope, $receive, $send) = @_;
        for my $event (@{$self->{events}}) {
            await $send->($event);
        }
        return;
    }

    package T::UnsupportedSSEResponse;
    use Future::AsyncAwait;
    use parent -norequire, 'PAGI::Response';
    our $calls = 0;
    sub protocol_response_capability { return undef }
    async sub respond {
        my ($self, @args) = @_;
        ++$calls;
        await $self->SUPER::respond(@args);
        return;
    }

    package T::SSEProducerFailureResponse;
    use Future::AsyncAwait;
    use parent -norequire, 'PAGI::Response';
    async sub respond {
        my ($self, $scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 503, headers => [] });
        die "producer failed after response start\n";
    }
}

subtest 'unsupported response capabilities fail before decline start' => sub {
    my ($fh, $path) = tempfile();
    print {$fh} 'file';
    close $fh;

    my @unsupported = (
        ['File response', PAGI::Response::File->new($path), qr/File/i],
        ['explicit custom opt-out', T::UnsupportedSSEResponse->new('opaque'), qr/capability/i],
    );

    for my $case (@unsupported) {
        my ($name, $response, $error) = @$case;
        subtest $name => sub {
            my @sent;
            local $T::UnsupportedSSEResponse::calls = 0;
            my $sse = sse(sse_scope(), sub { push @sent, $_[0]; Future->done });
            like(dies { $sse->decline($response)->get }, $error, 'unsupported response is rejected');
            is(\@sent, [], 'no protocol response event was sent');
            is($sse->connection_state, 'pending', 'request remains pending');
            is($T::UnsupportedSSEResponse::calls, 0,
                'unsupported custom delivery is rejected before invocation')
                if $name eq 'explicit custom opt-out';
        };
    }
};

subtest 'advertised invalid events fail before that event, without rolling back committed start' => sub {
    my @invalid = (
        ['declared trailers', T::InvalidSSEResponse->new([{
            type => 'http.response.start', status => 200, headers => [], trailers => 1,
        }]), qr/trailer/i, 0],
        ['fh body', T::InvalidSSEResponse->new([
            { type => 'http.response.start', status => 200, headers => [] },
            { type => 'http.response.body', fh => 'opaque', more => 0 },
        ]), qr/(?:fh|opaque|body)/i, 1],
        ['trailer event', T::InvalidSSEResponse->new([
            { type => 'http.response.start', status => 200, headers => [] },
            { type => 'http.response.trailers', headers => [] },
        ]), qr/trailer|event/i, 1],
        ['unknown event', T::InvalidSSEResponse->new([
            { type => 'http.response.start', status => 200, headers => [] },
            { type => 'http.response.push' },
        ]),
            qr/unknown|event/i, 1],
    );

    for my $case (@invalid) {
        my ($name, $response, $error, $start_commits) = @$case;
        subtest $name => sub {
            my @sent;
            my $close_calls = 0;
            my $sse = sse(sse_scope(), sub { push @sent, $_[0]; Future->done });
            $sse->on_close(sub { ++$close_calls });
            like(dies { $sse->decline($response)->get }, $error, 'invalid response is rejected');
            is([map { $_->{type} } @sent],
                $start_commits ? ['sse.http.response.start'] : [],
                'the invalid event itself never reaches the protocol send');
            is($sse->connection_state, $start_commits ? 'closed' : 'pending',
                'state reflects whether mapped start committed');
            is($close_calls, $start_commits ? 1 : 0,
                'close cleanup follows only a committed start');
        };
    }
};

subtest 'a producer failure after mapped start closes and cleans up exactly once' => sub {
    my @sent;
    my $close_calls = 0;
    my $sse = sse(sse_scope(), sub { push @sent, $_[0]; Future->done });
    $sse->on_close(sub { ++$close_calls });
    $sse->keepalive(13, 'pending')->get;

    like(dies { $sse->decline(T::SSEProducerFailureResponse->new('unused'))->get },
        qr/producer failed after response start/, 'producer failure reaches the caller');
    is([map { $_->{type} } @sent], ['sse.http.response.start'],
        'mapped start reached the protocol before the producer failed');
    is($sse->connection_state, 'closed', 'post-start producer failure cannot reopen the slot');
    is($close_calls, 1, 'post-start failure runs close cleanup exactly once');
    ok(!exists $sse->{_pending_keepalive}, 'post-start failure cannot preserve deferred keepalive');
    $sse->decline(PAGI::Response::Text->new('again'))->get;
    is($close_calls, 1, 'a repeated decline cannot repeat cleanup');
};

subtest 'a mapped body-send failure propagates and runs close cleanup exactly once' => sub {
    my @sent;
    my $close_calls = 0;
    my $sse = sse(sse_scope(), sub {
        push @sent, $_[0];
        return Future->done if $_[0]{type} eq 'sse.http.response.start';
        return Future->fail("decline body resource failed\n");
    });
    $sse->on_close(sub { ++$close_calls });

    like(dies { $sse->decline(PAGI::Response::Text->new('body'))->get },
        qr/decline body resource failed/, 'genuine body-send failure reaches the caller');
    is([map { $_->{type} } @sent], [
        'sse.http.response.start', 'sse.http.response.body',
    ], 'body send was attempted only after mapped start committed');
    is($sse->connection_state, 'closed', 'post-start send failure cannot reopen the slot');
    is($close_calls, 1, 'post-start send failure runs close cleanup exactly once');
};

subtest 'disconnect during a backpressured mapped body settles normally and cleans up' => sub {
    my $connection = PAGI::Test::ConnectionState->new;
    my @sent;
    my $body_send;
    my $body_cancelled = 0;
    my $close_calls = 0;
    my $stream = PAGI::Response::Stream->new(async sub {
        my ($writer) = @_;
        await $writer->write('pending');
    });
    my $sse = sse(sse_scope('pagi.connection' => $connection), sub {
        push @sent, $_[0];
        return Future->done if $_[0]{type} eq 'sse.http.response.start';
        $body_send = Future->new;
        $body_send->on_cancel(sub { $body_cancelled = 1 });
        return $body_send;
    });
    $sse->on_close(sub { ++$close_calls });

    my $decline = $sse->decline($stream);
    is([map { $_->{type} } @sent], [
        'sse.http.response.start', 'sse.http.response.body',
    ], 'the first body write is parked on the real mapped send');
    ok(!$decline->is_ready, 'decline remains pending on body backpressure');

    $connection->_mark_disconnected('client_closed');
    ok(!$body_send->is_ready, 'disconnect does not manufacture body-send settlement');
    ok(!$body_cancelled, 'disconnect never cancels the server-owned body send');
    $body_send->done;

    ok(lives { $decline->get }, 'successful post-disconnect settlement remains a normal outcome');
    is($body_cancelled, 0, 'mapped body send was awaited without cancellation');
    is($sse->connection_state, 'closed', 'decline remains committed after disconnect');
    is($close_calls, 1, 'disconnect outcome runs SSE close cleanup exactly once');
    is(scalar @sent, 2, 'disconnect suppresses terminal success without another send');
};

subtest 'decline accepts exactly one concrete Response and only before start' => sub {
    for my $arguments (
        [],
        [undef],
        [{}],
        ['status', 401],
        [PAGI::Response::Text->new('x'), 'extra'],
    ) {
        my @sent;
        my $sse = sse(sse_scope(), sub { push @sent, $_[0]; Future->done });
        like(dies { $sse->decline(@$arguments)->get }, qr/(?:one|PAGI::Response|concrete)/i,
            'invalid argument list is rejected');
        is(\@sent, [], 'invalid call sends nothing');
    }

    my @sent;
    my $sse = sse(sse_scope(), sub { push @sent, $_[0]; Future->done });
    $sse->start->get;
    like(dies { $sse->decline(PAGI::Response::Text->new('late'))->get },
        qr/(?:before start|pending)/i, 'decline after start fails');
    is([map { $_->{type} } @sent], ['sse.start'], 'late decline sends no response event');
    ok($sse->is_started, 'live stream remains started');
};

subtest 'decline drops deferred keepalive, closes once, and permits no live event afterward' => sub {
    my @sent;
    my $close_calls = 0;
    my $sse = sse(sse_scope(), sub { push @sent, $_[0]; Future->done });
    my $response = PAGI::Response::Text->new('Unauthorized', status => 401);
    $sse->on_close(sub { ++$close_calls; return Future->done });

    $sse->keepalive(25, 'pending')->get;
    is(\@sent, [], 'pre-start keepalive is deferred');
    $sse->decline($response)->get;
    $sse->decline($response)->get;

    is($close_calls, 1, 'close callbacks run exactly once');
    is([map { $_->{type} } @sent], [
        'sse.http.response.start', 'sse.http.response.body',
    ], 'repeat decline sends neither a duplicate response nor a keepalive');

    my $before = scalar @sent;
    ok($sse->send('x')->get == $sse, 'send is a post-decline no-op');
    ok($sse->send_json({ x => 1 })->get == $sse, 'send_json is a post-decline no-op');
    ok($sse->send_event(data => 'x')->get == $sse, 'send_event is a post-decline no-op');
    ok($sse->send_comment('x')->get == $sse, 'send_comment is a post-decline no-op');
    ok($sse->keepalive(10)->get == $sse, 'keepalive is a post-decline no-op');
    ok($sse->start->get == $sse, 'start is a post-decline no-op');
    ok($sse->close->get == $sse, 'close is a post-decline no-op');
    ok(lives { $sse->run->get }, 'run returns after decline');
    is(scalar @sent, $before, 'no live SSE event follows the terminal response body');
};

subtest 'an invalid decline preserves deferred keepalive and pending state' => sub {
    my @sent;
    my $sse = sse(sse_scope(), sub { push @sent, $_[0]; Future->done });
    $sse->keepalive(9, 'still-pending')->get;

    like(dies { $sse->decline(PAGI::Response::File->new(__FILE__))->get },
        qr/File/i, 'invalid response is rejected');
    is($sse->connection_state, 'pending', 'invalid decline leaves state pending');
    $sse->start->get;
    is([map { $_->{type} } @sent], ['sse.start', 'sse.keepalive'],
        'deferred keepalive still arms after invalid decline');
    is($sent[1]{interval}, 9, 'original deferred interval is retained');
};

subtest 'mapped start-send failure preserves pending state and deferred keepalive' => sub {
    my @sent;
    my $calls = 0;
    my $sse = sse(sse_scope(), sub {
        push @sent, $_[0];
        return ++$calls == 1
            ? Future->fail("decline transport failed\n")
            : Future->done;
    });
    $sse->keepalive(17, 'still-pending')->get;

    like(dies { $sse->decline(PAGI::Response::Text->new('no'))->get },
        qr/decline transport failed/, 'send failure reaches caller');
    is($sse->connection_state, 'pending', 'failed start does not claim the response slot');
    $sse->start->get;
    is([map { $_->{type} } @sent], [
        'sse.http.response.start', 'sse.start', 'sse.keepalive',
    ], 'live start remains available and arms the preserved keepalive');
    is($sent[-1]{interval}, 17, 'the original deferred interval is preserved');
};

subtest 'cancelling decline never cancels the server-owned send Future' => sub {
    my $send_future = Future->new;
    my $sse = sse(sse_scope(), sub { return $send_future });
    my $decline = $sse->decline(PAGI::Response::Text->new('pending'));

    $decline->cancel;
    ok($decline->is_cancelled, 'caller cancellation is observed by decline Future');
    ok(!$send_future->is_cancelled, 'pending server send remains owned by server');
    $send_future->done;
};

done_testing;
