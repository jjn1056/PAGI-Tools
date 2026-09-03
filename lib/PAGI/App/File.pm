package PAGI::App::File;

use strict;
use warnings;
use Future;
use Future::AsyncAwait;
use Carp qw(croak);
use Errno qw(EACCES ENOENT ENOTDIR EPERM);
use Fcntl qw(S_ISDIR S_ISREG);
use File::Spec;
use Scalar::Util qw(blessed);
use PAGI::App::File::Result;
use PAGI::Pages;
use PAGI::Response::File;
use PAGI::Response::File::Plan ();
use PAGI::Routing::HeadBoundary;
use PAGI::Utils ();

=head1 NAME

PAGI::App::File - Serve static files

=head1 SYNOPSIS

    use PAGI::App::File;

    my $app = PAGI::App::File->new(
        root => '/var/www/static',
    )->to_app;

    my $files = PAGI::App::File->from_app_path('static');
    my $app   = PAGI::App::File->from_app_path('static')->to_app;

The component can be mounted directly in a declarative router:

    use PAGI::Routing qw(router mount);

    my $routing = router(routes => [
        mount('/static', app => PAGI::App::File->from_app_path('static')),
    ]);

The named C<app> option matters: Route is a complete URL leaf, while this Mount
composes the file application under a prefix and passes the remaining child
path to it.

=head1 DESCRIPTION

PAGI::App::File serves static files from a configured root directory. It
resolves an untrusted request URL path and owns traversal, hidden-file, index,
missing, forbidden, and method policy. After it selects one trusted regular
path, it delegates metadata and delivery planning to
L<PAGI::Response::File>. A direct File Response is the complementary value: it
sends one path the application already selected and never interprets the
request URL.

=head2 Features

=over 4

=item * Efficient streaming (no memory bloat for large files)

=item * ETag caching with If-None-Match support (304 Not Modified)

=item * Range requests (HTTP 206 Partial Content)

=item * Automatic MIME type detection for common file types

=item * Index file resolution (index.html, index.htm)

=back

=head2 Security

This module implements multiple layers of path traversal protection:

=over 4

=item * Null byte injection blocking

=item * Double-dot and triple-dot component blocking

=item * Backslash normalization (Windows path separator)

=item * Hidden file policy (dotfiles are blocked unless C<allow_hidden> is true)

=item * Lexically rooted request-path construction

=back

The synchronous L</locate> boundary neither resolves symbolic links nor enforces
physical containment.  Symbolic links created by the administrator are trusted
and may point outside the configured lexical root.  Use a dedicated tree that
cannot be modified by untrusted principals when physical confinement is
required.

=head1 CONFIGURATION

=head2 root

The root defaults to the current directory.  It is converted to a lexical
absolute path when the component is constructed, so a later C<chdir> does not
change it.  Construction does not require the root to exist.

=head2 allow_hidden

Hidden request components are forbidden by default.  Hidden configured indexes
are instead ineligible and skipped during index selection.  Set
C<allow_hidden =E<gt> 1> to permit hidden request components and make hidden
indexes eligible.

=head2 index

An array reference of index names, examined in declaration order.  The first
regular candidate ends selection; an unreadable regular candidate is
forbidden rather than bypassed in favor of a later index.

=head1 METHODS

=head2 locate

    my $result = $files->locate($request_path);

Synchronously constructs and inspects one request's lexical candidate and
returns a L<PAGI::App::File::Result>.  The selected file's size and mtime are
captured in the Result as location metadata.
Index candidates may each be inspected while selecting in declaration order.

C<locate> does not open a filehandle.  The PAGI server remains responsible for
opening a later C<file> response event, leaving the normal trusted-tree pathname
race between inspection and open.

=head2 serve

    await $files->serve($scope, $send, $result);

Asynchronously renders any Result returned by L</locate>. File Results pass
only their trusted selected path into L<PAGI::Response::File>'s shared
request-time metadata, MIME, ETag, conditional-request, strict range, and file
event plan. The response contains a PAGI C<file> body event, so the server owns
the eventual open; C<serve> does not open the pathname itself.

Missing and directory Results render a negotiated 404, while forbidden Results
render a negotiated 403.  Callers may intercept a Result before choosing
whether to pass it to C<serve>.  The method requires an explicit HTTP scope,
owns only GET and HEAD, and renders a negotiated 405 with C<Allow: GET, HEAD>
for other methods.  HEAD preserves the corresponding GET status and headers
without emitting file or body bytes.

