use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use File::Temp qw(tempfile);

use PAGI::Request::BodyStream;

# Mock receive function
sub mock_receive {
    my @chunks = @_;
    my $i = 0;
    return sub {
        my $chunk = $chunks[$i++];
        return Future->done($chunk);
    };
}

subtest 'basic streaming' => sub {
    my $receive = mock_receive(
        { type => 'http.request', body => 'Hello', more => 1 },
        { type => 'http.request', body => ' World', more => 0 },
    );

    my $stream = PAGI::Request::BodyStream->new(receive => $receive);

    my $chunk1 = $stream->next_chunk->get;
    is $chunk1, 'Hello', 'first chunk';
    ok !$stream->is_done, 'not done yet';

    my $chunk2 = $stream->next_chunk->get;
    is $chunk2, ' World', 'second chunk';
    ok $stream->is_done, 'done after last chunk';

    is $stream->bytes_read, 11, 'bytes_read correct';
};

subtest 'max_bytes limit' => sub {
    my $receive = mock_receive(
        { type => 'http.request', body => 'Hello World', more => 0 },
    );

    my $stream = PAGI::Request::BodyStream->new(
        receive => $receive,
        max_bytes => 5,
    );

    my $error = dies { $stream->next_chunk->get };
    isa_ok($error, 'PAGI::Exception::RequestBody');
    is([$error->status_code, $error->reason, $error->message],
        [413, 'too_large', 'The request body is larger than this route accepts.'],
        "over the limit is the client's 413, in words a client can read");
    like($error->cause, qr/max_bytes exceeded/, 'the cause names the limit');
};

subtest 'UTF-8 decoding' => sub {
    my $receive = mock_receive(
        { type => 'http.request', body => "caf\xc3\xa9", more => 0 },
    );

    my $stream = PAGI::Request::BodyStream->new(
        receive => $receive,
        decode => 'UTF-8',
    );

    my $chunk = $stream->next_chunk->get;
    is $chunk, "café", 'UTF-8 decoded';
};

subtest 'disconnect handling' => sub {
    my $receive = mock_receive(
        { type => 'http.request', body => 'Hello', more => 1 },
        { type => 'http.disconnect' },
    );

    my $stream = PAGI::Request::BodyStream->new(receive => $receive);

    my $chunk1 = $stream->next_chunk->get;
    is $chunk1, 'Hello', 'first chunk';
    ok !$stream->truncated, 'not truncated before the disconnect is observed';

    my $chunk2 = $stream->next_chunk->get;
    is $chunk2, undef, 'undef on disconnect -- streaming consumers may still handle partial data';
    ok $stream->is_done, 'done after disconnect';
    ok $stream->truncated, 'truncated flag records that this was a mid-body disconnect';
};

subtest 'truncated stays false on an immediate disconnect with no bytes ever read' => sub {
    my $receive = mock_receive(
        { type => 'http.disconnect' },
    );

    my $stream = PAGI::Request::BodyStream->new(receive => $receive);

    my $chunk = $stream->next_chunk->get;
    is $chunk, undef, 'undef -- no data was ever sent';
    ok $stream->is_done, 'done';
    ok !$stream->truncated, 'an immediate disconnect with zero bytes is an empty stream, not a truncation';
};

subtest 'truncated stays false after a clean completion' => sub {
    my $receive = mock_receive(
        { type => 'http.request', body => 'Hello', more => 0 },
    );

    my $stream = PAGI::Request::BodyStream->new(receive => $receive);

    my $chunk = $stream->next_chunk->get;
    is $chunk, 'Hello', 'chunk read';
    ok $stream->is_done, 'done';
    ok !$stream->truncated, 'a clean end-of-body is not a truncation';
};

subtest 'UTF-8 boundary handling - split multi-byte sequence' => sub {
    # Split café (caf\xc3\xa9) across chunks: "caf\xc3" and "\xa9"
    my $receive = mock_receive(
        { type => 'http.request', body => "caf\xc3", more => 1 },
        { type => 'http.request', body => "\xa9", more => 0 },
    );

    my $stream = PAGI::Request::BodyStream->new(
        receive => $receive,
        decode => 'UTF-8',
    );

    my $chunk1 = $stream->next_chunk->get;
    is $chunk1, "caf", 'first chunk without incomplete sequence';

    my $chunk2 = $stream->next_chunk->get;
    is $chunk2, "é", 'second chunk completes the sequence';

    ok $stream->is_done, 'stream done';
};

