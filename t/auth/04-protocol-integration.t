#!/usr/bin/env perl
use strict;
use warnings;

use Future;
use Scalar::Util qw(weaken);
use Future::AsyncAwait;
use Test2::V0;

use lib 'lib';
use PAGI::Auth qw(challenge basic bearer);
use PAGI::Compose qw(compose);
use PAGI::Pages;
use PAGI::Response::File;
use PAGI::Response::Stream;
use PAGI::Routing qw(route sse websocket);
use PAGI::SSE;
use PAGI::Test::Client;
use PAGI::Test::ConnectionState;
use PAGI::Test::Response;
use PAGI::Utils qw(invoke_app);
use PAGI::WebSocket;

sub mapped_response {
    my ($protocol, $events) = @_;
    return PAGI::Test::Response->new(events => $events);
}

sub protocol_scope {
    my ($type, %changes) = @_;
    return {
        type         => $type,
        pagi         => { version => '0.5', spec_version => '0.6' },
        method       => 'GET',
        path         => $type eq 'websocket' ? '/socket' : '/events',
        headers      => [],
        query_string => '',
        extensions   => {},
        'pagi.connection' => PAGI::Test::ConnectionState->new(
            websocket => $type eq 'websocket',
        ),
        %changes,
    };
}

sub direct_protocol {
    my ($type, $send, %changes) = @_;
    my $scope = protocol_scope($type, %changes);
    my $connection = $scope->{'pagi.connection'};
    my $tracking_send = async sub {
        my ($event) = @_;
        await Future->wrap($send->($event));
        $connection->_mark_response_started
            if $connection && ($event->{type} // '') eq 'http.response.start';
        $connection->_mark_complete
            if $connection && ($event->{type} // '') eq 'http.response.body'
                && !$event->{more};
        return;
    };
    my $receive = $type eq 'websocket'
        ? sub { Future->done({ type => 'websocket.connect' }) }
        : sub { Future->new };
    return $type eq 'websocket'
        ? PAGI::WebSocket->new($scope, $receive, $tracking_send)
        : PAGI::SSE->new($scope, $receive, $tracking_send);
}

my $two_challenges = challenge(
    challenges => [
        basic(realm => 'staff'),
        bearer(realm => 'private'),
    ],
);

subtest 'HTTP Request handlers return negotiated Auth applications directly' => sub {
    my $app = compose(routes => [
        route('/private' => sub {
            my ($request) = @_;
            return $two_challenges;
        }),
    ]);
    my $client = PAGI::Test::Client->new(app => $app);

    my $response = $client->get('/private', headers => {
        Accept => 'application/problem+json',
    });

    isa_ok $response, 'PAGI::Test::Response';
    is $response->status, 401, 'RequestResponse invokes the returned outcome';
    is $response->content_type, 'application/problem+json',
        'the original Request scope drives Pages negotiation';
    is $response->header_all('WWW-Authenticate'), [
        'Basic realm="staff"',
        'Bearer realm="private"',
    ], 'structured challenges remain separate response fields';
    is $response->header('Cache-Control'), 'no-store';
};

subtest 'native applications invoke negotiated Auth outcomes through invoke_app' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        return await invoke_app(
            $two_challenges, $scope, $receive, $send,
        );
    };
    my $client = PAGI::Test::Client->new(app => $app);

    my $response = $client->get('/', headers => { Accept => 'text/plain' });

    is $response->status, 401;
    is $response->content_type, 'text/plain; charset=utf-8',
        'native invocation retains ordinary Pages negotiation';
    is $response->header_all('WWW-Authenticate'), [
        'Basic realm="staff"',
        'Bearer realm="private"',
    ], 'native invocation does not combine challenge fields';
};

my $protocol_failure = challenge(
    challenges => [bearer(realm => 'private')],
    as         => 'json',
);

