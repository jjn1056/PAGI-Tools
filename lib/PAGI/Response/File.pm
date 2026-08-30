package PAGI::Response::File;

use strict;
use warnings;

use Carp qw(croak);
use Exporter qw(import);
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(blessed);

use parent 'PAGI::Response';
use PAGI::Response::File::Plan ();

=encoding UTF-8

=head1 NAME

PAGI::Response::File - reusable response for one trusted selected file

=head1 SYNOPSIS

    use PAGI::Response qw(file_response);

    my $response = file_response(
        '/srv/reports/monthly.pdf',
        filename => 'monthly.pdf',
    );

=head1 DESCRIPTION

File owns request-time preflight and PAGI file-event delivery for exactly one
trusted, already selected filesystem path. It never maps C<< $scope->{path} >>
to disk. Use L<PAGI::App::File> when untrusted URL paths must be resolved under
a root with traversal, hidden-file, index, missing, and forbidden policy.

Construction validates configuration only. Existence, readability, metadata,
logical-window bounds, conditionals, and client ranges are evaluated before
response start for each invocation. The application opens no filehandle. Each
plan sends and awaits exactly one terminal PAGI C<http.response.body> event.
A full or ranged delivery plan uses an opaque C<file> event (normally status
200 or 206); a matching conditional plan (304) and an invalid-range plan (416)
use an ordinary empty C<body> event. An explicitly configured non-200 status
replaces the full plan's 200 while retaining its file delivery.

This deferred lifecycle lets a reusable value follow deployment replacement
and rotation of its selected path. A missing or unreadable direct File is a
pre-start application/resource failure, not App::File routing policy. If a
deployment requires startup validation, perform explicit C<-f>/C<-r> checks in
startup or lifespan code.

File returns C<undef> from C<protocol_response_capability> and therefore cannot
serve a WebSocket denial or SSE decline. This is the PAGI Www conformance
boundary: denial response bodies permit only the ordinary C<body> form and do
not use C<file> or C<fh>. See
L<PAGI::Spec::Www/"WebSocket Denial Response (extension)"> and
L<PAGI::Spec::Www/"Decline SSE - send event">.

=cut

our @EXPORT_OK = qw(file_response);

my %KNOWN_OPTIONS = map { $_ => 1 } qw(
    status content_type headers filename inline offset length handle_ranges etag
);
my %CALCULATED_HEADERS = map { $_ => 1 }
    qw(content-length content-range etag);

sub file_response {
    return PAGI::Response::File->new(@_);
}

sub new {
    my ($class, $path, @pairs) = @_;
    croak 'PAGI::Response::File->new requires a selected file path'
        unless @_ >= 2;
    croak 'File response path must be a defined nonempty scalar string'
        unless defined($path) && !ref($path) && length($path);
    croak 'File response path must not contain a NUL byte'
        if index($path, "\0") >= 0;

    my $options = _parse_file_options(@pairs);
    _nonnegative_integer('File response offset', $options->{offset})
        if exists $options->{offset};
    _nonnegative_integer('File response length', $options->{length})
        if exists $options->{length};
    _boolean('File response handle_ranges', $options->{handle_ranges})
        if exists $options->{handle_ranges};
    _boolean('File response inline', $options->{inline})
        if exists $options->{inline};

    if (exists $options->{filename}) {
        my $filename = $options->{filename};
        croak 'File response filename must be a defined scalar'
            unless defined($filename) && !ref($filename);
        croak 'File response filename must not contain control bytes'
            if $filename =~ /[\x00-\x1f\x7f]/;
    }

    my $etag_policy = 'auto';
    if (exists $options->{etag}) {
        my $etag = $options->{etag};
        croak 'File response ETag must be false, true, or a valid entity-tag'
            unless defined($etag) && !ref($etag);
        if (!$etag) {
            $etag_policy = undef;
        } elsif ($etag eq '1') {
            $etag_policy = 'auto';
        } else {
            croak 'File response ETag must be a valid entity-tag'
                unless PAGI::Response::File::Plan::_valid_entity_tag($etag);
            $etag_policy = $etag;
        }
    }

    my @common;
    for my $name (qw(status headers content_type)) {
        push @common, $name => $options->{$name} if exists $options->{$name};
    }
    my $self = $class->SUPER::new('', @common);
    delete $self->{_body};
    $self->{_path} = $path;
    $self->{_etag_policy} = $etag_policy;
    $self->{_handle_ranges} = exists($options->{handle_ranges})
        ? ($options->{handle_ranges} ? 1 : 0) : 1;
    for my $name (qw(filename inline offset length)) {
        $self->{"_$name"} = $options->{$name} if exists $options->{$name};
    }
    return $self;
}

sub default_content_type { return undef }

sub is_buffered { return 0 }

