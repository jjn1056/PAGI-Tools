package PAGI::Request::BodyStream;

use strict;
use warnings;

use Future;
use Future::AsyncAwait;
use PAGI::Utils::TextDecoder;
use Carp qw(croak);
use PAGI::Exception::RequestBody;
use PAGI::Request::_BodyInput ();


=head1 NAME

PAGI::Request::BodyStream - Streaming body consumption for PAGI requests

=head1 SYNOPSIS

    use PAGI::Request::BodyStream;
    use Future::AsyncAwait;

    # Basic streaming
    my $stream = PAGI::Request::BodyStream->new(receive => $receive);

    while (!$stream->is_done) {
        my $chunk = await $stream->next_chunk;
        last unless defined $chunk;
        print "Got chunk: ", length($chunk), " bytes\n";
    }

    # With size limit
    my $stream = PAGI::Request::BodyStream->new(
        receive   => $receive,
        max_bytes => 1024 * 1024,  # 1MB limit
    );

    # With UTF-8 decoding
    my $stream = PAGI::Request::BodyStream->new(
        receive => $receive,
        decode  => 'UTF-8',
    );

    # Stream to file
    await $stream->stream_to_file('/tmp/upload.dat');

    # Stream to custom sink
    await $stream->stream_to(async sub ($chunk) {
        # Process chunk
        print STDERR "Processing: ", length($chunk), " bytes\n";
    });

=head1 DESCRIPTION

PAGI::Request::BodyStream provides streaming body consumption for large request
bodies. This is useful when you need to process request data incrementally
without loading the entire body into memory.

Streams created by L<PAGI::Request> consume the native HTTP or SSE request and
disconnect event family for the request scope. Direct construction defaults to
HTTP events.

The stream is pull-based: you call C<next_chunk()> to receive the next chunk
of data. The stream handles:

=over 4

=item * Size limits with customizable error messages

=item * Text decoding as chunks arrive (C<decode>), with characters split across chunks held until complete

=item * Client disconnect detection

=item * Convenient file streaming with C<stream_to_file()>

=back

B<Important>: Streaming is mutually exclusive with buffered body methods like
C<body()>, C<json()>, C<form_params()> in L<PAGI::Request>. Once you start streaming,
you cannot use those methods.

=head1 CONSTRUCTOR

=head2 new

    my $stream = PAGI::Request::BodyStream->new(
        receive    => $receive,      # Required: PAGI receive callback
        max_bytes  => 10485760,      # Optional: max body size
        decode     => 'UTF-8',       # Optional: decode from UTF-8
        strict     => 1,             # Optional: invalid bytes are a 400
        strip_bom  => 1,             # Optional: drop a leading byte-order mark
        max_line_length => 65536,    # Optional: the longest line next_line takes
        limit_name => 'body_size',   # Optional: name for limit error message
    );

Creates a new body stream.

=over 4

=item * C<receive> - Required. The PAGI receive callback.

=item * C<max_bytes> - Optional. Maximum bytes to read. More is a
L<PAGI::Exception::RequestBody>: 413 (C<too_large>), or 400 (C<invalid_body>) when
the limit is the request's own Content-Length, which the body may not
exceed.

