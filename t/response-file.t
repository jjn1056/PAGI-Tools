use v5.24;
use warnings;
use Test2::V0;
use Future;
use File::Spec;
use PAGI::Test::Client;
use Test::Lib;
use Test::TempDir::Tiny qw(tempdir);
use PAGITest::LowercaseHeaders;

use PAGI::Response::File;

my $dir = tempdir();

# A file in the temp directory with the bytes given; returns its absolute path.
sub file_with {
    my ($name, $bytes) = @_;
    my $path = File::Spec->catfile($dir, $name);
    open my $fh, '>:raw', $path or die "can't write $path: $!";
    print {$fh} $bytes;
    close $fh or die "can't close $path: $!";
    return $path;
}

# Serves a response for one request, as a strict server would.
sub get  { my ($response, %options) = @_; PAGI::Test::Client->new(app => $response)->get('/', %options) }
sub head { my ($response, %options) = @_; PAGI::Test::Client->new(app => $response)->head('/', %options) }

my $report = file_with('report.pdf', 'pdf bytes here');

subtest 'the whole file' => sub {
    my $res = get(PAGI::Response::File->new(path => $report));
    is $res->status, 200, 'status 200';
    is $res->content, 'pdf bytes here', 'the file, as the body';
    is $res->header('content-length'), 14, 'its length';
    is $res->header('content-type'), 'application/pdf', 'the type, from the extension';
};

subtest 'the content type' => sub {
    my $data = file_with('data', 'x');
    is get(PAGI::Response::File->new(path => $data))->header('content-type'),
        'application/octet-stream', 'an unknown extension: octet-stream';
    is get(PAGI::Response::File->new(path => $data, filename => 'data.csv'))->header('content-type'),
        'text/csv', 'from the filename when there is one, with no charset added';
    is get(PAGI::Response::File->new(path => $report, content_type => 'application/x-report'))->header('content-type'),
        'application/x-report', 'yours, when you give one';
};

subtest 'ETag and Last-Modified' => sub {
    my $response = PAGI::Response::File->new(path => $report);
    my ($first, $second) = (get($response), get($response));
    like $first->header('etag'), qr/\A"[0-9a-f]{32}"\z/, 'a strong ETag';
    is $second->header('etag'), $first->header('etag'), 'the same for the same file';
    like $first->header('last-modified'), qr/\A[A-Z][a-z]{2}, \d\d [A-Z][a-z]{2} \d{4} \d\d:\d\d:\d\d GMT\z/,
        'Last-Modified, an HTTP date';
    is get(PAGI::Response::File->new(path => $report, etag => 0))->header('etag'), undef, 'etag => 0: none';
};

subtest 'the ETag is the same for the same file on another server' => sub {
    # Two copies, as two servers behind a load balancer have: same bytes,
    # same time, different inode (and device, on a real second machine).
    my $one = file_with('copy-one.css', 'body { color: red }');
    my $two = file_with('copy-two.css', 'body { color: red }');
    utime 1_700_000_000, 1_700_000_000, $one, $two or die "can't set times: $!";
    chmod 0644, $one; chmod 0600, $two;
    is get(PAGI::Response::File->new(path => $two))->header('etag'),
        get(PAGI::Response::File->new(path => $one))->header('etag'),
        'the same ETag: it comes from the size and the time, not the disk or the permissions';
};

subtest 'Accept-Ranges' => sub {
    is get(PAGI::Response::File->new(path => $report))->header('accept-ranges'), 'bytes', 'by default';
    is get(PAGI::Response::File->new(path => $report, ranges => 0))->header('accept-ranges'), undef,
        'ranges => 0: none';
};

subtest 'Content-Disposition' => sub {
    my %disposition = (
        'attachment; filename="report.pdf"'             => [filename => 'report.pdf'],
        'attachment; filename="a\"b\\\\c.txt"'          => [filename => 'a"b\\c.txt'],
        q{attachment; filename*=UTF-8''Gr%C3%BC%C3%9Fe.txt} => [filename => "Gr\x{fc}\x{df}e.txt"],
        'inline'                                        => [inline => 1],
        'inline; filename="x.txt"'                      => [inline => 1, filename => 'x.txt'],
    );
    for my $expected (sort keys %disposition) {
        is get(PAGI::Response::File->new(path => $report, @{ $disposition{$expected} }))->header('content-disposition'),
            $expected, $expected;
    }
    is get(PAGI::Response::File->new(path => $report))->header('content-disposition'), undef, 'none by default';
};

