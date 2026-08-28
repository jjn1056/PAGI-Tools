#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Request;
use PAGI::Test::ConnectionState;

{
    package T::GetOnlySinkResult;
    sub new { return bless { get_calls => 0 }, shift }
    sub get { ++$_[0]{get_calls}; die "undocumented get protocol was used\n" }
    sub get_calls { return $_[0]{get_calls} }
}

# Helper to create a mock receive that returns body in chunks
sub mock_receive {
    my (@chunks) = @_;
    my $index = 0;
    return async sub {
        if ($index < @chunks) {
            my $chunk = $chunks[$index++];
            return {
                type => 'http.request',
                body => $chunk,
                more => ($index < @chunks),
            };
        }
        return { type => 'http.disconnect' };
    };
}

subtest 'body reads entire content' => sub {
    my $scope = {
        type    => 'http',
        method  => 'POST',
        headers => [['content-length', '11']],
    };
    my $receive = mock_receive('Hello', ' ', 'World');
    my $req = PAGI::Request->new($scope, $receive);

    my $body = (async sub { await $req->body })->();
    $body = $body->get;  # Resolve Future

    is($body, 'Hello World', 'body concatenates all chunks');
};

subtest 'body caches result' => sub {
    my $call_count = 0;
    my $scope = { type => 'http', method => 'POST', headers => [] };
    my $receive = async sub {
        $call_count++;
        return { type => 'http.request', body => 'data', more => 0 };
    };

    my $req = PAGI::Request->new($scope, $receive);

    my $body1 = (async sub { await $req->body })->()->get;
    my $body2 = (async sub { await $req->body })->()->get;

    is($body1, 'data', 'first read works');
    is($body2, 'data', 'second read works');
    is($call_count, 1, 'receive only called once (cached)');
};

subtest 'text decodes as UTF-8' => sub {
    my $utf8_bytes = "Caf\xc3\xa9";  # "Café" in UTF-8
    my $scope = { type => 'http', method => 'POST', headers => [] };
    my $receive = mock_receive($utf8_bytes);
    my $req = PAGI::Request->new($scope, $receive);

    my $text = (async sub { await $req->text })->()->get;

    is($text, "Café", 'text decodes UTF-8');
};

subtest 'json parses body' => sub {
    my $json_body = '{"name":"John","age":30}';
    my $scope = {
        type    => 'http',
        method  => 'POST',
        headers => [['content-type', 'application/json']],
    };
    my $receive = mock_receive($json_body);
    my $req = PAGI::Request->new($scope, $receive);

    my $data = (async sub { await $req->json })->()->get;

    is($data, { name => 'John', age => 30 }, 'json parses correctly');
};

subtest 'json dies on invalid JSON' => sub {
    my $bad_json = '{"broken":';
    my $scope = { type => 'http', method => 'POST', headers => [] };
    my $receive = mock_receive($bad_json);
    my $req = PAGI::Request->new($scope, $receive);

    my $died = 0;
    eval {
        (async sub { await $req->json })->()->get;
    };
    $died = 1 if $@;

    ok($died, 'json dies on invalid JSON');
};

subtest 'body croaks on mid-body disconnect, not silent EOF' => sub {
    my $conn = PAGI::Test::ConnectionState->new;
    my $scope = {
        type    => 'http',
        method  => 'POST',
        headers => [],
        'pagi.connection' => $conn,
    };
    my $calls = 0;
    my $sent  = 0;
    my $receive = async sub {
        $calls++;
        if (!$sent) {
            $sent = 1;
            return { type => 'http.request', body => 'Hel', more => 1 };
        }
        $conn->_mark_disconnected('client_closed');
        return { type => 'http.disconnect' };
    };
    my $req = PAGI::Request->new($scope, $receive);

    my $err1;
    eval { (async sub { await $req->body })->()->get; 1 } or $err1 = $@;
    like $err1, qr/Request body incomplete: client disconnected mid-body \(client_closed\)/,
        'body croaks naming the disconnect reason instead of returning the partial body';
    is $calls, 2, 'receive called exactly twice (partial chunk + disconnect)';
    ok !$scope->{'pagi.request.body.read'}, 'the partial body is never cached as a complete read';
    ok $scope->{'pagi.request.body.truncated'}, 'truncation is recorded on the scope';

    my $err2;
    eval { (async sub { await $req->body })->()->get; 1 } or $err2 = $@;
    like $err2, qr/Request body incomplete: client disconnected mid-body \(client_closed\)/,
        'a second call fails identically';
    is $calls, 2, 'the second call does not re-await receive (entry guard, avoids parking)';
};