sub protocol_response_capability { return undef }

sub body {
    croak 'File response has no buffered body';
}

sub status {
    my ($self, $status) = @_;
    return $self->SUPER::status if @_ == 1;
    croak 'File response status 206 requires a valid request range plan'
        if defined($status) && !ref($status) && $status eq '206';
    return $self->SUPER::status($status);
}

sub header {
    my ($self, $name, $value) = @_;
    return $self->SUPER::header($name) if @_ == 2;
    if (defined($name) && !ref($name)) {
        my $lower = lc $name;
        croak "File response owns calculated header $name"
            if $CALCULATED_HEADERS{$lower};
    }
    return $self->SUPER::header($name, $value);
}

sub _plan_for_scope {
    my ($self, $scope) = @_;
    for my $header (@{$self->{_headers}->to_pairs}) {
        my $name = $header->[0];
        croak "File response owns calculated header $name"
            if $CALCULATED_HEADERS{lc $name};
    }
    my @args = (
        path          => $self->{_path},
        scope         => $scope,
        handle_ranges => $self->{_handle_ranges} && $self->status == 200
            ? 1 : 0,
        etag          => $self->{_etag_policy},
    );
    push @args, offset => $self->{_offset} if exists $self->{_offset};
    push @args, length => $self->{_length} if exists $self->{_length};
    return PAGI::Response::File::Plan->new(@args);
}

