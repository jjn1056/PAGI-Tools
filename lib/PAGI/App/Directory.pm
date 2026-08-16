package PAGI::App::Directory;

use strict;
use warnings;
use bytes ();
use Carp qw(croak);
use Encode qw(decode encode FB_CROAK LEAVE_SRC);
use Errno qw(EACCES EPERM);
use Fcntl qw(S_ISDIR);
use Future::AsyncAwait;
use parent 'PAGI::App::File';
use JSON::MaybeXS ();
use File::Spec;
use PAGI::Routing::HeadBoundary;

=head1 NAME

PAGI::App::Directory - Serve files with directory listing

=head1 SYNOPSIS

    use PAGI::App::Directory;

    my $app = PAGI::App::Directory->new(
        root => '/var/www/files',
    )->to_app;

=cut

# HTML escape to prevent XSS
sub _html_escape {
    my $str = shift;
    return '' unless defined $str;
    $str =~ s/&/&amp;/g;
    $str =~ s/</&lt;/g;
    $str =~ s/>/&gt;/g;
    $str =~ s/"/&quot;/g;
    $str =~ s/'/&#39;/g;
    return $str;
}

sub _utf8_bytes {
    my $str = shift;
    return $str unless utf8::is_utf8($str);
    return encode('UTF-8', $str, FB_CROAK | LEAVE_SRC);
}

sub _utf8_text {
    my $str = shift;
    return $str if utf8::is_utf8($str);

    my $decoded = eval {
        decode('UTF-8', $str, FB_CROAK | LEAVE_SRC);
    };
    return defined($decoded) ? $decoded : $str;
}

# URL encode for href attributes
sub _url_encode {
    my $str = shift;
    return '' unless defined $str;
    $str = _utf8_bytes($str);
    $str =~ s/([^A-Za-z0-9\-_.~\/])/sprintf("%%%02X", ord($1))/ge;
    return $str;
}

sub to_app {
    my ($self) = @_;

    my $parent_app = $self->SUPER::to_app();

    return async sub  {
        my ($scope, $receive, $send) = @_;
        PAGI::App::File::_validate_http_scope($scope);

        my $method = PAGI::App::File::_scope_method($scope);
        unless ($method eq 'GET' || $method eq 'HEAD') {
            return await $parent_app->($scope, $receive, $send);
        }

        my $request_path = $scope->{path} // '/';
        my $result = $self->locate($request_path);
        return await $self->serve($scope, $send, $result)
            unless $result->is_directory;

        my $listing_scope = $scope;
        $listing_scope = { %$scope, method => $method }
            if defined($scope->{method}) && !ref($scope->{method})
                && $scope->{method} ne $method;
        ($listing_scope, $send)
            = PAGI::Routing::HeadBoundary->prepare($listing_scope, $send);

        my $relative_path = $request_path;
        $relative_path =~ s{^/+}{};
        return await $self->_send_listing(
            $send, $listing_scope, $result->path, $relative_path,
        );
    };
}

sub _open_directory {
    my ($self, $dir_path) = @_;
    opendir my $dh, $dir_path or return;
    return $dh;
}

sub _close_directory {
    my ($self, $dh) = @_;
    return closedir $dh;
}