subtest 'json/text fail the same way as body on mid-body disconnect' => sub {
    my $conn = PAGI::Test::ConnectionState->new;
    my $scope = {
        type    => 'http',
        method  => 'POST',
        headers => [['content-type', 'application/json']],
        'pagi.connection' => $conn,
    };
    my $sent = 0;
    my $receive = async sub {
        if (!$sent) {
            $sent = 1;
            return { type => 'http.request', body => '{"a":', more => 1 };
        }
        $conn->_mark_disconnected('client_closed');
        return { type => 'http.disconnect' };
    };
    my $req = PAGI::Request->new($scope, $receive);

    my $err;
    eval { (async sub { await $req->json })->()->get; 1 } or $err = $@;
    like $err, qr/Request body incomplete: client disconnected mid-body \(client_closed\)/,
        'json() fails with the truncation reason rather than parsing the partial JSON';
};

subtest 'empty body' => sub {
    my $scope = { type => 'http', method => 'GET', headers => [] };
    my $receive = mock_receive();
    my $req = PAGI::Request->new($scope, $receive);

    my $body = (async sub { await $req->body })->()->get;

    is($body, '', 'empty body returns empty string');
};

subtest 'buffered and streaming request-body consumption remain mutually exclusive' => sub {
    my $stream_scope = { type => 'http', method => 'POST', headers => [] };
    my $stream_request = PAGI::Request->new($stream_scope, mock_receive('streamed'));
    $stream_request->body_stream;
    like dies { $stream_request->body->get }, qr/streaming already started/i,
        'buffered body is unavailable after body_stream creation';

    my $buffer_scope = { type => 'http', method => 'POST', headers => [] };
    my $buffer_request = PAGI::Request->new($buffer_scope, mock_receive('buffered'));
    is $buffer_request->body->get, 'buffered', 'buffered body is consumed first';
    like dies { $buffer_request->body_stream }, qr/already consumed|streaming not available/i,
        'body_stream is unavailable after buffered consumption';
};

subtest 'BodyStream stream_to wraps immediate and Future-backed sink results only' => sub {
    my @messages = (
        { type => 'http.request', body => 'one', more => 1 },
        { type => 'http.request', body => 'two', more => 1 },
        { type => 'http.request', body => 'three', more => 0 },
    );
    my $sink_wait = Future->new;
    my $get_only = T::GetOnlySinkResult->new;
    my @seen;
    my $stream = PAGI::Request::BodyStream->new(
        receive => sub { Future->done(shift @messages) },
    );
    my $running = $stream->stream_to(sub {
        my ($chunk) = @_;
        push @seen, $chunk;
        return 'immediate' if $chunk eq 'one';
        return $sink_wait if $chunk eq 'two';
        return $get_only;
    });

    is \@seen, ['one', 'two'], 'Future-backed sink applies pull backpressure';
    ok !$running->is_ready, 'stream_to remains pending on the sink Future';
    $sink_wait->done;
    is $running->get, 11, 'stream_to counts every processed byte after sink settlement';
    is \@seen, ['one', 'two', 'three'], 'source resumes only after sink settlement';
    is $get_only->get_calls, 0,
        'an unrelated get method does not create an undocumented awaitable protocol';

    my $failed = PAGI::Request::BodyStream->new(
        receive => sub { Future->done({
            type => 'http.request', body => 'bad', more => 0,
        }) },
    )->stream_to(sub { Future->fail("sink exploded\n") });
    like dies { $failed->get }, qr/sink exploded/,
        'Future-backed sink failure propagates';
};

subtest 'BodyStream stream_to retains mid-body truncation reporting' => sub {
    my @messages = (
        { type => 'http.request', body => 'partial', more => 1 },
        { type => 'http.disconnect' },
    );
    my $stream = PAGI::Request::BodyStream->new(
        receive => sub { Future->done(shift @messages) },
    );
    is $stream->stream_to(sub { return Future->done })->get, 7,
        'partial bytes are delivered to the sink';
    ok $stream->truncated, 'mid-body disconnect remains explicitly observable';
};

done_testing;