subtest 'empty chunks are handled' => sub {
    my $receive = mock_receive(
        { type => 'http.request', body => '', more => 1 },
        { type => 'http.request', body => 'data', more => 1 },
        { type => 'http.request', body => '', more => 0 },
    );

    my $stream = PAGI::Request::BodyStream->new(receive => $receive);

    my $chunk1 = $stream->next_chunk->get;
    is $chunk1, '', 'empty first chunk';

    my $chunk2 = $stream->next_chunk->get;
    is $chunk2, 'data', 'non-empty chunk';

    my $chunk3 = $stream->next_chunk->get;
    is $chunk3, '', 'empty last chunk';

    ok $stream->is_done, 'stream done';
    is $stream->bytes_read, 4, 'bytes_read only counts non-empty';
};

subtest 'stream_to custom sink' => sub {
    my $receive = mock_receive(
        { type => 'http.request', body => 'Hello', more => 1 },
        { type => 'http.request', body => ' World', more => 0 },
    );

    my $stream = PAGI::Request::BodyStream->new(receive => $receive);

    my $collected = '';
    my $bytes = $stream->stream_to(sub {
        my ($chunk) = @_;
        $collected .= $chunk;
    })->get;

    is $collected, 'Hello World', 'all chunks collected';
    is $bytes, 11, 'bytes_processed correct';
    ok $stream->is_done, 'stream done';
};

subtest 'stream_to_file' => sub {
    my $receive = mock_receive(
        { type => 'http.request', body => 'Hello', more => 1 },
        { type => 'http.request', body => ' World', more => 0 },
    );

    my $stream = PAGI::Request::BodyStream->new(receive => $receive);

    my ($fh, $filename) = tempfile(UNLINK => 1);
    close $fh;

    my $bytes = $stream->stream_to_file($filename)->get;

    is $bytes, 11, 'bytes written correct';
    ok $stream->is_done, 'stream done';

    # Read file to verify
    open my $read_fh, '<', $filename or die "Cannot read $filename: $!";
    my $content = do { local $/; <$read_fh> };
    close $read_fh;

    is $content, 'Hello World', 'file content correct';
};

subtest 'custom limit_name in error' => sub {
    my $receive = mock_receive(
        { type => 'http.request', body => 'Too much data', more => 0 },
    );

    my $stream = PAGI::Request::BodyStream->new(
        receive => $receive,
        max_bytes => 5,
        limit_name => 'upload_size',
    );

    my $error = dies { $stream->next_chunk->get };
    is($error->status_code, 413, 'a 413');
    like($error->cause, qr/upload_size exceeded/, 'the cause names the custom limit');
};

subtest 'a body longer than its own Content-Length is a 400' => sub {
    my $stream = PAGI::Request::BodyStream->new(
        receive => mock_receive({ type => 'http.request', body => 'Too much data', more => 0 }),
        max_bytes => 5,
        limit_name => 'content-length',
    );
    my $error = dies { $stream->next_chunk->get };
    is([$error->status_code, $error->reason, $error->message],
        [400, 'invalid_body', 'The request body is longer than its Content-Length.'],
        'a malformed request, not one that is too large');
};