=item * C<decode> - Optional. The encoding to decode chunks from, such as
C<'UTF-8'> (or C<< $request->charset // 'UTF-8' >>). Without it, chunks are
the bytes exactly as sent. An encoding this stream cannot decode (one Encode
does not know, or ISO-2022-*/UTF-7, which Encode decodes only line by line)
is a L<PAGI::Exception::RequestBody> 415 (C<unsupported_charset>) when the
stream is made: the client's charset error, as for C<< $request->text >>,
which can read ISO-2022 and UTF-7 bodies whole. Built on
L<PAGI::Utils::TextDecoder>.

=item * C<strict> - Optional. If true, bytes invalid in the C<decode> encoding
throw a L<PAGI::Exception::RequestBody> (400, C<invalid_encoding>), the client's
error. If false (default), they become U+FFFD.

=item * C<strip_bom> - Optional, with C<decode>. Drops a byte-order mark
(U+FEFF) at the very start of the text: Excel's "CSV UTF-8" begins with one.
Off by default, because in UTF-8 the mark is text. See
L<PAGI::Utils::TextDecoder/new>.

=item * C<max_line_length> - Optional. The longest line L</next_line>
accepts, in characters when decoding and bytes otherwise (default 65536). A
longer line is a L<PAGI::Exception::RequestBody> 413 (C<too_large>).

=item * C<limit_name> - Optional. Name to use in error message when max_bytes
is exceeded (default: 'max_bytes'). It appears in the error's C<cause>, for the
log; the client sees only the message. C<content-length> marks the limit as
the request's own Content-Length (the 400 above).

=back

=cut

sub new {
    my ($class, %args) = @_;
    my $receive = $args{receive} // croak("receive is required");

    my $self = bless {
        receive       => $receive,
        max_bytes     => $args{max_bytes},
        decode        => $args{decode},
        limit_name    => $args{limit_name} // 'max_bytes',
        _scope_type   => $args{_scope_type} // 'http',
        _bytes_read   => 0,
        _done         => 0,
        _error        => undef,
        _truncated    => 0,
        max_line_length => $args{max_line_length} // 65536,
        _lines        => undef,    # the partial line next_line holds
    }, $class;

    croak 'strip_bom needs decode: a byte-order mark is text'
        if $args{strip_bom} && !defined $args{decode};

    # The encoding name usually comes from the client's Content-Type, so one
    # this stream cannot decode is the client's 415, as for $request->text.
    if (defined $args{decode}) {
        my $decoder = eval {
            PAGI::Utils::TextDecoder->new($args{decode},
                strict => $args{strict}, strip_bom => $args{strip_bom});
        };
        PAGI::Exception::RequestBody->throw(
            status_code => 415,
            reason      => 'unsupported_charset',
            message     => "The request body's charset is not supported.",
            cause       => $@,
        ) unless $decoder;
        $self->{_decoder} = $decoder;
    }

    return $self;
}

=head1 METHODS

=head2 next_chunk

    my $chunk = await $stream->next_chunk;

Returns a Future that resolves to the next chunk of data, or undef when the
stream is exhausted or the client disconnects.

If C<decode> was specified in the constructor, chunks are decoded from that
encoding. A character split across chunks is held back until it is complete.
With C<strict>, bytes invalid in the encoding throw a
L<PAGI::Exception::RequestBody> (400). A route that has already started its own
response by then cannot send that 400: the response is cut short instead.

A client that disconnects partway through a character ends the text at the
last whole character (in strict UTF-16, one code unit earlier), and
C<truncated> is true; nothing is reported as invalid.

Throws a L<PAGI::Exception::RequestBody> (413, or 400 past the Content-Length) if
C<max_bytes> is exceeded.

=cut

async sub next_chunk {
    my ($self) = @_;
    # A line reader holds a partial line; chunks read past it would lose it.
    croak 'next_chunk: line reading has started; use next_line'
        if defined $self->{_lines};
    return await $self->_read_chunk;
}

async sub _read_chunk {
    my ($self) = @_;
    return undef if $self->{_done};
    return undef if $self->{_error};

    my $message = await $self->{receive}->();
    my $kind = PAGI::Request::_BodyInput::event_kind(
        $self->{_scope_type}, $message,
    );

    # Handle disconnect
    if ($kind eq 'disconnect') {
        $self->{_done} = 1;
        # No bytes ever arrived -- an empty stream, not a truncated one.
        $self->{_truncated} = 1 if $self->{_bytes_read} > 0;
        # A character the client never finished is dropped: the bytes
        # stopped, they were not wrong. truncated says so.
        return undef;
    }

    # Extract body chunk
    my $chunk = $message->{body} // '';
    my $more = $message->{more} // 0;

    # Check size limit before processing
    if (defined $self->{max_bytes}) {
        my $new_total = $self->{_bytes_read} + length($chunk);
        if ($new_total > $self->{max_bytes}) {
            $self->{_error} = "Request body $self->{limit_name} exceeded";
            $self->{_done} = 1;
            # More than the request's own Content-Length is a malformed
            # request; more than a limit the route set is too large.
            PAGI::Exception::RequestBody->throw(
                status_code => 400,
                reason      => 'invalid_body',
                message     => 'The request body is longer than its Content-Length.',
                cause       => $self->{_error},
            ) if $self->{limit_name} eq 'content-length';
            PAGI::Exception::RequestBody->throw(
                status_code => 413,
                reason      => 'too_large',
                message     => 'The request body is larger than this route accepts.',
                cause       => $self->{_error},
            );
        }
    }

    $self->{_bytes_read} += length($chunk);

    # Mark done if no more chunks
    $self->{_done} = 1 unless $more;

    # Decode if requested
    if ($self->{decode}) {
        $chunk = $self->_decode_chunk($chunk, !$more);
    }

    return $chunk;
}

=head2 bytes_read

    my $total = $stream->bytes_read;

Returns the total number of raw bytes read so far (before any decoding).

=cut

sub bytes_read {
    my ($self) = @_;
    return $self->{_bytes_read};
}

=head2 is_done

    if ($stream->is_done) { ... }

Returns true if the stream has been exhausted (no more chunks available).

=cut

sub is_done {
    my ($self) = @_;
    return $self->{_done};
}

=head2 error

    my $error = $stream->error;

Returns any error that occurred during streaming, or undef.

=cut

sub error {
    my ($self) = @_;
    return $self->{_error};
}

=head2 truncated

    if ($stream->truncated) { ... }

Returns true if the stream ended because the client disconnected after
sending some but not all of the body, rather than because the body was fully
delivered. C<next_chunk> still returns C<undef> in this case -- streaming
consumers may have legitimate uses for whatever partial data they already
collected -- so C<truncated> is how you tell "the client hung up early"
apart from "the body really ended here". An immediate disconnect before any
bytes ever arrive is treated as an empty stream, not a truncation. Check
the optional connection directly for a disconnect reason:

    my $connection = $req->connection;
    my $reason = $connection ? $connection->disconnect_reason : undef;

=cut

sub truncated {
    my ($self) = @_;
    return $self->{_truncated};
}

=head2 stream_to_file

    await $stream->stream_to_file($path);

Streams the entire request body to a file. Returns a Future that resolves
to the number of bytes written.

This is efficient for large uploads as it doesn't load the entire body into
memory - chunks are written incrementally as they arrive from the network.

B<Note:> File writes are B<blocking> (synchronous I/O). Since chunks are
typically small (e.g., 64KB), each write completes quickly. The method
remains async overall because it awaits network chunks between writes.

B<Note:> Cannot be used with the C<decode> option as that would corrupt binary
data. Use C<stream_to()> with a custom handler if you need decoded chunks
written to a file.

For fully non-blocking file I/O, use C<stream_to()> with your preferred
async file library:

    # Non-blocking alternative (bring your own async file library)
    await $stream->stream_to(async sub {
        my ($chunk) = @_;
        await $my_async_file_writer->write($chunk);
    });

=cut

async sub stream_to_file {
    my ($self, $path) = @_;
    croak("path is required") unless defined $path;
    # Checked here, not only in next_chunk: after the last line the loop below
    # never calls next_chunk, and the documented die would become a silent 0.
    croak 'stream_to_file: line reading has started; use next_line'
        if defined $self->{_lines};
    croak("stream_to_file() cannot be used with decode option - use stream_to() instead")
        if $self->{decode};

    my $bytes_written = 0;
    my $fh;

    while (!$self->is_done) {
        my $chunk = await $self->next_chunk;
        last unless defined $chunk;
        next unless length $chunk;

        # Open file on first chunk (truncate mode)
        unless ($fh) {
            open $fh, '>:raw', $path
                or croak("Cannot open $path for writing: $!");
        }

        # Blocking write - typically fast for small chunks
        print $fh $chunk
            or croak("Cannot write to $path: $!");

        $bytes_written += length($chunk);
    }

    # Close file if we opened it
    if ($fh) {
        close $fh
            or croak("Cannot close $path: $!");
    }

    return $bytes_written;
}

=head2 stream_to

    await $stream->stream_to(async sub ($chunk) {
        # Process chunk
    });

Streams the entire request body to a custom sink callback. The callback
receives each chunk and can be async (return a Future).

Returns a Future that resolves to the number of bytes processed, or of
characters when C<decode> is set (C<bytes_read> is always the byte count).

=cut

async sub stream_to {
    my ($self, $callback) = @_;
    croak("callback is required") unless $callback;
    croak 'stream_to: line reading has started; use next_line'
        if defined $self->{_lines};

    my $bytes_processed = 0;

    while (!$self->is_done) {
        my $chunk = await $self->next_chunk;
        last unless defined $chunk;
        next unless length $chunk;

        # Future->wrap is the complete sink contract: immediate values settle
        # now and real Future values retain their backpressure.
        my $result = $callback->($chunk);
        await Future->wrap($result);

        $bytes_processed += length($chunk);
    }

    return $bytes_processed;
}

=head2 next_line

    while (defined(my $line = await $stream->next_line)) { ... }

Resolves to the next line, without its C<\n> and without a C<\r> before it;
a last line without a newline is delivered; undef at the end. A client that
hangs up partway through a line ends the lines there, and C<truncated> is
true. After a body error (invalid bytes, C<max_bytes>, a line too long) the
lines end: C<next_line> resolves to undef and C<error> says why. A line longer than C<max_line_length> is a
L<PAGI::Exception::RequestBody> 413 (C<too_large>).

Once line reading starts, C<next_chunk>, C<stream_to> and C<stream_to_file>
die: the partial line held for C<next_line> would be lost.

=cut

async sub next_line {
    my ($self) = @_;
    # After a body error the lines end: a held fragment is not a line.
    return undef if $self->{_error};
    my $buffer = \($self->{_lines} //= '');
    while (1) {
        my $at = index $$buffer, "\n";
        if ($at >= 0) {
            my $line = substr $$buffer, 0, $at + 1, '';
            $line =~ s/\r?\n\z//;
            $self->_line_too_long if length $line > $self->{max_line_length};
            return $line;
        }
        # No newline yet: a line already longer than the limit never fits
        # (the one extra character may be the \r of a CRLF).
        $self->_line_too_long if length $$buffer > $self->{max_line_length} + 1;
        my $chunk = await $self->_read_chunk;
        if (!defined $chunk) {
            # A hang-up cut the last line short: it is dropped, as a partial
            # character is, and truncated says so.
            return undef if $self->{_truncated} || !length $$buffer;
            my $line = $$buffer;
            $$buffer = '';
            $line =~ s/\r\z//;
            $self->_line_too_long if length $line > $self->{max_line_length};
            return $line;
        }
        $$buffer .= $chunk;
    }
}

=head2 each_line

    my $count = await $stream->each_line(async sub ($line) { ... });

Calls the callback with each line (as L</next_line> reads them), awaiting a
Future it returns, and resolves to the number of lines. Empty lines are
delivered; skip them in the callback where the format allows them (NDJSON).

=cut

async sub each_line {
    my ($self, $callback) = @_;
    croak 'each_line: a callback is required' unless ref $callback eq 'CODE';
    my $count = 0;
    while (defined(my $line = await $self->next_line)) {
        # Future->wrap: a plain return settles now; a Future keeps backpressure.
        await Future->wrap($callback->($line));
        $count++;
    }
    return $count;
}

sub _line_too_long {
    my ($self) = @_;
    $self->{_error} = "line longer than max_line_length ($self->{max_line_length})";
    $self->{_done} = 1;
    $self->{_lines} = '';
    PAGI::Exception::RequestBody->throw(
        status_code => 413,
        reason      => 'too_large',
        message     => 'A line in the request body is longer than this route accepts.',
        cause       => $self->{_error},
    );
}

=head1 INTERNAL METHODS

=head2 _decode_chunk

Internal: hands a chunk to the stream's L<PAGI::Utils::TextDecoder>,
finishing it on the last chunk.

=cut

sub _decode_chunk {
    my ($self, $chunk, $last) = @_;
    my $text = eval {
        my $decoded = $self->{_decoder}->decode($chunk);
        $decoded .= $self->{_decoder}->finish if $last;
        $decoded;
    };
    return $text unless $@;

    # Bytes invalid in the encoding are the client's error, as for text.
    my $cause = $@;
    $self->{_error} = $cause;
    $self->{_done} = 1;
    PAGI::Exception::RequestBody->throw(
        reason  => 'invalid_encoding',
        message => "The request body is not valid $self->{decode}.",
        cause   => $cause,
    );
}

1;

__END__

=head1 EXAMPLES

=head2 Processing Large Uploads

    async sub upload_handler ($scope, $receive, $send) {
        my $stream = PAGI::Request::BodyStream->new(
            receive   => $receive,
            max_bytes => 100 * 1024 * 1024,  # 100MB limit
        );

        # Stream directly to file
        my $bytes = await $stream->stream_to_file('/uploads/data.bin');

        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => "Uploaded $bytes bytes\n",
            more => 0,
        });
    }