subtest 'HEAD: the headers, no body' => sub {
    my $res = head(PAGI::Response::File->new(path => $report));
    is $res->status, 200, 'status 200';
    is $res->header('content-length'), 14, 'the length a GET would send';
    is $res->content, '', 'no body';
};

subtest 'an empty file' => sub {
    my $res = get(PAGI::Response::File->new(path => file_with('empty.txt', '')));
    is [$res->status, $res->header('content-length'), $res->content], [200, 0, ''], '200, length 0';
};

subtest 'what new refuses' => sub {
    like dies { PAGI::Response::File->new }, qr/\Apath is required: /, 'no path';
    like dies { PAGI::Response::File->new(path => 'report.pdf') }, qr/\Apath must be absolute: /, 'a relative path';
    like dies { PAGI::Response::File->new(path => "/srv/a\0b") }, qr/\Apath contains a NUL byte/, 'a NUL byte';
    like dies { PAGI::Response::File->new(path => $report, filename => "a\nb") },
        qr/\Afilename contains a control character/, 'a control character in the filename';
    for my $owned (qw(content-length Content-Range etag last-modified)) {
        my $name = lc $owned;
        like dies { PAGI::Response::File->new(path => $report, headers => [[$owned => 1]]) },
            qr/\AFile sets $name itself/, "a $name header";
    }
    like dies { PAGI::Response::File->new(path => $report, status => 206) }, qr/\Astatus 206 is File's to send/, 'status 206';
    like dies { PAGI::Response::File->new(path => $report, status => 204) }, qr/\Astatus 204 has no body/, 'status 204';
};

# A hundred bytes, A-Z over and over: byte N is chr(65 + N % 26).
my $alphabet = join '', map { chr(65 + $_ % 26) } 0 .. 99;
my $hundred  = file_with('hundred.txt', $alphabet);

subtest 'a byte range: 206 and that part' => sub {
    my %expect = (
        'bytes=0-9'    => [0, 9],
        'bytes=-5'     => [95, 99],
        'bytes=90-'    => [90, 99],
        'bytes=95-200' => [95, 99],    # an end past the file is the file's end
    );
    for my $range (sort keys %expect) {
        my ($first, $last) = @{ $expect{$range} };
        my $res = get(PAGI::Response::File->new(path => $hundred), headers => { range => $range });
        is [$res->status, $res->content, $res->header('content-range'), $res->header('content-length')],
            [206, substr($alphabet, $first, $last - $first + 1), "bytes $first-$last/100", $last - $first + 1],
            $range;
    }
};

subtest 'a range past the end: 416' => sub {
    for my $range ('bytes=100-', 'bytes=-0') {
        my $res = get(PAGI::Response::File->new(path => $hundred), headers => { range => $range });
        is [$res->status, $res->header('content-range'), $res->content], [416, 'bytes */100', ''], $range;
    }
    my $res = get(PAGI::Response::File->new(path => file_with('nothing.txt', '')), headers => { range => 'bytes=0-' });
    is [$res->status, $res->header('content-range')], [416, 'bytes */0'],
        'bytes=0- of an empty file: first-pos is not less than the length';
};

subtest 'a range File does not serve: the whole file' => sub {
    for my $range ('bytes=0-0,5-9', 'items=0-5', 'bytes=abc', 'bytes=9-0', 'bytes=-') {
        my $res = get(PAGI::Response::File->new(path => $hundred), headers => { range => $range });
        is [$res->status, $res->content], [200, $alphabet], $range;
    }
    my $res = get(PAGI::Response::File->new(path => $hundred, ranges => 0), headers => { range => 'bytes=0-9' });
    is [$res->status, $res->content], [200, $alphabet], 'ranges => 0';
    $res = get(PAGI::Response::File->new(path => $hundred, status => 203), headers => { range => 'bytes=0-9' });
    is [$res->status, $res->content], [203, $alphabet], 'a status other than 200';
    $res = head(PAGI::Response::File->new(path => $hundred), headers => { range => 'bytes=0-9' });
    is [$res->status, $res->header('content-length')], [200, 100], 'HEAD: ranges are for GET';
};

