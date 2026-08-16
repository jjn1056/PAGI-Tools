package PAGI::Middleware::Static;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future;
use Future::AsyncAwait;
use PAGI::App::File;

=head1 NAME

PAGI::Middleware::Static - Static file serving middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'Static',
            root        => '/var/www/static',
            path        => qr{^/static/},
            pass_through => 1;
        $my_app;
    };

    # Rewrite /static/... to /...
    my $app = builder {
        enable 'Static',
            root => '/var/www/static',
            path => sub {
                my ($path) = @_;
                return unless $path =~ m{^/static/};
                $path =~ s{^/static}{/};
                return $path;  # Rewrite via return value
            };
        $my_app;
    };

    # Legacy (in-place) rewrite - still supported
    my $app = builder {
        enable 'Static',
            root => '/var/www/static',
            path => sub { $_[0] =~ s{^/static}{/} };
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::Static selects eligible requests, optionally rewrites their
local lookup path, and delegates file location and response generation to one
L<PAGI::App::File> engine constructed with the middleware.  The original
request scope is never rewritten.

=head1 CONFIGURATION

=over 4

=item * root (required)

The root directory to serve files from.

=item * path (default: qr{^/})

A regex or coderef to match request paths. Only matching paths are handled.

When C<path> is a coderef, it can also rewrite the request path:

=over 4

=item * Return a false value to skip static handling.

=item * Return the exact non-reference scalar C<1> to match using the current
local path, including any compatible in-place change made through C<$_[0]>.

=item * Return another true non-reference scalar to use it as the rewritten
path.

=item * Return a true reference to match without replacing the local path.

=back

In-place mutation of C<$_[0]> is still supported for compatibility, but
returning the rewritten path is preferred.

=item * pass_through (default: 0)

If true, pass requests to the inner app when the File engine classifies the
local path as missing or as a directory without an eligible index.  Forbidden
paths never pass through.

=item * index (default: ['index.html', 'index.htm'])

Array of index file names to try for directory requests.

=item * allow_hidden (default: 0)

Hidden request components are forbidden by default.  Set C<allow_hidden =E<gt>
1> to permit hidden request components and make hidden configured indexes
eligible.  This is the shared L<PAGI::App::File/allow_hidden> policy.

=item * handle_ranges (default: 1)

When enabled (default), the middleware processes Range request headers and returns
206 Partial Content responses. Set to 0 to ignore Range headers and always
return the full file.

B<When to disable Range handling:>

When using L<PAGI::Middleware::XSendfile> with a reverse proxy (Nginx, Apache),
you should disable range handling. The proxy will handle Range requests more
efficiently using its native sendfile implementation:

    my $app = builder {
        enable 'XSendfile',
            type    => 'X-Accel-Redirect',
            mapping => { '/var/www/files/' => '/protected/' };
        enable 'Static',
            root          => '/var/www/files',
            handle_ranges => 0;  # Let proxy handle Range requests
        $my_app;
    };

=back

=cut

sub _init {
    my ($self, $config) = @_;

    my $root = $config->{root}
        // die "Static middleware requires 'root' option";
    $self->{path} = $config->{path} // qr{^/};
    $self->{pass_through} = $config->{pass_through} // 0;
    $self->{file} = PAGI::App::File->new(
        root          => $root,
        index         => $config->{index} // ['index.html', 'index.htm'],
        handle_ranges => $config->{handle_ranges} // 1,
        allow_hidden  => $config->{allow_hidden} // 0,
    );
}

sub wrap {
    my ($self, $app) = @_;

    return async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} ne 'http') {
            return await Future->wrap($app->($scope, $receive, $send));
        }
        if ($scope->{method} ne 'GET' && $scope->{method} ne 'HEAD') {
            return await Future->wrap($app->($scope, $receive, $send));
        }

        my $path = $scope->{path};

        my $path_match = $self->{path};
        if (ref($path_match) eq 'Regexp') {
            unless ($path =~ $path_match) {
                return await Future->wrap(
                    $app->($scope, $receive, $send),
                );
            }
        } elsif (ref($path_match) eq 'CODE') {
            my $result = $path_match->($path);
            unless ($result) {
                return await Future->wrap(
                    $app->($scope, $receive, $send),
                );
            }
            if (defined $result && !ref($result) && $result ne '1') {
                $path = $result;
            }
        }

        # Normalize rewritten paths to start with /
        if (defined $path && $path ne '' && $path !~ m{^/}) {
            $path = '/' . $path;
        }

        my $result = $self->{file}->locate($path);
        if (($result->is_missing || $result->is_directory)
                && $self->{pass_through}) {
            return await Future->wrap($app->($scope, $receive, $send));
        }

        return await Future->wrap(
            $self->{file}->serve($scope, $send, $result),
        );
    };
}

1;

__END__

=head1 SECURITY

The shared File engine forbids unsafe request paths, traversal components,
mixed-separator traversal, null bytes, hidden components by default, and
unreadable files.  Forbidden Results always receive File's negotiated 403
response, even when C<pass_through> is enabled.

As with L<PAGI::App::File>, configured symbolic links are trusted and may point
outside the lexical root.  Use a dedicated tree that untrusted principals
cannot modify when physical confinement is required.

=head1 ELIGIBILITY AND PASS-THROUGH

Static examines the request in this order: HTTP scope, GET or HEAD method,
configured matcher, optional local rewrite, then File location.  A non-HTTP
scope, another method, or a matcher rejection reaches the inner application
unchanged.  With C<pass_through>, only missing Results and directories without
an eligible index reach the inner application.  Every bypass preserves the
same scope reference and original C<path>.

=head1 FILE RESPONSES

L<PAGI::App::File> owns MIME selection, the default
C<application/octet-stream> type, file metadata, ETags, conditional 304
responses, byte ranges, HEAD boundaries, negotiated errors, and raw C<file>
events.  Static does not open a filehandle, buffer a successful file into
memory, or implement a second response sender.

=head1 CACHING

Caching behavior is delegated to L<PAGI::App::File>.  Clients can use
C<If-None-Match> to receive its 304 Not Modified response.

=head1 RANGE REQUESTS

Range behavior is delegated to L<PAGI::App::File> and controlled by
C<handle_ranges>.

=head1 DIAGNOSTICS

Static performs no local access logging.  Its one File engine retains the
development-only candidate diagnostic documented by
L<PAGI::App::File/DEVELOPMENT DIAGNOSTICS>; production remains silent.

=head1 SEE ALSO

L<PAGI::App::File> - Shared file location and response engine

L<PAGI::Middleware> - Base class for middleware

=cut