=head2 Line-by-Line Processing

NDJSON, one JSON document per line, read without holding the body:

    async sub import_events ($request) {
        my $stream = $request->body_stream(decode => 'UTF-8', strict => 1);
        my $json   = JSON::PP->new;    # decoded text in, so not decode_json
        my $events = 0;
        await $stream->each_line(sub ($line) {
            return unless length $line;    # NDJSON allows blank lines
            store_event($json->decode($line));
            $events++;
        });
        # each_line resolves to the count of all lines, blank ones included.
        return response('JSON', { events => $events });
    }

C<next_line> is the same one line at a time. A line ends at C<\n> (a C<\r>
before it is dropped); C<max_line_length> caps how much one line may buffer.

=head2 Custom Processing with Backpressure

    async sub hash_upload ($scope, $receive, $send) {
        use Digest::SHA;

        my $stream = PAGI::Request::BodyStream->new(receive => $receive);
        my $sha = Digest::SHA->new(256);

        my $bytes = await $stream->stream_to(async sub ($chunk) {
            $sha->add($chunk);

            # Simulate slow processing (backpressure)
            await some_slow_operation($chunk);
        });

        my $digest = $sha->hexdigest;

        # Send digest response...
    }

=head1 ERROR HANDLING

The stream throws exceptions in these cases:

=over 4

=item * C<max_bytes> exceeded - a L<PAGI::Exception::RequestBody> 413, or 400
past the request's own Content-Length

=item * Bytes invalid in the C<decode> encoding (with C<strict>) - a
L<PAGI::Exception::RequestBody> 400; an encoding it cannot decode is a 415 when
the stream is made

=item * File I/O errors during C<stream_to_file>

=back

Always wrap stream operations in eval/try-catch:

    use Syntax::Keyword::Try;

    try {
        await $stream->stream_to_file($path);
    }
    catch ($e) {
        # Handle error
        await send_error($send, 400, "Upload failed: $e");
    }

=head1 SEE ALSO

L<PAGI::Request>, L<Future::AsyncAwait>

=head1 AUTHOR

PAGI Contributors

=cut
