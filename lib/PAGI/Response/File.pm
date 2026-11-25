package PAGI::Response::File;

use v5.24;
use warnings;
use parent 'PAGI::Response';
use Carp ();
use Digest::MD5 ();
use Encode ();
use File::Spec;
use Future::AsyncAwait;
use overload ();

my %MIME_TYPE = (
    html => 'text/html', htm => 'text/html', css => 'text/css', js => 'application/javascript',
    json => 'application/json', xml => 'application/xml', txt => 'text/plain', csv => 'text/csv',
    pl => 'text/plain', md => 'text/plain', png => 'image/png', jpg => 'image/jpeg',
    jpeg => 'image/jpeg', gif => 'image/gif', svg => 'image/svg+xml', ico => 'image/x-icon',
    webp => 'image/webp', woff => 'font/woff', woff2 => 'font/woff2', ttf => 'font/ttf',
    otf => 'font/otf', eot => 'application/vnd.ms-fontobject', pdf => 'application/pdf',
    zip => 'application/zip', gz => 'application/gzip', tar => 'application/x-tar',
    mp3 => 'audio/mpeg', mp4 => 'video/mp4', webm => 'video/webm', ogg => 'audio/ogg',
    wav => 'audio/wav',
);

# The headers that describe the file, which File works out per request.
my %OWNED = map { $_ => 1 } qw(content-length content-range etag last-modified);