Range handling accepts exactly one anchored ASCII C<bytes=start-end> interval,
including open-ended and suffix forms.  An absent Range field selects the full
representation.  Empty or repeated fields, empty or zero-length suffixes,
malformed values, and multi-ranges receive 416; an end beyond the
representation is clamped to its final byte.

Because C<serve> hands the file off as an opaque C<file> body event, the
server -- not this module -- owns the actual open and read. The returned
Future does not settle until that streaming completes, so a read failure
partway through the file (permissions change, device error, file truncated
or removed mid-stream) now fails the Future instead of silently completing
as if the file had ended -- a mid-body read error is not the same as
reaching EOF. Callers awaiting C<serve> should treat a failed Future as an
aborted response, the same way they would treat any other abnormal
disconnect, rather than assuming the file was necessarily delivered in full.

=cut

sub import {
    my $class = shift;
    my ($package, $source) = caller;

    require PAGI::Utils;
    PAGI::Utils::_remember_app_path_origin($package, $source);
    return;
}

sub from_app_path {
    my ($class, @components) = @_;
    croak 'PAGI::App::File->from_app_path is a class constructor '
        . 'and requires a class invocant'
        if ref($class);

    my ($package, $source) = caller;
    require PAGI::Utils;
    my $root = PAGI::Utils::_app_path_from_origin(
        $package, $source, @components,
    );

    return $class->new(root => $root);
}

sub new {
    my ($class, %args) = @_;

    my $root = exists $args{root} ? $args{root} : '.';
    croak 'File root must be a defined, nonempty, non-reference string'
        unless defined($root) && !ref($root) && length($root);

    my $index = $args{index} // ['index.html', 'index.htm'];
    croak 'File index must be an array reference'
        unless ref($index) eq 'ARRAY';
    for my $name (@$index) {
        croak 'File index entries must be defined non-reference strings'
            unless defined($name) && !ref($name);
    }

    my $absolute_root = File::Spec->canonpath(File::Spec->rel2abs($root));

    my $self = bless {
        root          => $absolute_root,
        allow_hidden  => $args{allow_hidden} ? 1 : 0,
        default_type  => $args{default_type} // 'application/octet-stream',
        index         => $index,
        handle_ranges => $args{handle_ranges} // 1,
    }, $class;
    return $self;
}

sub _has_hidden_component {
    my ($path) = @_;
    for my $component (split m{[\\/]}, $path, -1) {
        next if $component eq '' || $component eq '.';
        return 1 if substr($component, 0, 1) eq '.';
    }
    return 0;
}

sub _probe_path {
    my ($self, $path) = @_;
    my @stat = stat($path);
    unless (@stat) {
        my $errno = 0 + $!;
        my $error = "$!";
        return { errno => $errno, error => $error };
    }

    my $readable = -r _ ? 1 : 0;
    return { stat => \@stat, readable => $readable };
}

sub _result {
    my ($kind, $path, $probe) = @_;
    my %args = (kind => $kind, path => $path);
    if ($kind eq 'file') {
        $args{size} = $probe->{stat}[7];
        $args{mtime} = $probe->{stat}[9];
    }
    return PAGI::App::File::Result->new(%args);
}

sub _error_kind {
    my ($probe) = @_;
    my $errno = $probe->{errno};
    return 'missing' if $errno == ENOENT || $errno == ENOTDIR;
    return 'forbidden' if $errno == EACCES || $errno == EPERM;
    return;
}

sub _unexpected_probe_error {
    my ($path, $probe) = @_;
    my $message = defined($probe->{error}) ? $probe->{error} : 'unknown error';
    croak "Cannot inspect file candidate '$path': $message";
}

sub _path_from_root {
    my ($self, $request_path) = @_;
    return PAGI::Utils::path_from_root($self->{root}, $request_path);
}

sub locate {
    my ($self, $request_path) = @_;
    croak 'locate requires exactly one request path' unless @_ == 2;

    my $path = $self->_path_from_root($request_path);
    return _result('forbidden', undef) unless defined $path;
    return _result('forbidden', $path)
        if !$self->{allow_hidden} && _has_hidden_component($request_path);

    my $probe = $self->_probe_path($path);
    if (exists $probe->{errno}) {
        _development_file_attempt($path);
        my $kind = _error_kind($probe);
        return _result($kind, $path) if defined $kind;
        _unexpected_probe_error($path, $probe);
    }

    my $mode = $probe->{stat}[2];
    unless (S_ISDIR($mode)) {
        _development_file_attempt($path);
        return _result('missing', $path) unless S_ISREG($mode);
        return _result('forbidden', $path) unless $probe->{readable};
        return _result('file', $path, $probe);
    }

    for my $index (@{$self->{index}}) {
        next if !$self->{allow_hidden} && _has_hidden_component($index);

        my $index_path = File::Spec->catfile($path, $index);
        my $index_probe = $self->_probe_path($index_path);
        if (exists $index_probe->{errno}) {
            my $kind = _error_kind($index_probe);
            next if defined($kind) && $kind eq 'missing';
            _development_file_attempt($index_path);
            return _result('forbidden', $index_path)
                if defined($kind) && $kind eq 'forbidden';
            _unexpected_probe_error($index_path, $index_probe);
        }

        next unless S_ISREG($index_probe->{stat}[2]);
        _development_file_attempt($index_path);
        return _result('forbidden', $index_path)
            unless $index_probe->{readable};
        return _result('file', $index_path, $index_probe);
    }

    _development_file_attempt($path);
    return _result('directory', $path);
}