async sub _send_listing {
    my ($self, $send, $scope, $dir_path, $rel_path) = @_;

    $! = 0;
    my $dh = $self->_open_directory($dir_path);
    my $open_errno = 0 + $!;
    my $open_error = "$!";
    unless ($dh) {
        return await PAGI::App::File::_respond_page(
            $scope, $send, 'forbidden',
        ) if $open_errno == EACCES || $open_errno == EPERM;
        croak "Cannot open directory '$dir_path': $open_error";
    }

    my @entries;
    while (1) {
        $! = 0;
        my $entry = readdir $dh;
        unless (defined $entry) {
            my $read_errno = 0 + $!;
            my $read_error = "$!";
            if ($read_errno) {
                closedir $dh;
                croak "Cannot read directory '$dir_path': $read_error";
            }
            last;
        }

        next if $entry eq '.' || $entry eq '..';
        next if !$self->{allow_hidden} && $entry =~ /^\./;

        my $full_path = File::Spec->catfile($dir_path, $entry);
        my @stat = stat($full_path);
        unless (@stat) {
            my $stat_error = "$!";
            closedir $dh;
            croak "Cannot inspect directory entry '$full_path': $stat_error";
        }
        push @entries, {
            name  => $entry,
            is_dir => S_ISDIR($stat[2]) ? 1 : 0,
            size  => $stat[7] // 0,
            mtime => $stat[9] // 0,
        };
    }
    unless ($self->_close_directory($dh)) {
        my $close_error = "$!";
        croak "Cannot close directory '$dir_path': $close_error";
    }

    # Sort directories first, then by name
    @entries = sort { $b->{is_dir} <=> $a->{is_dir} || $a->{name} cmp $b->{name} } @entries;

    # Check Accept header for JSON
    my $accept = $self->_get_header($scope, 'accept') // '';
    if ($accept =~ m{application/json}) {
        my @json_entries = map {
            +{ %$_, name => _utf8_text($_->{name}) }
        } @entries;
        my $json = JSON::MaybeXS::encode_json(\@json_entries);
        await $send->({
            type => 'http.response.start',
            status => 200,
            headers => [
                ['content-type', 'application/json'],
                ['content-length', bytes::length($json)],
            ],
        });
        await $send->({ type => 'http.response.body', body => $json, more => 0 });
        return;
    }

    # HTML listing
    my $base_path = $rel_path eq '' ? '/' : "/$rel_path";
    $base_path =~ s{/+$}{};

    # Escape base_path for safe HTML output
    my $escaped_path = _utf8_bytes(_html_escape($base_path));

    my $html = "<!DOCTYPE html><html><head><title>Index of $escaped_path/</title>";
    $html .= '<style>body{font-family:sans-serif;margin:20px}table{border-collapse:collapse}';
    $html .= 'th,td{padding:8px 16px;text-align:left;border-bottom:1px solid #ddd}';
    $html .= 'a{text-decoration:none;color:#0066cc}a:hover{text-decoration:underline}</style></head>';
    $html .= "<body><h1>Index of $escaped_path/</h1><table><tr><th>Name</th><th>Size</th></tr>";

    if ($rel_path ne '') {
        $html .= '<tr><td><a href="../">..</a></td><td>-</td></tr>';
    }

    for my $entry (@entries) {
        my $name = $entry->{name};
        my $display = $entry->{is_dir} ? "$name/" : $name;
        my $href = "$name" . ($entry->{is_dir} ? '/' : '');
        my $size = $entry->{is_dir} ? '-' : _format_size($entry->{size});

        # Escape all user-controlled values to prevent XSS
        my $escaped_display = _utf8_bytes(_html_escape($display));
        my $escaped_href = _html_escape(_url_encode($href));
        $html .= qq{<tr><td><a href="$escaped_href">$escaped_display</a></td><td>$size</td></tr>};
    }

    $html .= '</table></body></html>';

    await $send->({
        type => 'http.response.start',
        status => 200,
        headers => [
            ['content-type', 'text/html; charset=utf-8'],
            ['content-length', bytes::length($html)],
        ],
    });
    await $send->({ type => 'http.response.body', body => $html, more => 0 });
}

sub _format_size {
    my $size = shift;
    return '0' if $size == 0;
    my @units = qw(B KB MB GB);
    my $i = 0;
    while ($size >= 1024 && $i < $#units) {
        $size /= 1024;
        $i++;
    }
    return sprintf("%.1f %s", $size, $units[$i]);
}

1;

__END__

=head1 DESCRIPTION

PAGI::App::Directory is a L<PAGI::App::File> subclass that adds one policy:
an index-free directory receives an HTML or JSON listing.  It uses the one
inherited C<locate> result for each GET or HEAD request and delegates every
non-directory result to inherited C<serve>.

L<PAGI::App::File> therefore remains the owner of file and index responses,
ETags, ranges, conditional requests, file events, and negotiated 403 and 404
responses.  It also handles unsupported methods before location and returns
the negotiated 405 response with C<Allow: GET, HEAD>.  Directory listings are
available only to GET and HEAD.  HEAD preserves the matching GET status and
headers while emitting no listing bytes.

An C<opendir> permission error uses the negotiated L<PAGI::Pages> forbidden
response.  Unexpected directory listing I/O failures propagate to the server.
As with L<PAGI::App::File>, configured symbolic links are trusted and may point
outside the lexical root; use a tree that untrusted principals cannot modify.
HTML listings declare and emit UTF-8; JSON listings are likewise UTF-8 octets.

=head1 CONFIGURATION

All configuration is inherited from L<PAGI::App::File>.  In particular,
C<allow_hidden> defaults to false and governs both direct file retrieval and
entries included in a listing.  Set it to true to allow both.  The special
C<.> and C<..> directory entries are never included.

=over 4

=item * C<allow_hidden> - Include and directly serve hidden names (default: 0)

=back

=head1 JSON FORMAT

When Accept header contains C<application/json>, returns JSON:

    [
      { "name": "file.txt", "is_dir": 0, "size": 1234, "mtime": 1234567890 },
      { "name": "subdir",   "is_dir": 1, "size": 0,    "mtime": 1234567890 }
    ]

=cut
