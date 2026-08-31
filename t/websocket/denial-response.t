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
use PAGI::Test::ConnectionState;
use PAGI::WebSocket;

sub ws_scope {
    my (%changes) = @_;
    return {
        type       => 'websocket',
        method     => 'POST',
        path       => '/socket',
        headers    => [],
        extensions => { 'websocket.http.response' => {} },
        state      => { shared => 'state' },
        marker     => ['nested'],
        %changes,
    };
}

sub receive { return sub { Future->done({ type => 'websocket.connect' }) } }

sub websocket {
    my ($scope, $send) = @_;
    return PAGI::WebSocket->new($scope, receive(), $send);
}

my $redirect_body = '<!doctype html><html><head><title>Found</title></head><body><p>Redirecting to <a href="/next">/next</a>.</p></body></html>';

my @matrix = (
    [
        base => PAGI::Response->new('raw', status => 418, headers => ['X-Kind' => 'base']),
        [
            {
                type => 'websocket.http.response.start', status => 418,
                headers => [
                    ['X-Kind' => 'base'],
                    ['Content-Type' => 'application/octet-stream'],
                    ['content-length' => 3],
                ],
            },
            { type => 'websocket.http.response.body', body => 'raw', more => 0 },
        ],
    ],
    [
        Text => PAGI::Response::Text->new('text'),
        [
            {
                type => 'websocket.http.response.start', status => 200,
                headers => [
                    ['Content-Type' => 'text/plain; charset=utf-8'],
                    ['content-length' => 4],
                ],
            },
            { type => 'websocket.http.response.body', body => 'text', more => 0 },
        ],
    ],
    [
        HTML => PAGI::Response::HTML->new('<b>x</b>'),
        [
            {
                type => 'websocket.http.response.start', status => 200,
                headers => [
                    ['Content-Type' => 'text/html; charset=utf-8'],
                    ['content-length' => 8],
                ],
            },
            { type => 'websocket.http.response.body', body => '<b>x</b>', more => 0 },
        ],
    ],
    [
        JSON => PAGI::Response::JSON->new([1]),
        [
            {
                type => 'websocket.http.response.start', status => 200,
                headers => [
                    ['Content-Type' => 'application/json'],
                    ['content-length' => 3],
                ],
            },
            { type => 'websocket.http.response.body', body => '[1]', more => 0 },
        ],
    ],
    [
        Problem => PAGI::Response::Problem->new({ status => 409 }),
        [
            {
                type => 'websocket.http.response.start', status => 409,
                headers => [
                    ['Content-Type' => 'application/problem+json'],
                    ['content-length' => 14],
                ],
            },
            { type => 'websocket.http.response.body', body => '{"status":409}', more => 0 },
        ],
    ],
    [
        Redirect => PAGI::Response::Redirect->new('/next'),
        [
            {
                type => 'websocket.http.response.start', status => 302,
                headers => [
                    ['Content-Type' => 'text/html; charset=utf-8'],
                    ['Location' => '/next'],
                    ['content-length' => length($redirect_body)],
                ],
            },
            { type => 'websocket.http.response.body', body => $redirect_body, more => 0 },
        ],
    ],
    [
        Empty => PAGI::Response::Empty->new,
        [
            { type => 'websocket.http.response.start', status => 204, headers => [] },
            { type => 'websocket.http.response.body', body => '', more => 0 },
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
                type => 'websocket.http.response.start', status => 200,
                headers => [['Content-Type' => 'application/x-stream']],
            },
            { type => 'websocket.http.response.body', body => 'one', more => 1 },
            { type => 'websocket.http.response.body', body => 'two', more => 1 },
            { type => 'websocket.http.response.body', body => '', more => 0 },
        ],
    ],
);

subtest 'deny adapts the complete concrete Response matrix exactly' => sub {
    for my $case (@matrix) {
        my ($name, $response, $expected) = @$case;
        subtest $name => sub {
            my @sent;
            my $scope = ws_scope();
            my $ws = websocket($scope, sub { push @sent, $_[0]; Future->done });

            my $returned = $ws->deny($response)->get;
            ok($returned == $ws, 'returns the WebSocket');
            is(\@sent, $expected, 'maps start/body fields, order, and more exactly');
            ok($ws->is_closed, 'denial closes the handshake');
            is($ws->close_code, undef, 'HTTP denial has no WebSocket close code');
        };
    }
};