sub _development_file_attempt {
    my ($file_path) = @_;
    require PAGI::Utils;
    return unless PAGI::Utils::is_development();

    my $display = $file_path;
    $display =~ s/([\x00-\x1f\x7f])/sprintf('\\x%02X', ord($1))/ge;
    print STDOUT "PAGI::App::File: attempting $display\n";
    return;
}

sub to_app {
    my ($self) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        _validate_http_scope($scope);

        my $method = _scope_method($scope);
        unless ($method eq 'GET' || $method eq 'HEAD') {
            my ($response_scope, $response_send)
                = PAGI::Routing::HeadBoundary->prepare($scope, $send);
            return await _respond_page(
                $response_scope, $response_send, 'method_not_allowed',
                allow => [qw(GET HEAD)],
            );
        }

        my $path = $scope->{path} // '/';
        my $result = $self->locate($path);
        return await $self->serve($scope, $send, $result);
    };
}

sub _validate_http_scope {
    my ($scope) = @_;
    croak 'PAGI::App::File scope must be an unblessed hashref'
        unless ref($scope) eq 'HASH' && !blessed($scope);

    my $type = $scope->{type};
    croak 'PAGI::App::File scope type is required'
        unless defined($type) && !ref($type) && length($type);
    croak "PAGI::App::File requires HTTP scope; received '$type'"
        unless $type eq 'http';
    return;
}

sub _scope_method {
    my ($scope) = @_;
    my $method = $scope->{method};
    return '' unless defined($method) && !ref($method);
    return uc($method);
}

async sub serve {
    my ($self, $scope, $send, $result) = @_;
    croak 'serve requires a scope, send callback, and Result'
        unless @_ == 4;
    _validate_http_scope($scope);
    croak 'PAGI::App::File serve send must be a coderef'
        unless ref($send) eq 'CODE';
    croak 'PAGI::App::File serve Result must be a PAGI::App::File::Result object'
        unless blessed($result)
            && $result->isa('PAGI::App::File::Result');

    my $method = _scope_method($scope);
    my $boundary_scope = $scope;
    $boundary_scope = { %$scope, method => $method }
        if defined($scope->{method}) && !ref($scope->{method})
            && $scope->{method} ne $method;
    ($boundary_scope, $send)
        = PAGI::Routing::HeadBoundary->prepare($boundary_scope, $send);

    return await _respond_page(
        $boundary_scope, $send, 'method_not_allowed',
        allow => [qw(GET HEAD)],
    ) unless $method eq 'GET' || $method eq 'HEAD';
    return await _respond_page($boundary_scope, $send, 'not_found')
        if $result->is_missing || $result->is_directory;
    return await _respond_page($boundary_scope, $send, 'forbidden')
        if $result->is_forbidden;

    my $file_path = $result->path;
    my @file_options = (handle_ranges => $self->{handle_ranges});
    my $default_type = PAGI::Response::File::Plan->_content_type_for(
        $file_path, 'application/octet-stream',
    );
    if ($default_type eq 'application/octet-stream'
            && $self->{default_type} ne $default_type) {
        push @file_options, content_type => $self->{default_type};
    }

    my $response = PAGI::Response::File->new(
        $file_path, @file_options,
    );
    my $plan = $response->_plan_for_scope($boundary_scope);
    if ($plan->status == 416) {
        return await _respond_page(
            $boundary_scope, $send, 'range_not_satisfiable',
            length => $plan->_logical_length,
        );
    }

    return await $response->_respond_with_plan($send, $plan);
}