sub _wire_headers_for_plan {
    my ($self, $plan) = @_;
    my $planned = $plan->headers;
    my $configured = $self->{_headers}->to_pairs;
    @$configured = grep { lc($_->[0]) ne 'transfer-encoding' } @$configured;

    my %configured_names = map { lc($_->[0]) => 1 } @$configured;
    @$planned = grep {
        my $name = lc $_->[0];
        !$configured_names{$name} || $CALCULATED_HEADERS{$name};
    } @$planned;

    if (exists($self->{_filename}) || $self->{_inline}) {
        @$configured = grep { lc($_->[0]) ne 'content-disposition' }
            @$configured;
        my $disposition = $self->{_inline} ? 'inline' : 'attachment';
        if (exists $self->{_filename}) {
            my $filename = $self->{_filename};
            $filename =~ s/([\\"])/\\$1/g;
            $disposition .= qq{; filename="$filename"};
        }
        push @$configured, ['Content-Disposition', $disposition];
    }

    return [@$configured, @$planned];
}

async sub _respond_with_plan {
    my ($self, $send, $plan) = @_;
    croak 'File response send must be a coderef' unless ref($send) eq 'CODE';
    croak 'File response requires a File plan'
        unless blessed($plan) && $plan->isa('PAGI::Response::File::Plan');

    my $status = $plan->status == 200 ? $self->status : $plan->status;
    my $headers = $self->_wire_headers_for_plan($plan);
    my $body_event = $plan->body_event;
    await Future->wrap($send->({
        type    => 'http.response.start',
        status  => $status,
        headers => $headers,
    }))->without_cancel;
    await Future->wrap($send->($body_event))->without_cancel;
    return;
}

async sub respond {
    my ($self, $scope, $receive, $send) = @_;
    PAGI::Response::_validate_http_triplet($scope, $receive, $send);
    my $plan = $self->_plan_for_scope($scope);
    await $self->_respond_with_plan($send, $plan);
    return;
}

sub to_app {
    my ($self) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        await $self->respond($scope, $receive, $send);
        return;
    };
}

sub _parse_file_options {
    croak 'File response options must be name/value pairs' if @_ % 2;
    my %options;
    while (@_) {
        my ($name, $value) = splice @_, 0, 2;
        croak 'File response option names must be scalar strings'
            unless defined($name) && !ref($name) && length($name);
        croak "Unknown File response option '$name'"
            unless $KNOWN_OPTIONS{$name};
        croak "Duplicate File response option '$name'"
            if exists $options{$name};
        $options{$name} = $value;
    }
    return \%options;
}

sub _nonnegative_integer {
    my ($label, $value) = @_;
    croak "$label must be a nonnegative integer"
        unless defined($value) && !ref($value) && $value =~ /\A[0-9]+\z/;
    return;
}

sub _boolean {
    my ($label, $value) = @_;
    croak "$label must be a boolean"
        unless defined($value) && !ref($value)
            && ($value eq '0' || $value eq '1');
    return;
}

=head1 CONSTRUCTOR AND FACTORY CONTRACT

    use PAGI::Response qw(file_response);

    my $response = file_response($path,
        status        => 200,
        content_type  => 'application/pdf',
        headers       => ['Cache-Control' => 'private'],
        filename      => 'monthly.pdf',
        inline        => 0,
        offset        => 1024,
        length        => 65536,
        handle_ranges => 1,
        etag          => 1,
    );

C<file_response($path, %options)> and
C<< PAGI::Response::File->new($path, %options) >> accept the same contract.
The class form requires an explicit C<use PAGI::Response::File ();>; importing
the base factory alone does not eagerly load concrete subclasses.

C<$path> is a trusted, already selected path. It must be a defined, nonempty,
non-reference scalar and must contain no NUL byte. Construction does not check
whether it exists, is regular, or is readable; those checks occur during every
request preflight.

The only accepted option names are C<status>, C<content_type>, C<headers>,
C<filename>, C<inline>, C<offset>, C<length>, C<handle_ranges>, and C<etag>.
Options are flat name/value pairs; an odd list, non-scalar/empty option name,
unknown name, or duplicate name croaks synchronously.

=over 4

=item * C<status>

Uses the common Response status validation and defaults to 200. An explicit
status must be an integer from 100 through 599, but body-forbidden 1xx, 204,
205, and 304 are rejected. File additionally rejects an explicit 206: only a
valid request Range plan may select 206. Range handling is enabled only while
the configured status is 200. A matched C<If-None-Match> plan can select 304
for any configured status; when range handling is enabled, an invalid processed
Range selects 416.

=item * C<content_type>

Uses the common Response scalar-or-C<undef> contract. When absent or C<undef>,
request preflight selects a media type from the path extension and falls back
to C<application/octet-stream>. A configured scalar overrides that planned
field.

=item * C<headers>

Uses the common even-length flat arrayref. Every name is a defined, nonempty,
non-reference scalar and every value is a defined non-reference scalar; nested
pairs are rejected. File owns calculated C<Content-Length>,
C<Content-Range>, and C<ETag>, so supplying any of those fields through the
constructor or C<header> croaks (and preflight checks the mutable header
collection again). An application-supplied C<Transfer-Encoding> is removed at
emission. When C<filename> or true C<inline> generates Content-Disposition, it
replaces an application-supplied field of that name.

=item * C<filename>

Optional. It must be a defined non-reference scalar and may not contain bytes
C<0x00> through C<0x1f> or C<0x7f>. It does not select or alter C<$path>.
Without true C<inline>, it generates an attachment Content-Disposition;
backslash and double quote are escaped in the quoted filename parameter.

=item * C<inline>

Optional exact boolean scalar C<0> or C<1>; the default is false. True emits an
inline Content-Disposition, with a filename parameter when C<filename> is also
present. False with no C<filename> emits no generated disposition.

=item * C<offset>, C<length>

Optional nonnegative integer scalars containing only ASCII digits. Preflight
defaults C<offset> to zero and C<length> to the selected file size minus the
offset. It then requires C<offset> not to exceed the file size and
C<length> not to exceed the remaining bytes. Supplying either option makes the
resulting offset/length pair the physical window backing one complete logical
representation; it does not itself select 206 or create Content-Range. A
client Range is measured inside that logical length, then its start is added
to the physical offset.

=item * C<handle_ranges>

Optional exact boolean scalar C<0> or C<1>; the default is true. When true,
the configured status is 200, and the request method is exactly GET, File
parses one strict byte Range. False suppresses Range parsing; it does not remove
the planned C<Accept-Ranges: bytes> field. HEAD does not parse Range.

=item * C<etag>

Defaults to automatic generation from file metadata plus the logical window.
A false scalar (C<0> or the empty string) disables ETag. Exact C<1> requests
automatic generation. Every other value must be an unflagged valid strong or
weak quoted entity-tag; references, C<undef>, other true scalars, and malformed
tags croak.

=back

C<If-None-Match> compares the first field value exactly with the selected
ETag. File does not implement Last-Modified, If-Modified-Since, or If-Range.

For example, C<offset =E<gt> 1024, length =E<gt> 65536> is advertised as one
65536-byte 200 representation. C<Range: bytes=100-199> then produces logical
C<Content-Range: bytes 100-199/65536> and a physical file event at offset 1124
for 100 bytes. A configured window alone never claims that a client requested
a range.

=head1 METHODS

C<respond> performs all file inspection before response start, then awaits
response start and the plan's one terminal body event. C<to_app> retains the
exact File object, so later deliberate changes affect later invocations while
each request keeps its complete pre-start plan. C<is_buffered> returns false,
C<body> croaks, and
C<protocol_response_capability> returns C<undef>.

The capability opt-out is independent of buffering: Stream remains eligible
for protocol denial because it emits only ordinary body events. File opts out
because a successful delivery plan may emit an opaque C<file> event from the
C<file>/C<fh> vocabulary that PAGI Www explicitly excludes from WebSocket
denial and SSE decline bodies; the fact that its 304/416 plans use ordinary
empty bodies does not change that class-level capability.

=cut

1;
