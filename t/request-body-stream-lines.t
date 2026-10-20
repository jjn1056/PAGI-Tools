use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use PAGI::Request::BodyStream;

# Line reading on a body stream: NDJSON uploads and other line formats.

sub stream_of {
    my ($chunks, %opts) = @_;
    my $end = delete $opts{end} // 'complete';
    my @events = map { { type => 'http.request', body => $_, more => 1 } } @$chunks;
    # A complete body ends with more => 0; a hang-up leaves more => 1 and disconnects.
    $events[-1]{more} = 0 if @events && $end eq 'complete';
    push @events, { type => 'http.disconnect' } if $end eq 'disconnect';
    return PAGI::Request::BodyStream->new(receive => async sub { shift @events // { type => 'http.disconnect' } }, %opts);
}

sub lines_of {
    my ($stream) = @_;
    my @lines;
    while (defined(my $line = $stream->next_line->get)) { push @lines, $line }
    return \@lines;
}

is lines_of(stream_of(["a\nb", "c\n\nd"])), ['a', 'bc', '', 'd'], 'lines across chunks; an empty line; a last line without a newline';
is lines_of(stream_of(["a\r", "\nb\r\n"])), ['a', 'b'], 'a CRLF split across chunks ends one line';
is lines_of(stream_of([])), [], 'no body, no lines';
is lines_of(stream_of(["x\xC3", "\xA9\n"], decode => 'UTF-8')), ["x\x{E9}"], 'decoded text: a character split across chunks';

my $cut = stream_of(["one\ntw"], end => 'disconnect');
is lines_of($cut), ['one'], 'a hang-up drops the partial last line';
ok $cut->truncated, 'and says the body was cut short';

my $long = stream_of(["12345\n"], max_line_length => 4);
my $error = dies { lines_of($long) };
isa_ok $error, ['PAGI::Exception::RequestBody'], 'a line over max_line_length';
is [$error->status_code, $error->reason], [413, 'too_large'], 'is the client\'s 413';

my $endless = stream_of(['12', '345', '6', '7890'], max_line_length => 4);
is [dies { lines_of($endless) }->status_code, $endless->bytes_read], [413, 6],
    'a line that never ends is cut off at the limit, not buffered whole';

my $each = stream_of(["a\nb\n"]);
my @seen;
is $each->each_line(async sub { my ($line) = @_; push @seen, $line })->get, 2, 'each_line resolves to the line count';
is \@seen, ['a', 'b'], 'and hands each line to the callback, awaiting it';

my $mixed = stream_of(["a\nb\n"]);
$mixed->next_line->get;
like dies { $mixed->next_chunk->get }, qr/next_chunk: line reading has started; use next_line/, 'chunks after lines would lose the buffer';
for my $method (qw(stream_to stream_to_file)) {
    my $finished = stream_of(["a\n"]);
    lines_of($finished);
    my @argument = $method eq 'stream_to' ? (sub { }) : ('/dev/null');
    like dies { $finished->$method(@argument)->get }, qr/\A$method: line reading has started; use next_line/,
        "$method dies once lines were read, even after the last one";
}

# After a body error the lines end: a held fragment is not a line.
for my $case (
    [ 'a decode 400',   ["good\npart", "\xFF\n"], decode => 'UTF-8', strict => 1 ],
    [ 'a max_bytes 413', ["ab\ncd", "efgh\n"],    max_bytes => 6 ],
    [ 'a line 413',      ["12345\nab\n"],         max_line_length => 4 ],
) {
    my ($label, $chunks, %opts) = @$case;
    my $stream = stream_of($chunks, %opts);
    my @before;
    my $error = dies { while (defined(my $line = $stream->next_line->get)) { push @before, $line } };
    ok $error, "$label is thrown";
    is $stream->next_line->get, undef, "after $label, next_line has no more lines";
    ok defined $stream->error, "and error says why";
}

done_testing;
