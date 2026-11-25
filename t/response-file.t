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
