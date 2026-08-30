package PAGI::App::Directory;

use strict;
use warnings;
use Carp qw(croak);
use Encode qw(decode encode FB_CROAK LEAVE_SRC);
use Errno qw(EACCES EPERM);
use Fcntl qw(S_ISDIR);
use Future::AsyncAwait;
use parent 'PAGI::App::File';
use File::Spec;
use PAGI::Response::HTML ();
use PAGI::Response::JSON ();
use PAGI::Routing::HeadBoundary;
use PAGI::Utils ();

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
    my $text = _utf8_text($str);
    return undef unless defined $text;
    return encode('UTF-8', $text, FB_CROAK | LEAVE_SRC);
}

sub _utf8_text {
    my $str = shift;
    return undef unless defined $str;

    if (utf8::is_utf8($str)) {
        my $valid = eval {
            encode('UTF-8', $str, FB_CROAK | LEAVE_SRC);
            1;
        };
        return $valid ? $str : undef;
    }

    my $decoded = eval {
        decode('UTF-8', $str, FB_CROAK | LEAVE_SRC);
    };
    return $decoded;
}

# URL encode for href attributes
sub _url_encode {
    my $str = shift;
    return '' unless defined $str;
    $str = _utf8_bytes($str);
    return '' unless defined $str;
    $str =~ s/([^A-Za-z0-9\-_.~\/])/sprintf("%%%02X", ord($1))/ge;
    return $str;
}

sub _listing_entry_name {
    my ($self, $raw_name) = @_;
    my $name = _utf8_text($raw_name);
    return undef unless defined $name && length $name;

    my ($parts, $directory_intent)
        = PAGI::Utils::_validated_request_parts($name);
    return undef unless defined($parts)
        && @$parts == 1
        && $parts->[0] eq $name
        && !$directory_intent;
    return undef if !$self->{allow_hidden}
        && PAGI::App::File::_has_hidden_component($name);
    return $name;
}

sub _listing_path_parts {
    my ($fragment) = @_;
    my $text = _utf8_text($fragment);
    croak 'Directory request path must be valid decoded UTF-8'
        unless defined $text;
    return grep { length($_) && $_ ne '.' }
        split m{[\\/]}, $text, -1;
}

sub _public_listing_base {
    my ($scope) = @_;
    my @parts = map { _listing_path_parts($_) }
        ($scope->{root_path} // '', $scope->{path} // '/');

    return '/' unless @parts;
    return '/' . join('/', map { _url_encode($_) } @parts) . '/';
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

        my $relative_path = join '/', _listing_path_parts($request_path);
        return await $self->_send_listing(
            $listing_scope, $receive, $send, $result->path, $relative_path,
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
    my ($self, $scope, $receive, $send, $dir_path, $rel_path) = @_;

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
        my $name = $self->_listing_entry_name($entry);
        next unless defined $name;

        my $full_path = File::Spec->catfile($dir_path, $entry);
        my @stat = stat($full_path);
        unless (@stat) {
            my $stat_error = "$!";
            closedir $dh;
            croak "Cannot inspect directory entry '$full_path': $stat_error";
        }
        push @entries, {
            name  => $name,
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
        my $response = PAGI::Response::JSON->new(\@entries);
        return await PAGI::Utils::invoke_app(
            $response, $scope, $receive, $send,
        );
    }

    # HTML listing
    my $base_path = $rel_path eq '' ? '/' : "/$rel_path";
    $base_path =~ s{/+$}{};
    my $public_base = _public_listing_base($scope);

    # Escape base_path for safe HTML output
    my $escaped_path = _html_escape($base_path);

    my $html = "<!DOCTYPE html><html><head><title>Index of $escaped_path/</title>";
    $html .= '<style>body{font-family:sans-serif;margin:20px}table{border-collapse:collapse}';
    $html .= 'th,td{padding:8px 16px;text-align:left;border-bottom:1px solid #ddd}';
    $html .= 'a{text-decoration:none;color:#0066cc}a:hover{text-decoration:underline}</style></head>';
    $html .= "<body><h1>Index of $escaped_path/</h1><table><tr><th>Name</th><th>Size</th></tr>";

    if ($rel_path ne '') {
        my $parent_href = $public_base;
        $parent_href =~ s{[^/]+/\z}{};
        $html .= '<tr><td><a href="'
            . _html_escape($parent_href)
            . '">..</a></td><td>-</td></tr>';
    }

    for my $entry (@entries) {
        my $name = $entry->{name};
        my $display = $entry->{is_dir} ? "$name/" : $name;
        my $href = $public_base . _url_encode($name)
            . ($entry->{is_dir} ? '/' : '');
        my $size = $entry->{is_dir} ? '-' : _format_size($entry->{size});

        # Escape all user-controlled values to prevent XSS
        my $escaped_display = _html_escape($display);
        my $escaped_href = _html_escape($href);
        $html .= qq{<tr><td><a href="$escaped_href">$escaped_display</a></td><td>$size</td></tr>};
    }

    $html .= '</table></body></html>';

    my $response = PAGI::Response::HTML->new($html);
    return await PAGI::Utils::invoke_app(
        $response, $scope, $receive, $send,
    );
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

L<PAGI::App::File> therefore remains the owner of safe file and index
selection plus negotiated 403 and 404 responses, while selected files use the
shared L<PAGI::Response::File> ETag, range, conditional, and file-event plan.
The parent also handles unsupported methods before location and returns
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
C<.> and C<..> directory entries are never included.  Listings also omit a
filesystem name unless it is valid UTF-8 and round-trips as exactly one safe
component under the shared request grammar.  In particular, separator-bearing,
all-dot, platform-absolute, volumed, and non-UTF-8 byte names are omitted rather
than linked under a changed identity.  Entry and parent links are absolute
request paths built from C<root_path> and C<path>, so slashless and mounted
listings remain navigable without leaving their mount.

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