subtest 'WebSocket denial and SSE decline emit the same captured Auth response' => sub {
    my @websocket_events;
    my $routing = compose(routes => [
        websocket('/socket' => async sub {
            my ($ws) = @_;
            return await $ws->deny($protocol_failure->response_for($ws));
        }),
        sse('/events' => async sub {
            my ($stream) = @_;
            return await $stream->decline(
                $protocol_failure->response_for($stream),
            );
        }),
    ])->to_app;

    my $capturing_app = async sub {
        my ($scope, $receive, $send) = @_;
        my $observed_send = $send;
        if (($scope->{type} // '') eq 'websocket') {
            $observed_send = sub {
                my ($event) = @_;
                push @websocket_events, $event
                    if ($event->{type} // '')
                        =~ /^http\.response\./;
                return $send->($event);
            };
        }
        return await $routing->($scope, $receive, $observed_send);
    };
    my $client = PAGI::Test::Client->new(app => $capturing_app);

    my $socket = $client->websocket('/socket');
    ok $socket->is_closed, 'the denied test handshake is terminal';
    my $websocket_response = mapped_response(
        'websocket', \@websocket_events,
    );
    my $sse_response = $client->sse('/events');

    for my $case (
        ['WebSocket', $websocket_response],
        ['SSE',       $sse_response],
    ) {
        my ($name, $response) = @$case;
        isa_ok $response, ['PAGI::Test::Response'], "$name captured response";
        is $response->status, 401, "$name preserves the Auth status";
        is $response->content_type, 'application/problem+json',
            "$name preserves the fixed representation";
        is $response->header('Cache-Control'), 'no-store',
            "$name preserves the Auth cache policy";
        is $response->header_all('WWW-Authenticate'), [
            'Bearer realm="private"',
        ], "$name preserves one structured Bearer field";
    }
};

 my @protocol_cases = (
    {
        name          => 'WebSocket',
        type          => 'websocket',
        prefix        => 'http.response',
        initial_state => 'connecting',
        reserved_state => 'denying',
        reject        => sub { $_[0]->deny($_[1]) },
        compete       => sub { $_[0]->accept },
    },
    {
        name          => 'SSE',
        type          => 'sse',
        prefix        => 'http.response',
        initial_state => 'pending',
        reserved_state => 'declining',
        reject        => sub { $_[0]->decline($_[1]) },
        compete       => sub { $_[0]->start },
    },
);

subtest 'failed mapped starts leave Auth responses retryable' => sub {
    for my $case (@protocol_cases) {
        subtest $case->{name} => sub {
            my @sent;
            my $send_calls = 0;
            my $close_calls = 0;
            my $protocol = direct_protocol($case->{type}, sub {
                push @sent, $_[0];
                return ++$send_calls == 1
                    ? Future->fail("controlled start failure\n")
                    : Future->done;
            });
            $protocol->on_close(sub { ++$close_calls });
            my $response = $protocol_failure->response_for($protocol);

            like dies {
                $case->{reject}->($protocol, $response)->get;
            }, qr/controlled start failure/, 'the genuine send failure propagates';
            is $protocol->connection_state, $case->{initial_state},
                'failed start releases the response slot';
            ok !$protocol->scope->{'pagi.connection'}->response_started,
                'failed start remains uncommitted in connection state';
            ok !$protocol->scope->{'pagi.connection'}->response_complete,
                'failed start is not complete in connection state';
            is $close_calls, 0, 'an uncommitted response has no terminal cleanup';

            my $returned = $case->{reject}->($protocol, $response)->get;
            ok $returned == $protocol, 'the same concrete response can be retried';
            is [map { $_->{type} } @sent], [
                "$case->{prefix}.start",
                "$case->{prefix}.start",
                "$case->{prefix}.body",
            ], 'retry performs one complete mapped response';
            is $protocol->connection_state, 'closed';
            ok $protocol->scope->{'pagi.connection'}->response_started,
                'successful retry publishes response start';
            ok $protocol->scope->{'pagi.connection'}->response_complete,
                'successful retry publishes clean completion';
            is $close_calls, 1, 'successful retry runs terminal cleanup once';
        };
    }
};

subtest 'mapped start settlement owns the slot while body backpressure remains server-owned' => sub {
    for my $case (@protocol_cases) {
        subtest $case->{name} => sub {
            my $connection = PAGI::Test::ConnectionState->new;
            my @sent;
            my @settlements;
            my $body_cancelled = 0;
            my $close_calls = 0;
            my $writer_cleanup = 0;
            my $protocol = direct_protocol(
                $case->{type},
                sub {
                    my ($event) = @_;
                    push @sent, $event;
                    my $settlement = Future->new;
                    $settlement->on_cancel(sub { ++$body_cancelled })
                        if ($event->{type} // '') eq "$case->{prefix}.body";
                    push @settlements, $settlement;
                    return $settlement;
                },
                'pagi.connection' => $connection,
            );
            $protocol->on_close(sub { ++$close_calls });
            my $response = PAGI::Response::Stream->new(async sub {
                my ($writer) = @_;
                $writer->on_close(sub { ++$writer_cleanup });
                await $writer->write('pending');
            });

            my $rejection = $case->{reject}->($protocol, $response);
            is [map { $_->{type} } @sent], ["$case->{prefix}.start"],
                'only mapped start is sent before its settlement';
            is $protocol->connection_state, $case->{reserved_state},
                'the pending start reserves the first-event slot';
            ok !$connection->response_started,
                'pending start is not published before send settlement';
            like dies { $case->{compete}->($protocol)->get },
                qr/response is pending/, 'a competing first event fails locally';

            $settlements[0]->done;
            is $protocol->connection_state, $case->{reserved_state},
                'start acceptance commits the slot but body remains nonterminal';
            ok $connection->response_started,
                'settled start is published to connection state';
            ok !$connection->response_complete,
                'pending body leaves connection state incomplete';
            is [map { $_->{type} } @sent], [
                "$case->{prefix}.start", "$case->{prefix}.body",
            ], 'body emission begins only after start acceptance';
            ok !$rejection->is_ready, 'the mapped body retains backpressure';
            is $close_calls, 0, 'terminal cleanup waits for body settlement';

            $connection->_mark_disconnected('client_closed');
            ok !$settlements[1]->is_ready,
                'the test connection does not manufacture server send settlement';
            is $body_cancelled, 0,
                'disconnect observation never cancels the server-owned send';
            $settlements[1]->done;

            ok lives { $rejection->get },
                'server resolution during disconnect remains successful settlement';
            is scalar(@sent), 2,
                'disconnect suppresses a terminal send after the parked body';
            is $body_cancelled, 0, 'body settlement never cancels the send';
            is $writer_cleanup, 1, 'Response cleanup runs exactly once';
            is $close_calls, 1, 'terminal cleanup runs exactly once';
        };
    }
};

subtest 'unrelated parked refusal producers observe the test connection terminal outcome' => sub {
    for my $case (@protocol_cases) {
        subtest $case->{name} => sub {
            my (@sent, $weak_writer, $weak_producer);
            my ($cancelled, $writer_cleanup, $helper_cleanup) = (0, 0, 0);
            my $protocol = direct_protocol($case->{type}, sub {
                push @sent, $_[0]->{type}; return Future->done;
            });
            $protocol->on_close(sub { ++$helper_cleanup; return });
            my $response = PAGI::Response::Stream->new(sub {
                my ($writer) = @_;
                $weak_writer = $writer; weaken($weak_writer);
                $writer->on_close(sub { ++$writer_cleanup; return });
                my $producer = (async sub {
                    await $writer->write('parked');
                    await Future->new;
                })->();
                $weak_producer = $producer; weaken($weak_producer);
                $producer->on_cancel(sub { ++$cancelled });
                return $producer;
            }, status => 403);
            my $rejection = $case->{reject}->($protocol, $response);
            ok !$rejection->is_ready, 'producer parks after body send settles';
            ok $weak_writer && $weak_producer, 'resources remain live before disconnect';
            $protocol->scope->{'pagi.connection'}->_mark_disconnected('client_closed');
            ok lives { $rejection->get }, 'refusal settles successfully on disconnect';
            is [$cancelled, $writer_cleanup, $helper_cleanup], [1, 1, 1], 'cancellation and both cleanups run once';
            ok !$weak_producer, 'producer released';
            ok !$weak_writer, 'writer released';
            is \@sent, ['http.response.start', 'http.response.body'], 'no protocol start or terminal HTTP send';
        };
    }
};

done_testing;