# The configuration, checked here, once; the file itself is looked at per
# request, in call, so a file replaced on disk is served as it is now.
sub prepare {
    my ($self, $args) = @_;
    my $path = _string($args->{path}, 'path');
    Carp::croak('path is required: the absolute path of the file to send')
        unless defined $path && length $path;
    Carp::croak('path contains a NUL byte') if $path =~ /\0/;
    Carp::croak("path must be absolute: the server opens it, not your working directory (use File::Spec->rel2abs)")
        unless File::Spec->file_name_is_absolute($path);
    my $filename = _string($args->{filename}, 'filename');
    Carp::croak('filename contains a control character')
        if defined $filename && $filename =~ /[\x00-\x1F\x7F]/;
    for my $header (@{ $args->{headers} // [] }) {
        (my $name = $header->[0]) =~ tr/A-Z/a-z/;
        Carp::croak("File sets $name itself, from the file it sends") if $OWNED{$name};
    }
    $self->{path}     = $path;
    $self->{filename} = $filename;
    $self->{etag}     = $args->{etag}   // 1;
    $self->{ranges}   = $args->{ranges} // 1;
    $self->SUPER::prepare($args);
    # Yours is the one sent, if you gave one, as for Content-Type.
    my $has_disposition = grep { $_->[0] eq 'content-disposition' } @{ $self->{headers} };
    push @{ $self->{headers} }, ['content-disposition', _content_disposition($args->{inline} ? 'inline' : 'attachment', $filename)]
        if !$has_disposition && (defined $filename || $args->{inline});
    return;
}

# The status: yours, else 200. File always sends the file, so not a status
# with no body, and not 206, which it sends itself for a Range request.
sub prepare_status {
    my ($self, $args) = @_;
    my $status = $self->SUPER::prepare_status($args);
    Carp::croak("status 206 is File's to send, for a Range request") if $status eq '206';
    Carp::croak("status $status has no body: File always sends one")
        if $status =~ /\A1\d\d\z/ || $status eq '204' || $status eq '205' || $status eq '304';
    return $status;
}

# No body to buffer: the server reads the file when the response is sent.
sub prepare_body { return undef }

# The type you gave, else the one the filename's extension names, else the
# path's; else application/octet-stream. No charset is added: File sends
# bytes it hasn't read.
sub prepare_content_type {
    my ($self, $args, %prepared) = @_;
    return $args->{content_type} if exists $args->{content_type};
    return _known_type($self->{filename}) // _known_type($self->{path}) // 'application/octet-stream';
}

# Serving the file: looked at now, then the start and one file event.
async sub call {
    my ($self, $scope, $receive, $send) = @_;
    my $path = $self->{path};
    my @stat = stat $path or Carp::croak("can't serve $path: $!");
    Carp::croak("can't serve $path: not a regular file") unless -f _;
    Carp::croak("can't serve $path: not readable") unless -r _;
    my $size          = $stat[7];
    my $etag          = $self->{etag} ? _etag(@stat) : undef;
    my $last_modified = PAGI::Response::_date($stat[9]);
    my @headers       = map { [@$_] } @{ $self->headers };
    my @validators    = ((defined $etag ? ['etag', $etag] : ()), ['last-modified', $last_modified]);
    my @accept        = $self->{ranges} ? ['accept-ranges', 'bytes'] : ();

    if ($self->_not_modified($scope, $etag, $stat[9])) {
        await $send->({ type => 'http.response.start', status => 304, headers => [@headers, @validators] });
        await $send->({ type => 'http.response.body', body => '', more => 0 });
        return;
    }

    my @range = $self->_requested_range($scope, $size, $etag, $last_modified);
    if (@range == 1) {    # unsatisfiable
        await $send->({ type => 'http.response.start', status => 416,
            headers => [@headers, ['content-range', "bytes */$size"], ['content-length', 0], @accept, @validators] });
        await $send->({ type => 'http.response.body', body => '', more => 0 });
        return;
    }
    if (@range == 2) {
        my ($first, $last) = @range;
        my $length = $last - $first + 1;
        await $send->({ type => 'http.response.start', status => 206,
            headers => [@headers, ['content-length', $length], ['content-range', "bytes $first-$last/$size"], @accept, @validators] });
        await $send->({ type => 'http.response.body', file => $path, offset => $first, length => $length });
        return;
    }
    await $send->({ type => 'http.response.start', status => $self->status,
        headers => [@headers, ['content-length', $size], @accept, @validators] });
    await $send->({ type => 'http.response.body', file => $path });
    return;
}

# The byte range the request asks for, if File serves it: (first, last)
# for a 206, ('unsatisfiable') for a 416, else () and the whole file. Only
# for a GET of a 200 with ranges on, one bytes= range (RFC 9110 14.2 lets
# a server ignore the rest), and an If-Range naming this file as it is.
sub _requested_range {
    my ($self, $scope, $size, $etag, $last_modified) = @_;
    return () unless $self->{ranges} && $self->status eq '200' && ($scope->{method} // '') eq 'GET';
    my $range = _request_header($scope, 'range');
    return () unless defined $range;
    my $if_range = _request_header($scope, 'if-range');
    return () if defined $if_range && !_same_file($if_range, $etag, $last_modified);
    return _byte_range($range, $size);
}

# Whether the client already has this file, so a 304 does: for a GET or
# HEAD of a 200 (RFC 9110 13.1.3). If-None-Match, when present, decides
# alone: a weak match of any tag it lists, or *, means not modified.
# Otherwise If-Modified-Since: not modified unless the file is newer.
sub _not_modified {
    my ($self, $scope, $etag, $mtime) = @_;
    my $method = $scope->{method} // '';
    return 0 unless $self->status eq '200' && ($method eq 'GET' || $method eq 'HEAD');
    my $if_none_match = _request_header($scope, 'if-none-match');
    if (defined $if_none_match) {
        return 1 if $if_none_match =~ /\A\s*\*\s*\z/;
        return 0 unless defined $etag;
        my $opaque = _opaque_tag($etag);
        return scalar grep { _opaque_tag($_) eq $opaque } split /\s*,\s*/, $if_none_match;
    }
    my $since = _parse_http_date(_request_header($scope, 'if-modified-since'));
    return defined $since && $mtime <= $since;
}

# An entity-tag without its weakness, for the weak comparison.
sub _opaque_tag {
    my ($tag) = @_;
    $tag =~ s/\A\s*W\///;
    $tag =~ s/\s+\z//;
    return $tag;
}

my %MONTH_NUMBER = (Jan => 0, Feb => 1, Mar => 2, Apr => 3, May => 4, Jun => 5,
                    Jul => 6, Aug => 7, Sep => 8, Oct => 9, Nov => 10, Dec => 11);

# An IMF-fixdate (RFC 9110 5.6.7), "Sun, 06 Nov 1994 08:49:37 GMT", as an
# epoch; undef for anything else.
sub _parse_http_date {
    my ($date) = @_;
    return undef unless defined $date;
    my ($mday, $month, $year, $hour, $min, $sec)
        = $date =~ /\A\s*[A-Z][a-z]{2}, (\d\d) ([A-Z][a-z]{2}) (\d{4}) (\d\d):(\d\d):(\d\d) GMT\s*\z/a
        or return undef;
    return undef unless exists $MONTH_NUMBER{$month};
    require Time::Local;
    return eval { Time::Local::timegm($sec, $min, $hour, $mday, $MONTH_NUMBER{$month}, $year) };
}

# An If-Range names this file: its strong ETag, or its Last-Modified exactly.
sub _same_file {
    my ($if_range, $etag, $last_modified) = @_;
    return defined $etag && $if_range eq $etag if $if_range =~ /\A(?:W\/)?"/;
    return $if_range eq $last_modified;
}

sub _byte_range {
    my ($range, $size) = @_;
    my ($first, $last) = $range =~ /\Abytes=(\d*)-(\d*)\z/a or return ();
    if (!length $first) {    # a suffix: the last N bytes
        return () unless length $last;
        return ('unsatisfiable') if $last == 0;
        return () if $size == 0;    # satisfiable, and it selects all of nothing: the whole file
        return ($last >= $size ? 0 : $size - $last, $size - 1);
    }
    return () if length $last && $last < $first;    # invalid: ignored
    return ('unsatisfiable') if $first >= $size;
    $last = $size - 1 if !length $last || $last >= $size;
    return ($first, $last);
}

# A request header's value, the fields of that name joined with ', ' as
# RFC 9110 5.3 allows; undef if there's none.
sub _request_header {
    my ($scope, $name) = @_;
    my @values = map { $_->[1] } grep { lc $_->[0] eq $name } @{ $scope->{headers} // [] };
    return @values ? join(', ', @values) : undef;
}

# A value as a string: undef stays undef, an object that overloads
# stringification is its string, any other reference croaks.
sub _string {
    my ($value, $name) = @_;
    return undef unless defined $value;
    Carp::croak("$name must be a string, or an object that stringifies")
        if ref $value && !overload::Method($value, '""');
    return "$value";
}

# The type a name's extension is known for, else undef.
sub _known_type {
    my ($name) = @_;
    return undef unless defined $name;
    my ($extension) = $name =~ /\.([^.\/]+)\z/;
    return defined $extension ? $MIME_TYPE{ lc $extension } : undef;
}

# A strong validator for this file as it is: what stat says identifies it
# and changes when it's replaced or written.
sub _etag {
    my @stat = @_;
    return '"' . Digest::MD5::md5_hex(join '-', @stat[0, 1, 2, 7, 9]) . '"';
}

# Content-Disposition (RFC 6266): an ASCII filename quoted, with " and \
# escaped; any other as RFC 8187 UTF-8, percent-encoded.
sub _content_disposition {
    my ($disposition, $filename) = @_;
    return $disposition unless defined $filename;
    if ($filename =~ /\A[\x20-\x7E]*\z/) {
        (my $quoted = $filename) =~ s/(["\\])/\\$1/g;
        return qq{$disposition; filename="$quoted"};
    }
    my $encoded = Encode::encode('UTF-8', $filename);
    $encoded =~ s/([^A-Za-z0-9!#\$&+\-.^_`|~])/sprintf '%%%02X', ord $1/ge;
    return "$disposition; filename*=UTF-8''$encoded";
}

1;

=encoding UTF-8

=head1 NAME

PAGI::Response::File - a response that sends a file from disk

=head1 SYNOPSIS

    use v5.40;
    use Future::AsyncAwait;
    use PAGI::Response::File;

    my $app = async sub ($scope, $receive, $send) {
        die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';
        my $response = PAGI::Response::File->new(
            path     => '/srv/reports/monthly.pdf',
            filename => 'monthly.pdf',    # downloaded under this name
        );
        await $response->call($scope, $receive, $send);
    };

    $app;

=head1 DESCRIPTION

A L<PAGI::Response> that sends one file you've already chosen: the server
opens it and sends it (a C<file> body event, L<PAGI::Spec::Www>), so the
application never reads it. File never turns a request's path into a file
on disk; choosing the file, and refusing paths that escape a directory, is
yours.

What you give is checked when you build the response. The file is looked
at each time the response is sent, so the same response serves a file
that's replaced on disk as it is then, with its own length and validators.
For that reason C<status> and C<headers> give what you configured: the
length, ETag and Last-Modified are worked out per request, from the file.

A missing, unreadable or non-regular file dies when the response is sent,
before anything goes out, so the server answers with a 500. Check that the
file is there first if a missing one should be a 404.

File isn't a L<PAGI::Response::Stream>: it sends one event, the server
sends the file, and there's no body of yours to run or cancel.

=head1 CONSTRUCTOR ARGUMENTS

=over 4

=item path

Required. The file, as an absolute path: the server opens it, not your
process's working directory, so a relative path dies (make one absolute
with C<< File::Spec->rel2abs >>). An object that overloads stringification,
such as L<Path::Tiny>, is its string.

=item filename

The name the browser saves the file under: sends
C<Content-Disposition: attachment; filename="...">. A name that isn't
printable ASCII is sent as C<filename*=UTF-8''...> (RFC 6266, RFC 8187).
It also picks the content type, by its extension, when you give none.

=item inline

True to send C<Content-Disposition: inline>, with the filename if you gave
one: shown in the browser rather than saved.

=item content_type

The type, sent as given. Without one, it's named by the extension of the
filename, else of the path, from a short table of common types; anything
else is C<application/octet-stream>. No charset is added: File sends bytes
it hasn't read, so give the type with its charset when you know it.

=item status

200 unless you give one. Not 206, which File sends for a Range request, and
not a status with no body (1xx, 204, 205, 304).

=item headers

As L<PAGI::Response>'s, except Content-Length, Content-Range, ETag and
Last-Modified, which describe the file and which File sets itself: giving
one dies. A Content-Disposition you give is the one sent, in place of the
one C<filename> and C<inline> would make.

=item etag

True (the default) to send a strong ETag for the file as it is; false to
send none.

=item ranges

True (the default) to send C<Accept-Ranges: bytes>.

=back

=head1 METHODS

=head2 prepare

Checks the configuration, as described under L</CONSTRUCTOR ARGUMENTS>, then
does L<PAGI::Response>'s steps and adds the Content-Disposition. A subclass
with arguments of its own extends this.

=head2 prepare_status

The status you gave, else 200, refusing 206 and a status with no body.

=head2 prepare_body

C<undef>: there's no body to buffer, since the server reads the file.

=head2 prepare_content_type

The type you gave, else the one the filename's extension names, else the
path's, else C<application/octet-stream>.

=head2 call

    await $response->call($scope, $receive, $send);

Looks at the file, then sends the start, with the file's Content-Length,
ETag and Last-Modified, and the file. A HEAD request gets the same headers;
the server sends no body.

=head1 CONDITIONAL REQUESTS

A browser that has the file already sends back what it was told about it,
and File answers C<304 Not Modified>, with no body, when the file is
unchanged (RFC 9110 13):

=over 4

=item *

C<If-None-Match> with the file's ETag, as given or weak (C<W/"...">), or in a
list, or C<*>: 304.

=item *

Otherwise C<If-Modified-Since> with a date no earlier than the file's
Last-Modified: 304. A date that isn't an HTTP date is ignored.

=back

When C<If-None-Match> is there it decides alone, and C<If-Modified-Since> is
not looked at. A 304 is sent only for a GET or HEAD of a 200, before any
Range is looked at, and carries the ETag and Last-Modified.

=head1 RANGES

A GET with a C<Range> header gets part of the file, as a download manager
resuming, or a video player seeking, asks for it. File serves one range of
bytes (RFC 9110 14): C<bytes=0-99>, C<bytes=100->, or the last N bytes,
C<bytes=-500>.

=over 4

=item *

A range within the file: C<206 Partial Content>, that part, and a
C<Content-Range> such as C<bytes 0-99/1000>. An end past the file is the
file's end.

=item *

A range starting at or past the end (C<bytes=0-> of an empty file too), or
the last zero bytes (C<bytes=-0>): C<416 Range Not Satisfiable>, with
C<Content-Range: bytes */SIZE>.

=item *

The last N bytes of an empty file: the whole file, a 200 of length 0. RFC
9110 counts that range satisfiable, and a 206 can't say zero bytes.

=item *

Anything else, several ranges, another unit, or a range that doesn't parse,
gets the whole file, as RFC 9110 lets a server do.

=item *

With C<If-Range>, the range is served only if it names the file as it is
now: its ETag, or its Last-Modified date exactly. Otherwise the client gets
the whole file, so it never stitches together parts of two versions.

=back

Ranges are for a GET of a 200: a HEAD, another status, or
C<< ranges => 0 >> gets the whole file.

=head1 SEE ALSO

L<PAGI::Response>, L<PAGI::Spec::Www> (the C<file> body event)

=cut