subtest 'strict UTF-8 mode' => sub {
    # Invalid UTF-8 sequence
    my $receive = mock_receive(
        { type => 'http.request', body => "\xFF\xFE", more => 0 },
    );

    my $stream = PAGI::Request::BodyStream->new(
        receive => $receive,
        decode => 'UTF-8',
        strict => 1,
    );

    my $error = dies { $stream->next_chunk->get };
    isa_ok($error, 'PAGI::Exception::RequestBody');
    is([$error->status_code, $error->reason, $error->message],
        [400, 'invalid_encoding', 'The request body is not valid UTF-8.'],
        "invalid bytes are the client's error, a 400");

    # Invalid bytes held back across a chunk boundary are found the same way.
    $stream = PAGI::Request::BodyStream->new(
        receive => mock_receive(
            { type => 'http.request', body => "caf\xC3", more => 1 },
            { type => 'http.request', body => "\x28",    more => 0 },
        ),
        decode => 'UTF-8',
        strict => 1,
    );
    is($stream->next_chunk->get, 'caf', 'the valid part arrives');
    isa_ok(dies { $stream->next_chunk->get }, 'PAGI::Exception::RequestBody');

    # An invalid byte with more data behind it is reported on that chunk,
    # not held back until the end of the body.
    $stream = PAGI::Request::BodyStream->new(
        receive => mock_receive({ type => 'http.request', body => "a\xFFbcd", more => 1 }),
        decode => 'UTF-8',
        strict => 1,
    );
    isa_ok(dies { $stream->next_chunk->get }, 'PAGI::Exception::RequestBody');
};

subtest 'strict mode accepts a valid character split across chunks' => sub {
    my $stream = PAGI::Request::BodyStream->new(
        receive => mock_receive(
            { type => 'http.request', body => "caf\xC3", more => 1 },
            { type => 'http.request', body => "\xA9!",   more => 0 },
        ),
        decode => 'UTF-8',
        strict => 1,
    );
    my @chunks;
    while (defined(my $chunk = $stream->next_chunk->get)) { push @chunks, $chunk }
    is(join('', @chunks), "caf\x{E9}!", 'the held-back byte completes with the next chunk');
};

subtest 'an encoding the stream cannot decode is the client\'s 415, when the stream is made' => sub {
    for my $name ('UFT-8', 'ISO-2022-JP') {
        my $error = dies { PAGI::Request::BodyStream->new(receive => mock_receive(), decode => $name) };
        isa_ok($error, 'PAGI::Exception::RequestBody');
        is([$error->status_code, $error->reason, $error->message],
            [415, 'unsupported_charset', "The request body's charset is not supported."], "$name: a 415");
        like($error->cause, qr/\APAGI::Utils::TextDecoder: /, "$name: the decoder's reason is the cause");
    }
};

subtest 'no receive callback throws' => sub {
    like dies {
        PAGI::Request::BodyStream->new();
    }, qr/receive is required/, 'throws without receive';
};

subtest 'bytes_read tracking' => sub {
    my $receive = mock_receive(
        { type => 'http.request', body => '12345', more => 1 },
        { type => 'http.request', body => '67890', more => 0 },
    );

    my $stream = PAGI::Request::BodyStream->new(receive => $receive);

    is $stream->bytes_read, 0, 'zero before reading';

    $stream->next_chunk->get;
    is $stream->bytes_read, 5, 'five after first chunk';

    $stream->next_chunk->get;
    is $stream->bytes_read, 10, 'ten after second chunk';
};

subtest 'stream_to_file rejects decode option' => sub {
    my $receive = mock_receive(
        { type => 'http.request', body => 'test', more => 0 },
    );

    my $stream = PAGI::Request::BodyStream->new(
        receive => $receive,
        decode => 'UTF-8',
    );

    like dies { $stream->stream_to_file('/tmp/test.bin')->get },
        qr/cannot be used with decode/,
        'stream_to_file throws with decode option';
};

subtest 'PAGI::Request body_stream' => sub {
    use PAGI::Request;

    my $chunks = [
        { type => 'http.request', body => 'Hello', more => 1 },
        { type => 'http.request', body => ' World', more => 0 },
    ];
    my $i = 0;
    my $receive = sub { Future->done($chunks->[$i++]) };

    my $scope = { type => 'http', method => 'POST', path => '/', headers => [] };
    my $req = PAGI::Request->new($scope, $receive);

    my $stream = $req->body_stream;
    isa_ok $stream, 'PAGI::Request::BodyStream';

    my $chunk1 = $stream->next_chunk->get;
    is $chunk1, 'Hello', 'first chunk via Request';
};

