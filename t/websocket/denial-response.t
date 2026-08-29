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
    async sub respond {
        my ($self, $scope, $receive, $send) = @_;
        $seen_scope = $scope;
        await $self->SUPER::respond($scope, $receive, $send);
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

subtest 'mapped Stream sends remain sequential and backpressured' => sub {
    my @sent;
    my @settlements;
    my $producer_calls = 0;
    my $stream = PAGI::Response::Stream->new(async sub {
        my ($writer) = @_;
        ++$producer_calls;
        await $writer->write('first');
        await $writer->write('second');
    });
    my $ws = websocket(ws_scope(), sub {
        push @sent, $_[0];
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
    is($producer_calls, 1, 'producer starts after response start settles');
    is([map { $_->{body} // '<start>' } @sent], ['<start>', 'first'],
        'first chunk follows start');

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
    async sub respond {
        my ($self, $scope, $receive, $send) = @_;
        for my $event (@{$self->{events}}) {
            await $send->($event);
        }
        return;
    }

    package T::ExplodingResponse;
    use Future::AsyncAwait;
    use parent -norequire, 'PAGI::Response';
    our $calls = 0;
    async sub respond { ++$calls; die "custom response was invoked\n" }
}

subtest 'File, fh, trailers, and unknown response events fail before denial start' => sub {
    my ($fh, $path) = tempfile();
    print {$fh} 'file';
    close $fh;

    my @invalid = (
        ['File response', PAGI::Response::File->new($path), qr/File/i],
        ['fh body', T::InvalidProtocolResponse->new([
            { type => 'http.response.start', status => 200, headers => [] },
            { type => 'http.response.body', fh => 'opaque', more => 0 },
        ]), qr/(?:fh|opaque|body)/i],
        ['declared trailers', T::InvalidProtocolResponse->new([{
            type => 'http.response.start', status => 200, headers => [], trailers => 1,
        }]), qr/trailer/i],
        ['trailer event', T::InvalidProtocolResponse->new([
            { type => 'http.response.start', status => 200, headers => [] },
            { type => 'http.response.trailers', headers => [] },
        ]), qr/trailer|event/i],
        ['unknown event', T::InvalidProtocolResponse->new([
            { type => 'http.response.start', status => 200, headers => [] },
            { type => 'http.response.push' },
        ]),
            qr/unknown|event/i],
    );

    for my $case (@invalid) {
        my ($name, $response, $error) = @$case;
        subtest $name => sub {
            my @sent;
            my $ws = websocket(ws_scope(), sub { push @sent, $_[0]; Future->done });
            like(dies { $ws->deny($response)->get }, $error, 'invalid response is rejected');
            is(\@sent, [], 'no protocol response event was sent');
            is($ws->connection_state, 'connecting', 'handshake state remains live');
        };
    }
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

subtest 'denial send failures propagate and do not close early' => sub {
    my $failure = Future->fail("denial transport failed\n");
    my $ws = websocket(ws_scope(), sub { return $failure });

    like(dies { $ws->deny(PAGI::Response::Text->new('no'))->get },
        qr/denial transport failed/, 'send failure reaches caller');
    is($ws->connection_state, 'connecting', 'failed denial does not claim closure');
};

subtest 'cancelling deny never cancels the server-owned send Future' => sub {
    my $send_future = Future->new;
    my $ws = websocket(ws_scope(), sub { return $send_future });
    my $denial = $ws->deny(PAGI::Response::Text->new('pending'));

    $denial->cancel;
    ok($denial->is_cancelled, 'caller cancellation is observed by deny Future');
    ok(!$send_future->is_cancelled, 'pending server send remains owned by server');
    $send_future->done;
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