subtest 'If-Range: the range only for the same file' => sub {
    my $response = PAGI::Response::File->new(path => $hundred);
    my $now = get($response);
    my ($etag, $date) = ($now->header('etag'), $now->header('last-modified'));
    for my $case ([$etag, 206, 'the current ETag'], [$date, 206, 'the current Last-Modified'],
                  ['"stale"', 200, 'another ETag'], ['Thu, 01 Jan 1970 00:00:00 GMT', 200, 'another date']) {
        my ($if_range, $status, $name) = @$case;
        my $res = get($response, headers => { range => 'bytes=0-9', 'if-range' => $if_range });
        is $res->status, $status, $name;
    }

    # The file replaced: new length, new time, so a new ETag and Last-Modified.
    file_with('hundred.txt', "$alphabet!");
    utime time + 10, time + 10, $hundred or die "can't touch $hundred: $!";
    my $then = get($response, headers => { range => 'bytes=0-9', 'if-range' => $etag });
    is [$then->status, length $then->content], [200, 101], 'the old ETag gets the whole new file';
    isnt $then->header('etag'), $etag, 'a new ETag';
    isnt $then->header('last-modified'), $date, 'a new Last-Modified';
};

subtest 'If-None-Match: 304 when the client has this file' => sub {
    my $page = file_with('page.html', '<p>page</p>');
    my $response = PAGI::Response::File->new(path => $page);
    my $etag = get($response)->header('etag');

    my $res = get($response, headers => { 'if-none-match' => $etag });
    is [$res->status, $res->content], [304, ''], 'the same ETag: 304, no body';
    is $res->header('etag'), $etag, 'with the ETag';
    ok defined $res->header('last-modified'), 'and Last-Modified';
    is $res->header('content-length'), undef, 'and no length of the file';

    for my $case (["W/$etag", 'a weak ETag of the same tag'], ['*', 'any file'], [qq{"other", $etag}, 'one in a list']) {
        my ($if_none_match, $name) = @$case;
        is get($response, headers => { 'if-none-match' => $if_none_match })->status, 304, $name;
    }
    is get($response, headers => { 'if-none-match' => '"other"' })->status, 200, 'another ETag: the file';
};

subtest 'If-Modified-Since: 304 when the file is no newer' => sub {
    my $page = file_with('dated.html', '<p>dated</p>');
    my $response = PAGI::Response::File->new(path => $page);
    my $date = get($response)->header('last-modified');
    my $mtime = (stat $page)[9];

    is get($response, headers => { 'if-modified-since' => $date })->status, 304, 'its Last-Modified: 304';
    is get($response, headers => { 'if-modified-since' => PAGI::Response::_date($mtime - 1) })->status, 200,
        'a second earlier: the file';
    is get($response, headers => { 'if-modified-since' => 'not a date' })->status, 200, 'a date that does not parse: the file';
    is get($response, headers => { 'if-none-match' => '"other"', 'if-modified-since' => $date })->status, 200,
        'If-None-Match, when present, decides alone (RFC 9110 13.1.3)';
};

subtest 'when a 304 can be sent' => sub {
    my $page = file_with('when.html', '<p>when</p>');
    my $etag = get(PAGI::Response::File->new(path => $page))->header('etag');
    my %matching = ('if-none-match' => $etag);

    is head(PAGI::Response::File->new(path => $page), headers => \%matching)->status, 304, 'HEAD too';
    is(PAGI::Test::Client->new(app => PAGI::Response::File->new(path => $page))->post('/', headers => \%matching)->status,
        200, 'not a POST');
    is get(PAGI::Response::File->new(path => $page, status => 203), headers => \%matching)->status, 203,
        'not a status other than 200';
    is get(PAGI::Response::File->new(path => $page), headers => { %matching, range => 'bytes=0-1' })->status, 304,
        'before a Range';
};