subtest 'body_stream mutual exclusivity' => sub {
    use PAGI::Request;

    # Streaming then buffered should fail
    my $scope1 = { type => 'http', method => 'POST', path => '/', headers => [] };
    my $receive1 = sub { Future->done({ type => 'http.request', body => 'test', more => 0 }) };
    my $req1 = PAGI::Request->new($scope1, $receive1);
    $req1->body_stream;
    like dies { $req1->body->get }, qr/streaming/, 'body after stream fails';

    # Buffered then streaming should fail
    my $scope2 = { type => 'http', method => 'POST', path => '/', headers => [] };
    my $receive2 = sub { Future->done({ type => 'http.request', body => 'x', more => 0 }) };
    my $req2 = PAGI::Request->new($scope2, $receive2);
    $req2->body->get;
    like dies { $req2->body_stream }, qr/consumed|read/, 'stream after body fails';
};

sub stream_text {
    my ($decode, $strict, @events) = @_;
    my $stream = PAGI::Request::BodyStream->new(
        receive => mock_receive(@events), decode => $decode, strict => $strict);
    my @out;
    my $ok = eval { while (defined(my $chunk = $stream->next_chunk->get)) { push @out, $chunk } 1 };
    return (\@out, $ok ? undef : $@, $stream);
}
sub body_events {
    my @chunks = @_;
    return map { { type => 'http.request', body => $chunks[$_], more => ($_ < $#chunks ? 1 : 0) } } 0 .. $#chunks;
}

subtest 'decoding streams on after a bad byte, and keeps a UTF-16 byte order' => sub {
    my ($out) = stream_text('UTF-8', 0, body_events("x\xFF" . ('a' x 1000), ('a' x 1000) x 4));
    is [map { length } @$out], [1002, 1000, 1000, 1000, 1000], 'no chunk waits for the end';
    ($out) = stream_text('UTF-16', 0, body_events("\xFF\xFEh\0i\0", "!\0"));
    is join('', @$out), 'hi!', 'the second chunk keeps the BOM\'s byte order';
    ($out) = stream_text('UTF-16', 1, body_events("\xFF\xFEh\0i\0", "!\0"));
    is join('', @$out), 'hi!', 'strict too';
};

subtest 'a body that ends inside a character' => sub {
    my ($out, $error) = stream_text('UTF-8', 0, body_events("ok\xE2\x82"));
    is join('', @$out), "ok\x{FFFD}", 'not strict: U+FFFD';
    ($out, $error) = stream_text('UTF-8', 1, body_events("ok\xE2\x82"));
    isa_ok($error, 'PAGI::Exception::RequestBody');
    is $error->status_code, 400, 'strict: the client\'s 400';
};

subtest 'a disconnect inside a character ends the text; truncated says why' => sub {
    for my $case (['UTF-8', "ok\xE2\x82", 'ok'], ['UTF-16', "\xFF\xFEo\0k\0\x3D\xD8", 'ok']) {
        my ($name, $bytes, $text) = @$case;
        for my $strict (0, 1) {
            my ($out, $error, $stream) = stream_text($name, $strict,
                { type => 'http.request', body => $bytes, more => 1 }, { type => 'http.disconnect' });
            is [join('', @$out), $error, $stream->truncated ? 1 : 0], [$text, undef, 1],
                "$name strict=$strict: the whole characters, no exception, truncated";
        }
    }
};

subtest 'strip_bom on a body stream' => sub {
    my $stream = PAGI::Request::BodyStream->new(
        receive => mock_receive(
            { type => 'http.request', body => "\xEF\xBB", more => 1 },
            { type => 'http.request', body => "\xBFid\n", more => 0 },
        ),
        decode => 'UTF-8', strip_bom => 1,
    );
    my $text = '';
    while (defined(my $chunk = $stream->next_chunk->get)) { $text .= $chunk }
    is $text, "id\n", 'the BOM is dropped across a chunk boundary';

    like dies { PAGI::Request::BodyStream->new(receive => mock_receive(), strip_bom => 1) },
        qr/strip_bom needs decode: a byte-order mark is text/, 'strip_bom on raw bytes is a mistake';
};

done_testing;