subtest 'one Response value can be reused for independent denials' => sub {
    my $response = PAGI::Response::Text->new('reused', status => 401);
    my @invocations;

    for (1 .. 2) {
        my @sent;
        my $ws = websocket(ws_scope(), sub { push @sent, $_[0]; Future->done });
        $ws->deny($response)->get;
        push @invocations, \@sent;
    }

    is($invocations[0], $invocations[1], 'unchanged response emits identically twice');
    is($response->status, 401, 'response status remains reusable');
    is($response->body, 'reused', 'response body remains reusable');
};

{
    package T::ScopeResponse;
    use Future::AsyncAwait;
    use parent -norequire, 'PAGI::Response';
    our $seen_scope;
    async sub _emit {
        my ($self, $scope, $receive, $send) = @_;
        $seen_scope = $scope;
        await $self->SUPER::_emit($scope, $receive, $send);
        return;
    }
}

subtest 'Response receives a shallow HTTP scope clone without protocol mutation' => sub {
    my $scope = ws_scope();
    my $state = $scope->{state};
    my $marker = $scope->{marker};
    my @sent;
    my $ws = websocket($scope, sub { push @sent, $_[0]; Future->done });

    $ws->deny(T::ScopeResponse->new('scope'))->get;

    isnt(refaddr($T::ScopeResponse::seen_scope), refaddr($scope),
        'Response sees a distinct top-level hash');
    is($T::ScopeResponse::seen_scope->{type}, 'http', 'clone type is HTTP');
    is($T::ScopeResponse::seen_scope->{method}, 'GET', 'clone method is GET');
    is($T::ScopeResponse::seen_scope->{path}, '/socket', 'unrelated scalar fields are retained');
    is(refaddr($T::ScopeResponse::seen_scope->{state}), refaddr($state),
        'nested state reference is identical');
    is(refaddr($T::ScopeResponse::seen_scope->{marker}), refaddr($marker),
        'other nested references are identical');
    is($scope->{type}, 'websocket', 'live protocol scope type is unchanged');
    is($scope->{method}, 'POST', 'live protocol scope method is unchanged');
};

{
    package T::InheritedProtocolStream;
    use parent -norequire, 'PAGI::Response::Stream';
}

subtest 'protocol response capability is inherited without implying buffering' => sub {
    is(PAGI::Response->new('base')->protocol_response_capability,
        'body-events-v1', 'base advertises the versioned byte-body capability');
    is(PAGI::Response::Stream->new(sub {})->protocol_response_capability,
        'body-events-v1', 'Stream inherits the byte-body capability');
    is(T::InheritedProtocolStream->new(sub {})->protocol_response_capability,
        'body-events-v1', 'a delivery-preserving Stream subclass inherits it');
    is(PAGI::Response::File->new(__FILE__)->protocol_response_capability,
        undef, 'File explicitly opts out of denial-body delivery');
};