sub _get_header_values {
    my ($self, $scope, $name) = @_;

    $name = lc $name;
    my @values;
    for my $header (@{$scope->{headers} // []}) {
        push @values, $header->[1]
            if lc($header->[0]) eq $name;
    }
    return @values;
}

sub _get_header {
    my ($self, $scope, $name) = @_;
    my @values = $self->_get_header_values($scope, $name);
    return @values ? $values[0] : undef;
}

async sub _respond_page {
    my ($scope, $send, $method, @options) = @_;
    my $response = PAGI::Pages->$method(@options);
    my $receive = sub {
        return Future->done({ type => 'http.disconnect' });
    };
    return await PAGI::Utils::invoke_app(
        $response, $scope, $receive, $send,
    );
}

1;

__END__

=head1 CONSTRUCTORS

=head2 from_app_path

    my $files = PAGI::App::File->from_app_path('static');
    my $app   = PAGI::App::File->from_app_path('static')->to_app;

Returns a C<PAGI::App::File> app object rooted at the application path
formed from its logical path components. It is a class-only constructor and
preserves subclasses, so C<< MyApp::Files->from_app_path('static') >> returns a
C<MyApp::Files> object. With no path components it selects the application
home. All arguments are path components; use C<< ->new(root =E<gt> ...) >>
when advanced file-app options are required.

Do not confuse this class constructor with L<PAGI::Utils/app_path>, which
returns an absolute path string for application-owned selection:

    my $path = app_path('public', 'index.html');
    my $app  = PAGI::App::File->from_app_path('static');

Filesystem existence is not required at component construction. Request-time
selection and File preflight observe the current tree. Applications that need
startup configuration validation must perform explicit checks during startup
or lifespan handling.

Its C<PAGI_HOME> precedence and path-component semantics are shared with
L<PAGI::Utils/app_path>. Each ordinary C<use PAGI::App::File> records that
file's caller origin so relative module sources remain anchored if the process
later changes directory. C<use PAGI::App::File ()> and C<require
PAGI::App::File> do not record that origin; use C<PAGI_HOME> as the explicit
escape hatch in those cases. The origin registrar and resolver are unsupported
internals.

=head1 DEVELOPMENT DIAGNOSTICS

At request time, C<PAGI_ENV=development> makes this application write one
record to C<STDOUT> after index selection and before it checks whether the
candidate is a readable file. For example:

    PAGI::App::File: attempting /Project-MyApp/static/css/app.css

Both existing and missing candidates are reported. Unset, empty, C<test>,
C<staging>, and C<production> values are silent. Any other nonempty value
fails through L<PAGI::Utils/pagi_env>, so environment typos are not silently
accepted. Requests rejected before this diagnostic boundary, including
unsupported methods, null bytes, traversal components, and hidden components,
do not inspect the environment and remain silent. ASCII control bytes in the
displayed path are escaped as C<\xNN>, so every diagnostic remains one physical
line. The record shows the lexical candidate rather than a resolved symlink
path, can disclose absolute paths, is not access logging, and never changes a
response or file event. The component performs no production logging.

=head1 CONFIGURATION

Stock 403, 404, 405, and 416 errors are rendered by L<PAGI::Pages> and negotiate
among HTML, problem JSON, and plain text from the request C<Accept> header.
Unsafe, hidden, or unreadable paths are 403; missing paths and unintercepted
directories are 404; and unsupported methods are 405. These defaults are
non-cacheable; 405 responses advertise C<GET, HEAD>, and 416 responses include
the known representation length. After safe selection, successful file
metadata, MIME selection, streaming, caching, and range planning are delegated
to L<PAGI::Response::File>. This component retains its C<default_type> seam for
unknown suffixes.

See L<PAGI::Routing::Mount> for prefix composition and L<PAGI::Compose> for
root ErrorHandler, response-completion, and lifespan ownership.

=over 4

=item * root - Root directory for files

=item * default_type - Default MIME type (default: application/octet-stream)

=item * index - Index file names (default: [index.html, index.htm])

=item * handle_ranges - Process Range headers (default: 1)

When enabled (default), the app processes Range request headers and returns
206 Partial Content responses. Set to 0 to ignore Range headers and always
return the full file.

B<When to disable Range handling:>

When using L<PAGI::Middleware::XSendfile> with a reverse proxy (Nginx, Apache),
you should disable range handling. The proxy will handle Range requests more
efficiently using its native sendfile implementation:

    my $app = PAGI::App::File->new(
        root          => '/var/www/files',
        handle_ranges => 0,  # Let proxy handle Range requests
    )->to_app;

    my $wrapped = builder {
        enable 'XSendfile',
            type    => 'X-Accel-Redirect',
            mapping => { '/var/www/files/' => '/protected/' };
        $app;
    };

With this setup, your app always sends the full file path via X-Sendfile header,
and Nginx handles Range requests natively (which is faster than doing it in Perl).

=back

=cut