subtest 'review fixes' => sub {
    # The filename's extension, else the path's (Minor 7).
    is get(PAGI::Response::File->new(path => $report, filename => 'report'))->header('content-type'),
        'application/pdf', 'a filename with no extension: the type from the path';

    # Your Content-Disposition is the one sent (Minor 8), as with Content-Type.
    my $res = get(PAGI::Response::File->new(path => $report, filename => 'x.pdf',
        headers => [['Content-Disposition', 'inline; filename="mine.pdf"']]));
    is [map { $_->[1] } grep { $_->[0] eq 'content-disposition' } @{ $res->header_pairs }],
        ['inline; filename="mine.pdf"'], 'one Content-Disposition, yours';

    # A suffix range of an empty file: satisfiable (RFC 9110 14.1.2), and the
    # whole file, nothing, is what it selects; a 206 can't say zero bytes, so
    # it's the whole response (ruled by John 2026-11-25: "follow 9110").
    my $empty = file_with('empty-suffix.txt', '');
    $res = get(PAGI::Response::File->new(path => $empty), headers => { range => 'bytes=-5' });
    is [$res->status, $res->header('content-length'), $res->header('content-range'), $res->content],
        [200, 0, undef, ''], 'bytes=-5 of an empty file: 200, length 0';
    $res = get(PAGI::Response::File->new(path => $empty), headers => { range => 'bytes=-0' });
    is [$res->status, $res->header('content-range')], [416, 'bytes */0'], 'bytes=-0 of an empty file: still 416';

    # The 416 says its body is empty (Minor 3).
    $res = get(PAGI::Response::File->new(path => $hundred), headers => { range => 'bytes=500-' });
    is $res->header('content-length'), 0, 'a 416 has content-length 0';

    # Statuses with no body (Minor 2).
    for my $status (101, 205, 304) {
        like dies { PAGI::Response::File->new(path => $report, status => $status) },
            qr/\Astatus $status has no body/, "status $status";
    }

    # If-None-Match with space after the tag (Minor 4).
    my $etag = get(PAGI::Response::File->new(path => $report))->header('etag');
    is get(PAGI::Response::File->new(path => $report), headers => { 'if-none-match' => "$etag " })->status,
        304, 'a tag followed by a space still matches';
};

# Serves a response with a recording $send; returns call's Future and what was sent.
sub call_recorded {
    my ($response) = @_;
    my @sent;
    my $call = $response->call({ type => 'http', method => 'GET', headers => [] }, sub { Future->new },
        sub { push @sent, $_[0]; Future->done });
    return ($call, \@sent);
}

subtest 'a file that is not there to serve dies before anything is sent' => sub {
    # Important 2: a directory, and a file this process can't read.
    my ($call, $sent) = call_recorded(PAGI::Response::File->new(path => $dir));
    like scalar $call->failure, qr/\Acan't serve \S+: not a regular file/, 'a directory';
    is $sent, [], 'nothing sent';

    SKIP: {
        skip 'root reads any file', 2 if $> == 0;
        my $locked = file_with('locked.txt', 'secret');
        chmod 0000, $locked or die "can't chmod $locked: $!";
        ($call, $sent) = call_recorded(PAGI::Response::File->new(path => $locked));
        like scalar $call->failure, qr/\Acan't serve \S+: not readable/, 'an unreadable file';
        is $sent, [], 'nothing sent';
        chmod 0600, $locked;
    }
};

subtest 'a missing file dies before anything is sent' => sub {
    my @sent;
    my $call = PAGI::Response::File->new(path => File::Spec->catfile($dir, 'nope.pdf'))->call(
        { type => 'http', method => 'GET', headers => [] }, sub { Future->new },
        sub { push @sent, $_[0]; Future->done },
    );
    ok $call->is_failed, 'the call fails';
    like scalar $call->failure, qr/\Acan't serve \S+nope\.pdf: /, 'naming the file and why';
    is \@sent, [], 'and nothing was sent';
};

done_testing;
