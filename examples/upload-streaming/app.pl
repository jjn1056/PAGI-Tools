#!/usr/bin/env perl
#
# Streaming uploads: bytes or text.
#
#   - Files (archives, images, anything binary) are bytes. body_stream without
#     decode hands them over exactly as sent; nothing is decoded or replaced.
#   - Text is decoded as it streams with decode => $charset. strict decides
#     what happens to bytes that are not valid in that charset: off (the
#     default) turns them into U+FFFD, fine where a garbled character does not
#     matter; on answers the client 400, right where the text is stored or
#     acted on -- and a binary file posted to a text route fails at once
#     instead of becoming garbage text. A charset that cannot be streamed is
#     the client's 415.
#   - A client that hangs up mid-upload is reported by $stream->truncated.
#
# Run:  pagi-server --app examples/upload-streaming/app.pl --port 5000
# Try:  curl -i -T archive.zip localhost:5000/files/archive.zip
#       curl -i --data-binary @people.csv -H 'Content-Type: text/csv; charset=windows-1252' localhost:5000/import
#       curl -i --data-binary $'{"type":"a"}\n{"type":"b"}\n' localhost:5000/events
#       curl -i --data-binary 'hello wörld' -H 'Content-Type: text/plain; charset=utf-8' localhost:5000/shout

use v5.40;
use Future::AsyncAwait;
use Digest::SHA;
use Encode qw(encode);
use File::Temp qw(tempdir);
use JSON::PP ();
use Text::CSV;
use PAGI::Tools qw(compose response route);

# Bytes: stored exactly as sent, checksummed, size-capped. The name allows
# letters, digits, '-', '_' and single dots between them: no '/', no '..'.
async sub store_file ($request) {
    my $name = $request->path_param('name');
    my $path = $request->state->get('uploads') . "/$name";
    my $body = $request->body_stream(max_bytes => 50 * 1024 * 1024);
    try { await $body->stream_to_file($path) }
    catch ($e) {
        unlink $path;    # a partial file is not kept
        die $e;          # over max_bytes (the client's 413), or a write failure
    }
    if ($body->truncated || !$body->bytes_read) {
        unlink $path;    # nor an empty or cut-short one
        return response('Text', 'The upload was empty or cut short.', status => 400);
    }
    my $sha = Digest::SHA->new(256)->addfile($path)->hexdigest;
    return response('JSON', { name => $name, bytes => $body->bytes_read, sha256 => $sha }, status => 201);
}

# Text, strict: decoded as it streams, so bad bytes are the client's 400 and
# a charset that cannot be streamed is a 415. Excel's BOM is dropped. The
# text is spooled as UTF-8 and parsed by Text::CSV: real CSV, where a quoted
# field may hold a newline, is not one record per line.
async sub import_csv ($request) {
    my $text = $request->body_stream(decode => $request->charset // 'UTF-8', strict => 1, strip_bom => 1);
    my $spool = File::Temp->new;
    binmode $spool, ':encoding(UTF-8)';
    await $text->stream_to(sub ($chunk) { print {$spool} $chunk });
    return response('Text', 'The upload was cut short.', status => 400) if $text->truncated;

    seek $spool, 0, 0;
    my $csv = Text::CSV->new({ binary => 1 });
    # A getline that returns undef either reached the end (Text::CSV's code
    # 2012) or failed to parse (any other code; eof alone is true even when
    # the last record failed). Each such undef is checked.
    my $malformed = sub { 0 + $csv->error_diag != 2012 };
    my $columns = $csv->getline($spool);
    return response('Text', 'The CSV is malformed.', status => 400) if !$columns && $malformed->();
    my $rows = 0;
    $rows++ while $csv->getline($spool);
    return response('Text', 'The CSV is malformed.', status => 400) if $malformed->();
    return response('JSON', { columns => $columns // [], rows => $rows });
}

# NDJSON, one event per line: the input twin of response('NDJSON'). A line
# that is not JSON dies in decode, a 500 here; a real importer would answer
# the client's 400 with the line number.
async sub import_events ($request) {
    my $lines = $request->body_stream(decode => 'UTF-8', strict => 1);
    my $json  = JSON::PP->new;    # decoded text in, so not decode_json
    my @types;
    await $lines->each_line(sub ($line) {
        push @types, $json->decode($line)->{type} if length $line;    # blank lines are allowed
    });
    return response('Text', 'The upload was cut short.', status => 400) if $lines->truncated;
    return response('JSON', { events => scalar @types, types => \@types });
}

# Text, lenient: a transformation where a stray U+FFFD does no harm.
async sub shout ($request) {
    my $text = $request->body_stream(decode => $request->charset // 'UTF-8');
    return response('Stream', async sub ($writer) {
        while (defined(my $chunk = await $text->next_chunk)) {
            await $writer->write(encode('UTF-8', uc $chunk));
        }
    }, content_type => 'text/plain; charset=utf-8');
}

compose(
    routes => [
        route('/files/{name:[\w-]+(?:\.[\w-]+)*}' => \&store_file, methods => 'PUT'),
        route('/import' => \&import_csv, methods => 'POST'),
        route('/events' => \&import_events, methods => 'POST'),
        route('/shout'  => \&shout,      methods => 'POST'),
    ],
    lifespan => {
        startup => sub ($state, $scope) { $state->{uploads} = tempdir(CLEANUP => 1) },
    },
);
