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
        extensions => {},
        state      => { shared => 'state' },
        marker     => ['nested'],
        pagi => { spec_version => '0.6' }, 'pagi.connection' => PAGI::Test::ConnectionState->new(websocket => 1),
        %changes,
    };
}

sub receive { return sub { Future->done({ type => 'websocket.connect' }) } }

sub websocket {
    my ($scope, $send) = @_;
    my $connection = $scope->{'pagi.connection'};
    my $tracking_send = sub {
        my ($event) = @_;
        local $connection->{_defer_notifications} = 1 if $connection;
        my $result = Future->wrap($send->($event));
        return $result if $result->is_failed;
        $connection->_mark_response_started
            if $connection && ($event->{type} // '') =~ /^(?:http\.response\.start|sse\.start|websocket\.accept)$/;
        $connection->_mark_complete
            if $connection && ($event->{type} // '') eq 'http.response.body'
                && !$event->{more};
        return $result;
    };
    return PAGI::WebSocket->new($scope, receive(), $tracking_send);
}

my $redirect_body = '<!doctype html><html><head><title>Found</title></head><body><p>Redirecting to <a href="/next">/next</a>.</p></body></html>';

my @matrix = (
    [
        base => PAGI::Response->new('raw', status => 418, headers => ['X-Kind' => 'base']),
        [
            {
                type => 'http.response.start', status => 418,
                headers => [
                    ['X-Kind' => 'base'],
                    ['Content-Type' => 'application/octet-stream'],
                    ['content-length' => 3],
                ],
            },
            { type => 'http.response.body', body => 'raw', more => 0 },
        ],
    ],
    [
        Text => PAGI::Response::Text->new('text', status => 403),
        [
            {
                type => 'http.response.start', status => 403,
                headers => [
                    ['Content-Type' => 'text/plain; charset=utf-8'],
                    ['content-length' => 4],
                ],
            },
            { type => 'http.response.body', body => 'text', more => 0 },
        ],
    ],
    [
        HTML => PAGI::Response::HTML->new('<b>x</b>', status => 403),
        [
            {
                type => 'http.response.start', status => 403,
                headers => [
                    ['Content-Type' => 'text/html; charset=utf-8'],
                    ['content-length' => 8],
                ],
            },
            { type => 'http.response.body', body => '<b>x</b>', more => 0 },
        ],
    ],
    [
        JSON => PAGI::Response::JSON->new([1], status => 403),
        [
            {
                type => 'http.response.start', status => 403,
                headers => [
                    ['Content-Type' => 'application/json'],
                    ['content-length' => 3],
                ],
            },
            { type => 'http.response.body', body => '[1]', more => 0 },
        ],
    ],
    [
        Problem => PAGI::Response::Problem->new({ status => 409 }),
        [
            {
                type => 'http.response.start', status => 409,
                headers => [
                    ['Content-Type' => 'application/problem+json'],
                    ['content-length' => 14],
                ],
            },
            { type => 'http.response.body', body => '{"status":409}', more => 0 },
        ],
    ],
    [
        Redirect => PAGI::Response::Redirect->new('/next'),
        [
            {
                type => 'http.response.start', status => 302,
                headers => [
                    ['Content-Type' => 'text/html; charset=utf-8'],
                    ['Location' => '/next'],
                    ['content-length' => length($redirect_body)],
                ],
            },
            { type => 'http.response.body', body => $redirect_body, more => 0 },
        ],
    ],
    [
        Empty => PAGI::Response::Empty->new(status => 403),
        [
            { type => 'http.response.start', status => 403,
              headers => [['content-length', 0]] },
            { type => 'http.response.body', body => '', more => 0 },
        ],
    ],
    [
        Stream => PAGI::Response::Stream->new(async sub {
            my ($writer) = @_;
            await $writer->write('one');
            await $writer->write('two');
        }, status => 403, content_type => 'application/x-stream'),
        [
            {
                type => 'http.response.start', status => 403,
                headers => [['Content-Type' => 'application/x-stream']],
            },
            { type => 'http.response.body', body => 'one', more => 1 },
            { type => 'http.response.body', body => 'two', more => 1 },
            { type => 'http.response.body', body => '', more => 0 },
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
            ok($sent[0]{status} >= 300,
                'successful WebSocket refusal uses a legal status');
            is(\@sent, $expected, 'maps start/body fields, order, and more exactly');
            ok($ws->is_closed, 'denial closes the handshake');
            is($ws->close_code, 1006, 'HTTP denial records local no-peer Close metadata');
        };
    }
};

subtest 'deny emits File directly with an ordinary HTTP file body' => sub {
    my ($fh, $path) = tempfile();
    print {$fh} 'file refusal';
    close $fh;
    my @sent;
    my $ws = websocket(ws_scope(), sub { push @sent, $_[0]; Future->done });
    $ws->deny(PAGI::Response::File->new($path, status => 403))->get;
    is($sent[0]{type}, 'http.response.start', 'ordinary HTTP start');
    is($sent[0]{status}, 403, 'WebSocket refusal status is valid');
    is($sent[1]{type}, 'http.response.body', 'ordinary HTTP body');
    is($sent[1]{file}, $path, 'file body is preserved');
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

subtest 'Response receives the original WebSocket scope unchanged' => sub {
    my $scope = ws_scope();
    my $state = $scope->{state};
    my $marker = $scope->{marker};
    my @sent;
    my $ws = websocket($scope, sub { push @sent, $_[0]; Future->done });

    $ws->deny(T::ScopeResponse->new('scope', status => 403))->get;

    is(refaddr($T::ScopeResponse::seen_scope), refaddr($scope),
        'Response sees the original scope');
    is($T::ScopeResponse::seen_scope->{type}, 'websocket', 'scope type stays WebSocket');
    is($T::ScopeResponse::seen_scope->{method}, 'POST', 'scope method is unchanged');
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

 subtest 'an inherited Stream reaches original sends incrementally and observes server progress' => sub {
    my @sent;
    my @settlements;
    my $producer_calls = 0;
    my $stream = T::InheritedProtocolStream->new(async sub {
        my ($writer) = @_;
        ++$producer_calls;
        await $writer->write('first');
        await $writer->write('second');
    }, status => 403);
    my $ws = websocket(ws_scope(), sub {
        push @sent, $_[0];
        return Future->done if $_[0]{type} eq 'websocket.accept';
        my $settlement = Future->new;
        push @settlements, $settlement;
        return $settlement;
    });

    my $denial = $ws->deny($stream);
    is([map { $_->{type} } @sent], ['http.response.start'],
        'only response start is sent initially');
    is($producer_calls, 0, 'producer waits for ordinary start settlement');
    ok(!$denial->is_ready, 'deny awaits response start');

    $settlements[0]->done;
    ok($ws->scope->{'pagi.connection'}->response_started,
        'committed response slot remains nonterminal while body is pending');
    is($producer_calls, 1, 'producer starts after response start settles');
    is([map { $_->{body} // '<start>' } @sent], ['<start>', 'first'],
        'first chunk follows start');

    my $before_accept = scalar @sent;
    my $accept = $ws->accept;
    ok($accept->is_ready, 'accept is an immediate no-op after denial commitment');
    is(scalar @sent, $before_accept, 'accept cannot send after denial commitment');
    like(dies { $ws->deny(PAGI::Response::Text->new('again'))->get },
        qr/no response started/i, 'a second denial cannot claim the committed slot');

    $settlements[1]->done;
    is([map { $_->{body} // '<start>' } @sent], ['<start>', 'first', 'second'],
        'second chunk waits for first chunk settlement');

    $settlements[2]->done;
    is($sent[-1], { type => 'http.response.body', body => '', more => 0 },
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

  subtest 'a producer failure after ordinary start propagates and leaves denial committed' => sub {
    my @sent;
    my $ws = websocket(ws_scope(), sub { push @sent, $_[0]; Future->done });

    like(dies { $ws->deny(T::ProducerFailureResponse->new('unused'))->get },
        qr/producer failed after response start/, 'producer failure reaches the caller');
    is([map { $_->{type} } @sent], ['http.response.start'],
        'ordinary start reached the protocol before the producer failed');
    ok($ws->scope->{'pagi.connection'}->response_started, 'post-start producer failure cannot reopen the slot');
};

subtest 'an ordinary body-send failure propagates and leaves denial committed' => sub {
    my @sent;
    my $ws = websocket(ws_scope(), sub {
        push @sent, $_[0];
        return Future->done if $_[0]{type} eq 'http.response.start';
        return Future->fail("denial body resource failed\n");
    });

    like(dies { $ws->deny(PAGI::Response::Text->new('body', status => 403))->get },
        qr/denial body resource failed/, 'genuine body-send failure reaches the caller');
    is([map { $_->{type} } @sent], [
        'http.response.start', 'http.response.body',
    ], 'body send was attempted only after ordinary start committed');
    ok($ws->scope->{'pagi.connection'}->response_started, 'post-start send failure cannot reopen the slot');
};

subtest 'disconnect during a backpressured ordinary body settles normally' => sub {
    my $connection = PAGI::Test::ConnectionState->new;
    my @sent;
    my $body_send;
    my $body_cancelled = 0;
    my $stream = PAGI::Response::Stream->new(async sub {
        my ($writer) = @_;
        await $writer->write('pending');
    }, status => 403);
    my $ws = websocket(ws_scope(pagi => { spec_version => '0.6' }, 'pagi.connection' => $connection), sub {
        push @sent, $_[0];
        return Future->done if $_[0]{type} eq 'http.response.start';
        $body_send = Future->new;
        $body_send->on_cancel(sub { $body_cancelled = 1 });
        return $body_send;
    });

    my $denial = $ws->deny($stream);
    is([map { $_->{type} } @sent], [
        'http.response.start', 'http.response.body',
    ], 'the first body write is parked on the original send');
    ok(!$denial->is_ready, 'denial remains pending on body backpressure');

    $connection->_mark_disconnected('client_closed');
    ok(!$body_send->is_ready, 'disconnect does not manufacture body-send settlement');
    ok(!$body_cancelled, 'disconnect never cancels the server-owned body send');
    $body_send->done;

    ok(lives { $denial->get }, 'successful post-disconnect settlement remains a normal outcome');
    is($body_cancelled, 0, 'ordinary body send was awaited without cancellation');
    is($ws->connection_state, 'closed', 'denial remains committed after disconnect');
    is(scalar @sent, 2, 'disconnect suppresses terminal success without another send');
};

subtest 'deny accepts exactly one Request handler or app object and only while connecting' => sub {
    for my $arguments (
        [],
        [undef],
        [{}],
        ['status', 401],
        [PAGI::Response::Text->new('x'), 'extra'],
    ) {
        my @sent;
        my $ws = websocket(ws_scope(), sub { push @sent, $_[0]; Future->done });
        like(dies { $ws->deny(@$arguments)->get }, qr/(?:one|Request handler|app object)/i,
            'invalid argument list is rejected');
        is(\@sent, [], 'invalid call sends nothing');
    }

    my @sent;
    my $ws = websocket(ws_scope(), sub { push @sent, $_[0]; Future->done });
    $ws->accept->get;
    like(dies { $ws->deny(PAGI::Response::Text->new('late'))->get },
        qr/no response started/i, 'denial after accept fails');
    is([map { $_->{type} } @sent], ['websocket.accept'], 'late denial sends no response event');
    ok($ws->is_connected, 'accepted connection remains connected');
};

 subtest 'ordinary start-send failure preserves the connecting state' => sub {
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
        'http.response.start', 'websocket.accept',
    ], 'accept remains available after pre-commit failure');
    ok($ws->is_connected, 'successful accept establishes the still-live connection');
};

# Handler, buffered and Stream cancellation boundaries are covered for both
# protocols in t/protocol-refusal-applications.t.

done_testing;