subtest 'an inherited Stream reaches mapped sends incrementally and commits at start settlement' => sub {
    my @sent;
    my @settlements;
    my $producer_calls = 0;
    my $stream = T::InheritedProtocolStream->new(async sub {
        my ($writer) = @_;
        ++$producer_calls;
        await $writer->write('first');
        await $writer->write('second');
    });
    my $ws = websocket(ws_scope(), sub {
        push @sent, $_[0];
        return Future->done if $_[0]{type} eq 'websocket.accept';
        my $settlement = Future->new;
        push @settlements, $settlement;
        return $settlement;
    });

    my $denial = $ws->deny($stream);
    is([map { $_->{type} } @sent], ['websocket.http.response.start'],
        'only response start is sent initially');
    is($producer_calls, 0, 'producer waits for mapped start settlement');
    ok(!$denial->is_ready, 'deny awaits response start');

    $settlements[0]->done;
    is($ws->connection_state, 'closed',
        'successful mapped start settlement commits the response slot immediately');
    is($producer_calls, 1, 'producer starts after response start settles');
    is([map { $_->{body} // '<start>' } @sent], ['<start>', 'first'],
        'first chunk follows start');

    my $before_accept = scalar @sent;
    my $accept = $ws->accept;
    ok($accept->is_ready, 'accept is an immediate no-op after denial commitment');
    is(scalar @sent, $before_accept, 'accept cannot send after denial commitment');
    like(dies { $ws->deny(PAGI::Response::Text->new('again'))->get },
        qr/(?:connecting|before accept)/i, 'a second denial cannot claim the committed slot');

    $settlements[1]->done;
    is([map { $_->{body} // '<start>' } @sent], ['<start>', 'first', 'second'],
        'second chunk waits for first chunk settlement');

    $settlements[2]->done;
    is($sent[-1], { type => 'websocket.http.response.body', body => '', more => 0 },
        'terminal chunk waits for second chunk settlement');
    ok(!$denial->is_ready, 'deny awaits terminal send');
    $settlements[3]->done;
    my $returned = $denial->get;
    ok($returned == $ws, 'deny resolves after every send settles');
};

{
    package T::InvalidProtocolResponse;
    use Future::AsyncAwait;
    use parent -norequire, 'PAGI::Response';
    sub new { return bless { events => $_[1] }, $_[0] }
    async sub _emit {
        my ($self, $scope, $receive, $send) = @_;
        for my $event (@{$self->{events}}) {
            await $send->($event);
        }
        return;
    }

    package T::UnsupportedProtocolResponse;
    use Future::AsyncAwait;
    use parent -norequire, 'PAGI::Response';
    our $calls = 0;
    sub protocol_response_capability { return undef }
    async sub _emit {
        my ($self, @args) = @_;
        ++$calls;
        await $self->SUPER::_emit(@args);
        return;
    }

    package T::ProducerFailureResponse;
    use Future::AsyncAwait;
    use parent -norequire, 'PAGI::Response';
    async sub _emit {
        my ($self, $scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 503, headers => [] });
        die "producer failed after response start\n";
    }

    package T::ExplodingResponse;
    use Future::AsyncAwait;
    use parent -norequire, 'PAGI::Response';
    our $calls = 0;
    async sub _emit { ++$calls; die "custom response was invoked\n" }
}

subtest 'unsupported response capabilities fail before denial start' => sub {
    my ($fh, $path) = tempfile();
    print {$fh} 'file';
    close $fh;

    my @unsupported = (
        ['File response', PAGI::Response::File->new($path), qr/File/i],
        ['explicit custom opt-out', T::UnsupportedProtocolResponse->new('opaque'), qr/capability/i],
    );

    for my $case (@unsupported) {
        my ($name, $response, $error) = @$case;
        subtest $name => sub {
            my @sent;
            local $T::UnsupportedProtocolResponse::calls = 0;
            my $ws = websocket(ws_scope(), sub { push @sent, $_[0]; Future->done });
            like(dies { $ws->deny($response)->get }, $error, 'unsupported response is rejected');
            is(\@sent, [], 'no protocol response event was sent');
            is($ws->connection_state, 'connecting', 'handshake state remains live');
            is($T::UnsupportedProtocolResponse::calls, 0,
                'unsupported custom delivery is rejected before invocation')
                if $name eq 'explicit custom opt-out';
        };
    }
};

subtest 'advertised invalid events fail before that event, without rolling back committed start' => sub {
    my @invalid = (
        ['declared trailers', T::InvalidProtocolResponse->new([{
            type => 'http.response.start', status => 200, headers => [], trailers => 1,
        }]), qr/trailer/i, 0],
        ['fh body', T::InvalidProtocolResponse->new([
            { type => 'http.response.start', status => 200, headers => [] },
            { type => 'http.response.body', fh => 'opaque', more => 0 },
        ]), qr/(?:fh|opaque|body)/i, 1],
        ['trailer event', T::InvalidProtocolResponse->new([
            { type => 'http.response.start', status => 200, headers => [] },
            { type => 'http.response.trailers', headers => [] },
        ]), qr/trailer|event/i, 1],
        ['unknown event', T::InvalidProtocolResponse->new([
            { type => 'http.response.start', status => 200, headers => [] },
            { type => 'http.response.push' },
        ]),
            qr/unknown|event/i, 1],
    );

    for my $case (@invalid) {
        my ($name, $response, $error, $start_commits) = @$case;
        subtest $name => sub {
            my @sent;
            my $ws = websocket(ws_scope(), sub { push @sent, $_[0]; Future->done });
            like(dies { $ws->deny($response)->get }, $error, 'invalid response is rejected');
            is([map { $_->{type} } @sent],
                $start_commits ? ['websocket.http.response.start'] : [],
                'the invalid event itself never reaches the protocol send');
            is($ws->connection_state, $start_commits ? 'closed' : 'connecting',
                'state reflects whether mapped start committed');
        };
    }
};

subtest 'a producer failure after mapped start propagates and leaves denial committed' => sub {
    my @sent;
    my $ws = websocket(ws_scope(), sub { push @sent, $_[0]; Future->done });

    like(dies { $ws->deny(T::ProducerFailureResponse->new('unused'))->get },
        qr/producer failed after response start/, 'producer failure reaches the caller');
    is([map { $_->{type} } @sent], ['websocket.http.response.start'],
        'mapped start reached the protocol before the producer failed');
    is($ws->connection_state, 'closed', 'post-start producer failure cannot reopen the slot');
};

subtest 'a mapped body-send failure propagates and leaves denial committed' => sub {
    my @sent;
    my $ws = websocket(ws_scope(), sub {
        push @sent, $_[0];
        return Future->done if $_[0]{type} eq 'websocket.http.response.start';
        return Future->fail("denial body resource failed\n");
    });

    like(dies { $ws->deny(PAGI::Response::Text->new('body'))->get },
        qr/denial body resource failed/, 'genuine body-send failure reaches the caller');
    is([map { $_->{type} } @sent], [
        'websocket.http.response.start', 'websocket.http.response.body',
    ], 'body send was attempted only after mapped start committed');
    is($ws->connection_state, 'closed', 'post-start send failure cannot reopen the slot');
};

subtest 'disconnect during a backpressured mapped body settles normally' => sub {
    my $connection = PAGI::Test::ConnectionState->new;
    my @sent;
    my $body_send;
    my $body_cancelled = 0;
    my $stream = PAGI::Response::Stream->new(async sub {
        my ($writer) = @_;
        await $writer->write('pending');
    });
    my $ws = websocket(ws_scope('pagi.connection' => $connection), sub {
        push @sent, $_[0];
        return Future->done if $_[0]{type} eq 'websocket.http.response.start';
        $body_send = Future->new;
        $body_send->on_cancel(sub { $body_cancelled = 1 });
        return $body_send;
    });

    my $denial = $ws->deny($stream);
    is([map { $_->{type} } @sent], [
        'websocket.http.response.start', 'websocket.http.response.body',
    ], 'the first body write is parked on the real mapped send');
    ok(!$denial->is_ready, 'denial remains pending on body backpressure');

    $connection->_mark_disconnected('client_closed');
    ok(!$body_send->is_ready, 'disconnect does not manufacture body-send settlement');
    ok(!$body_cancelled, 'disconnect never cancels the server-owned body send');
    $body_send->done;

    ok(lives { $denial->get }, 'successful post-disconnect settlement remains a normal outcome');
    is($body_cancelled, 0, 'mapped body send was awaited without cancellation');
    is($ws->connection_state, 'closed', 'denial remains committed after disconnect');
    is(scalar @sent, 2, 'disconnect suppresses terminal success without another send');
};

subtest 'deny accepts exactly one concrete Response and only while connecting' => sub {
    for my $arguments (
        [],
        [undef],
        [{}],
        ['status', 401],
        [PAGI::Response::Text->new('x'), 'extra'],
    ) {
        my @sent;
        my $ws = websocket(ws_scope(), sub { push @sent, $_[0]; Future->done });
        like(dies { $ws->deny(@$arguments)->get }, qr/(?:one|PAGI::Response|concrete)/i,
            'invalid argument list is rejected');
        is(\@sent, [], 'invalid call sends nothing');
    }

    my @sent;
    my $ws = websocket(ws_scope(), sub { push @sent, $_[0]; Future->done });
    $ws->accept->get;
    like(dies { $ws->deny(PAGI::Response::Text->new('late'))->get },
        qr/(?:before accept|connecting)/i, 'denial after accept fails');
    is([map { $_->{type} } @sent], ['websocket.accept'], 'late denial sends no response event');
    ok($ws->is_connected, 'accepted connection remains connected');
};

subtest 'without the extension deny uses policy-close and never invokes the custom Response' => sub {
    my @sent;
    my $scope = ws_scope(extensions => {});
    my $ws = websocket($scope, sub { push @sent, $_[0]; Future->done });
    local $T::ExplodingResponse::calls = 0;

    my $returned = $ws->deny(bless({}, 'T::ExplodingResponse'))->get;
    ok($returned == $ws, 'fallback resolves with WebSocket');
    is($T::ExplodingResponse::calls, 0, 'custom response body is ignored');
    is(\@sent, [{ type => 'websocket.close', code => 1008, reason => '' }],
        'fallback is exactly one policy-close event');
    ok($ws->is_closed, 'fallback closes the connection');
    is($ws->close_code, 1008, 'fallback records policy close code');
};

subtest 'mapped start-send failure preserves the connecting state' => sub {
    my @sent;
    my $calls = 0;
    my $ws = websocket(ws_scope(), sub {
        push @sent, $_[0];
        return ++$calls == 1
            ? Future->fail("denial transport failed\n")
            : Future->done;
    });

    like(dies { $ws->deny(PAGI::Response::Text->new('no'))->get },
        qr/denial transport failed/, 'send failure reaches caller');
    is($ws->connection_state, 'connecting', 'failed start does not claim the response slot');
    $ws->accept->get;
    is([map { $_->{type} } @sent], [
        'websocket.http.response.start', 'websocket.accept',
    ], 'accept remains available after pre-commit failure');
    ok($ws->is_connected, 'successful accept establishes the still-live connection');
};

subtest 'pending denial start reserves the first-event slot' => sub {
    my @claimants = (
        accept => sub { $_[0]->accept },
        close  => sub { $_[0]->close },
        deny   => sub { $_[0]->deny(PAGI::Response::Text->new('competing')) },
    );

    while (@claimants) {
        my ($name, $claim) = splice @claimants, 0, 2;
        my @sent;
        my $start = Future->new;
        my $ws = websocket(ws_scope(), sub {
            push @sent, $_[0];
            return $start if $_[0]{type} eq 'websocket.http.response.start';
            return Future->done;
        });
        my $denial = $ws->deny(PAGI::Response::Text->new('reserved'));

        is($ws->connection_state, 'denying', 'pending start has a distinct reserved state');
        like(dies { $claim->($ws)->get }, qr/denial response.*pending/i,
            "$name fails locally while denial owns the response slot");
        is([map { $_->{type} } @sent], ['websocket.http.response.start'],
            "$name emits no competing first event");

        $start->fail("controlled denial start failure\n");
        like(dies { $denial->get }, qr/controlled denial start failure/,
            'the genuine pre-commit send failure reaches the observer');
        is($ws->connection_state, 'connecting',
            'a genuine pre-commit failure releases the reservation');
    }
};

subtest 'cancelling deny during start leaves the retained lifecycle authoritative' => sub {
    my @sent;
    my $start = Future->new;
    my $start_cancelled = 0;
    my $close_calls = 0;
    $start->on_cancel(sub { ++$start_cancelled });
    my $ws = websocket(ws_scope(), sub {
        push @sent, $_[0];
        return $start if $_[0]{type} eq 'websocket.http.response.start';
        return Future->done;
    });
    $ws->on_close(sub { ++$close_calls });
    my $denial = $ws->deny(PAGI::Response::Text->new('pending'));

    $denial->cancel;
    ok($denial->is_cancelled, 'caller cancellation settles only the public observer');
    is($start_cancelled, 0, 'caller cancellation never cancels the start send');
    is($ws->connection_state, 'denying', 'the response slot remains reserved');
    like(dies { $ws->accept->get }, qr/denial response.*pending/i,
        'accept cannot claim the reserved slot');
    is(scalar @sent, 1, 'no competing event was sent');

    $start->done;
    is([map { $_->{type} } @sent], [
        'websocket.http.response.start', 'websocket.http.response.body',
    ], 'retained lifecycle emits the terminal buffered body after start settles');
    is($ws->connection_state, 'closed', 'start settlement commits and closes denial');
    is($close_calls, 1, 'denial cleanup runs exactly once after cancellation');
    ok(!exists $ws->{_response_lifecycle}, 'completed lifecycle releases its retention slot');
};

subtest 'cancelling deny during a body send preserves producer and cleanup ownership' => sub {
    my @sent;
    my $body_send = Future->new;
    my $body_cancelled = 0;
    my $writer_cleanup = 0;
    my $close_calls = 0;
    $body_send->on_cancel(sub { ++$body_cancelled });
    my $stream = PAGI::Response::Stream->new(async sub {
        my ($writer) = @_;
        $writer->on_close(sub { ++$writer_cleanup });
        await $writer->write('pending');
    });
    my $ws = websocket(ws_scope(), sub {
        push @sent, $_[0];
        return $body_send
            if $_[0]{type} eq 'websocket.http.response.body' && $_[0]{more};
        return Future->done;
    });
    $ws->on_close(sub { ++$close_calls });
    my $denial = $ws->deny($stream);

    is([map { $_->{type} } @sent], [
        'websocket.http.response.start', 'websocket.http.response.body',
    ], 'stream is parked in its first mapped body send');
    $denial->cancel;
    is($body_cancelled, 0, 'public cancellation never cancels the body send');
    my $before = scalar @sent;
    $ws->accept->get;
    like(dies { $ws->deny(PAGI::Response::Text->new('again'))->get },
        qr/(?:connecting|before accept)/i, 'a competing denial cannot follow commitment');
    is(scalar @sent, $before, 'committed denial admits no competing event');

    $body_send->done;
    is($sent[-1], {
        type => 'websocket.http.response.body', body => '', more => 0,
    }, 'retained producer still applies the normal terminal-body policy');
    is($body_cancelled, 0, 'body settlement path never cancels the send');
    is($writer_cleanup, 1, 'Stream Writer cleanup runs exactly once');
    is($close_calls, 1, 'WebSocket denial cleanup runs exactly once');
    is($ws->connection_state, 'closed', 'denial remains closed');
};

subtest 'cancelling policy-close fallback retains send and cleanup ownership' => sub {
    my @sent;
    my $close_send = Future->new;
    my $close_cancelled = 0;
    my $close_calls = 0;
    $close_send->on_cancel(sub { ++$close_cancelled });
    my $ws = websocket(ws_scope(extensions => {}), sub {
        push @sent, $_[0];
        return $close_send;
    });
    $ws->on_close(sub { ++$close_calls });
    my $denial = $ws->deny(PAGI::Response::Text->new('ignored'));

    $denial->cancel;
    is($close_cancelled, 0, 'fallback send remains server-owned');
    is($ws->connection_state, 'denying', 'fallback reserves the response slot');
    like(dies { $ws->accept->get }, qr/denial response.*pending/i,
        'accept fails locally while the fallback is pending');
    is(scalar @sent, 1, 'fallback cancellation sends no competing event');

    $close_send->done;
    is($ws->connection_state, 'closed', 'fallback eventually closes');
    is($ws->close_code, 1008, 'fallback retains its policy close code');
    is($close_calls, 1, 'fallback cleanup runs exactly once');
    is($close_cancelled, 0, 'fallback settlement never cancels the send');
};

subtest 'supports_denial_response reports the advertised extension' => sub {
    my $with = websocket(ws_scope(), sub { Future->done });
    ok($with->supports_denial_response, 'extension is reported');

    my $without = websocket(ws_scope(extensions => {}), sub { Future->done });
    ok(!$without->supports_denial_response, 'missing extension is reported false');

    my $none = websocket(ws_scope(extensions => undef), sub { Future->done });
    ok(!$none->supports_denial_response, 'undefined extensions are reported false');
};

done_testing;
