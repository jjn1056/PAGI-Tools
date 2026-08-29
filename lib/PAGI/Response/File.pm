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
response start for each invocation. The application opens no filehandle; it
sends and awaits exactly one PAGI C<http.response.body> file event.

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

sub _snapshot {
    my ($self) = @_;
    my %copy = (
        _path          => $self->{_path},
        _etag_policy   => $self->{_etag_policy},
        _handle_ranges => $self->{_handle_ranges},
        _headers       => $self->{_headers}->clone,
    );
    $copy{_status} = $self->{_status} if $self->has_status;
    for my $name (qw(filename inline offset length)) {
        $copy{"_$name"} = $self->{"_$name"}
            if exists $self->{"_$name"};
    }
    return bless \%copy, ref($self);
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
    await Future->wrap($send->({
        type    => 'http.response.start',
        status  => $status,
        headers => $self->_wire_headers_for_plan($plan),
    }))->without_cancel;
    await Future->wrap($send->($plan->body_event))->without_cancel;
    return;
}

async sub respond {
    my ($self, $scope, $receive, $send) = @_;
    PAGI::Response::_validate_http_triplet($scope, $receive, $send);
    my $snapshot = $self->_snapshot;
    my $plan = $snapshot->_plan_for_scope($scope);
    await $snapshot->_respond_with_plan($send, $plan);
    return;
}

sub to_app {
    my ($self) = @_;
    my $snapshot = $self->_snapshot;
    return async sub {
        my ($scope, $receive, $send) = @_;
        await $snapshot->respond($scope, $receive, $send);
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

=head1 OPTIONS

C<filename> selects an attachment disposition unless C<inline> is true.
C<offset> and C<length> define the backing window for a complete logical 200
representation; they do not themselves create C<Content-Range>. A client
Range applies inside that logical representation and its offset is added to
the configured physical offset. C<handle_ranges> defaults true. C<etag>
accepts false, true/omission for automatic metadata-plus-window identity, or
a validated explicit entity tag.

File owns calculated C<Content-Length>, C<Content-Range>, and C<ETag>; callers
cannot supply those fields directly or select status 206 without a request
range plan. The initial conditional surface is intentionally limited to exact
C<If-None-Match>; it does not implement Last-Modified, If-Modified-Since, or
If-Range.

=head1 METHODS

C<respond> performs all file inspection before response start, then awaits
response start and one body event. C<to_app> captures a reusable configuration
snapshot. C<is_buffered> returns false, C<body> croaks, and
C<protocol_response_capability> returns C<undef>.

=cut

1;
