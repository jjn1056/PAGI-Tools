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
    push @{ $self->{headers} }, ['content-disposition', _content_disposition($args->{inline} ? 'inline' : 'attachment', $filename)]
        if defined $filename || $args->{inline};
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

# The type you gave, else the one the filename's extension, then the
# path's, names; else application/octet-stream. No charset is added: File
# sends bytes it hasn't read.
sub prepare_content_type {
    my ($self, $args, %prepared) = @_;
    return $args->{content_type} if exists $args->{content_type};
    return _content_type_for($self->{filename} // $self->{path});
}

# Serving the file: looked at now, then the start and one file event.
async sub call {
    my ($self, $scope, $receive, $send) = @_;
    my $path = $self->{path};
    my @stat = stat $path or Carp::croak("can't serve $path: $!");
    Carp::croak("can't serve $path: not a regular file") unless -f _;
    Carp::croak("can't serve $path: not readable") unless -r _;
    my @headers = map { [@$_] } @{ $self->headers };
    push @headers, ['content-length', $stat[7]];
    push @headers, ['accept-ranges', 'bytes'] if $self->{ranges};
    push @headers, ['etag', _etag(@stat)] if $self->{etag};
    push @headers, ['last-modified', PAGI::Response::_date($stat[9])];
    await $send->({ type => 'http.response.start', status => $self->status, headers => \@headers });
    await $send->({ type => 'http.response.body', file => $path });
    return;
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

sub _content_type_for {
    my ($name) = @_;
    my ($extension) = $name =~ /\.([^.\/]+)\z/;
    return $MIME_TYPE{ lc($extension // '') } // 'application/octet-stream';
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
one dies.

=item etag

True (the default) to send a strong ETag for the file as it is; false to
send none.

=item ranges

True (the default) to send C<Accept-Ranges: bytes>.

=back

=head1 METHODS

=head2 call

    await $response->call($scope, $receive, $send);

Looks at the file, then sends the start, with the file's Content-Length,
ETag and Last-Modified, and the file. A HEAD request gets the same headers;
the server sends no body.

=head1 SEE ALSO

L<PAGI::Response>, L<PAGI::Spec::Www> (the C<file> body event)

=cut
