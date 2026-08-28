package PAGI::Response;

use strict;
use warnings;

use Carp qw(croak);
use Cookie::Baker ();
use Exporter qw(import);
use Future::AsyncAwait;
use PAGI::Headers ();
use Scalar::Util qw(blessed);

=encoding UTF-8

=head1 NAME

PAGI::Response - complete buffered byte response value

=head1 SYNOPSIS

    my $response = PAGI::Response->new(
        $bytes,
        status  => 201,
        headers => ['X-Request-ID' => $request_id],
    );

    await $response->respond($scope, $receive, $send);

    mount('/health', app => $response->to_app);

=head1 DESCRIPTION

The base response is an already-encoded finite byte body.  It stores no
request scope, receive callback, send callback, connection state, file, or
stream.  An unchanged response can therefore be emitted for multiple HTTP
invocations.  Header changes are allowed before emission; each emission uses
an invocation-local snapshot.

Unicode text and structured values belong to representation subclasses.  The
base class accepts only an unflagged byte scalar.  C<default_content_type> and
C<render> are the finite-representation subclass hooks.

=head1 METHODS

=head2 new

    PAGI::Response->new($bytes, %options)

Creates a complete buffered response.  The supported options are C<status>,
C<content_type>, and C<headers>, where C<headers> is an even-length flat
arrayref of name/value pairs.

=head2 respond

    await $response->respond($scope, $receive, $send)

Validates a native HTTP triplet, sends C<http.response.start>, waits for its
Future, then sends and waits for one terminal C<http.response.body> event.

=head2 to_app

Returns an async HTTP application coderef with a response snapshot captured
when C<to_app> is called.

=cut

my %KNOWN_OPTIONS = map { $_ => 1 } qw(status content_type headers);

our @EXPORT_OK = qw(
    response text_response html_response json_response problem_response
    redirect_response empty_response file_response stream_response
);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

sub response {
    return PAGI::Response->new(@_);
}

sub text_response {
    require PAGI::Response::Text;
    return PAGI::Response::Text->new(@_);
}

sub html_response {
    require PAGI::Response::HTML;
    return PAGI::Response::HTML->new(@_);
}

sub json_response {
    require PAGI::Response::JSON;
    return PAGI::Response::JSON->new(@_);
}

sub problem_response {
    require PAGI::Response::Problem;
    return PAGI::Response::Problem->new(@_);
}

sub redirect_response {
    require PAGI::Response::Redirect;
    return PAGI::Response::Redirect->new(@_);
}

sub empty_response {
    require PAGI::Response::Empty;
    return PAGI::Response::Empty->new(@_);
}

sub file_response {
    require PAGI::Response::File;
    return PAGI::Response::File->new(@_);
}

sub stream_response {
    require PAGI::Response::Stream;
    return PAGI::Response::Stream->new(@_);
}

sub new {
    my ($class, $value, @pairs) = @_;
    croak 'PAGI::Response->new requires a body byte scalar'
        unless @_ >= 2;
    my $options = _parse_options(@pairs);

    my $self = bless { _headers => PAGI::Headers->new }, $class;
    my $body = $self->render($value);
    _require_bytes('response body', $body);
    $self->{_body} = $body;

    $self->status($options->{status}) if exists $options->{status};
    if (exists $options->{headers}) {
        my $headers = $options->{headers};
        croak 'headers must be an arrayref of flat name/value pairs'
            unless ref($headers) eq 'ARRAY';
        croak 'headers must be flat name/value pairs, not nested pairs'
            if grep { ref } @$headers;
        croak 'headers must be an even-length flat arrayref [ name => value, ... ]'
            if @$headers % 2;
        for (my $index = 0; $index < @$headers; $index += 2) {
            my ($name, $header_value) = @{$headers}[$index, $index + 1];
            $self->header($name, $header_value);
        }
    }
    $self->content_type($options->{content_type})
        if exists $options->{content_type};
    $self->content_type_try($self->default_content_type);
    return $self;
}

sub default_content_type { 'application/octet-stream' }
sub render { $_[1] }

sub status {
    my ($self, $code) = @_;
    return $self->{_status} // 200 if @_ == 1;
    _validate_status($code);
    croak "response body is forbidden for status $code"
        if _status_forbids_body($code) && !$self->_allows_body_forbidden_status;
    $self->{_status} = $code;
    return $self;
}

sub has_status { exists $_[0]->{_status} ? 1 : 0 }

sub status_try {
    my ($self, $code) = @_;
    return $self if $self->has_status;
    return $self->status($code);
}

sub headers { $_[0]->{_headers} }

sub header {
    my ($self, $name, $value) = @_;
    croak 'Header name is required' unless defined $name && !ref($name) && length $name;
    return $self->{_headers}->get($name) if @_ == 2;
    croak 'Header value is required' unless defined $value && !ref($value);
    $self->{_headers}->add($name, $value);
    return $self;
}

sub header_all {
    my ($self, $name) = @_;
    croak 'Header name is required' unless defined $name && !ref($name) && length $name;
    return [ $self->{_headers}->get_all($name) ];
}

sub has_header { $_[0]->{_headers}->has($_[1]) ? 1 : 0 }

sub header_try {
    my ($self, $name, $value) = @_;
    return $self if $self->has_header($name);
    return $self->header($name, $value);
}

sub remove_header {
    my ($self, $name) = @_;
    croak 'Header name is required' unless defined $name && !ref($name) && length $name;
    $self->{_headers}->remove($name);
    return $self;
}

sub content_type {
    my ($self, $value) = @_;
    return $self->header('content-type') if @_ == 1;
    if (defined $value) {
        croak 'Content-Type must be a scalar' if ref $value;
        $self->{_headers}->set('Content-Type', $value);
    } else {
        $self->{_headers}->remove('content-type');
    }
    return $self;
}

sub has_content_type { $_[0]->has_header('content-type') }

sub content_type_try {
    my ($self, $value) = @_;
    return $self if $self->has_content_type;
    return $self->content_type($value);
}

sub cookie {
    my ($self, $name, $value, %options) = @_;
    my %cookie = (value => $value, path => $options{path} // '/');
    $cookie{domain}    = $options{domain}  if defined $options{domain};
    $cookie{expires}   = $options{expires} if defined $options{expires};
    $cookie{'max-age'} = $options{max_age} if defined $options{max_age};
    $cookie{secure}    = $options{secure} if $options{secure};
    $cookie{httponly}  = $options{httponly} if $options{httponly};
    $cookie{samesite}  = $options{samesite} if defined $options{samesite};
    return $self->header('Set-Cookie', Cookie::Baker::bake_cookie($name, \%cookie));
}

sub delete_cookie {
    my ($self, $name, %options) = @_;
    return $self->cookie($name, '', %options, max_age => 0, expires => 0);
}

sub is_buffered { 1 }

sub body {
    my ($self) = @_;
    my $body = $self->{_body};
    return $body;
}

sub _snapshot {
    my ($self) = @_;
    my %copy = (
        _body    => $self->{_body},
        _headers => $self->{_headers}->clone,
    );
    $copy{_status} = $self->{_status} if $self->has_status;
    return bless \%copy, ref($self);
}

sub _wire_headers {
    my ($self, $length) = @_;
    my $headers = $self->{_headers}->to_pairs;
    @$headers = grep {
        my $name = $_->[0];
        $name =~ tr/A-Z/a-z/;
        $name ne 'content-length' && $name ne 'transfer-encoding';
    } @$headers;
    push @$headers, ['content-length', $length];
    return $headers;
}

async sub respond {
    my ($self, $scope, $receive, $send) = @_;
    _validate_http_triplet($scope, $receive, $send);
    my $snapshot = $self->_snapshot;
    my $body = $snapshot->{_body};
    await $send->({
        type    => 'http.response.start',
        status  => $snapshot->status,
        headers => $snapshot->_wire_headers(length $body),
    });
    await $send->({ type => 'http.response.body', body => $body, more => 0 });
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

sub _parse_options {
    croak 'response options must be name/value pairs' if @_ % 2;
    my %options;
    while (@_) {
        my ($name, $value) = splice @_, 0, 2;
        croak 'response option names must be scalar strings'
            unless defined $name && !ref($name) && length $name;
        croak "Unknown response option '$name'"
            unless $KNOWN_OPTIONS{$name};
        croak "Duplicate response option '$name'"
            if exists $options{$name};
        $options{$name} = $value;
    }
    return \%options;
}

sub _require_bytes {
    my ($name, $value) = @_;
    croak "$name must be a defined unblessed scalar of encoded bytes"
        unless defined $value && !ref($value) && !utf8::is_utf8($value);
    return;
}

sub _validate_status {
    my ($code) = @_;
    croak 'Status must be a number between 100-599'
        unless defined $code && !ref($code) && $code =~ /\A\d+\z/ && $code >= 100 && $code <= 599;
    return;
}

sub _status_forbids_body {
    my ($status) = @_;
    return $status >= 100 && $status < 200 || $status == 204 || $status == 205 || $status == 304;
}

sub _allows_body_forbidden_status { 0 }

sub _validate_uri_reference {
    my ($label, $value) = @_;
    croak "$label must be a URI-reference scalar"
        unless defined($value) && !ref($value)
            && $value =~ /\A(?:[A-Za-z0-9\-._~!\$&'\(\)\*\+,;=:@\/?#\[\]]|%[0-9A-Fa-f]{2})*\z/;
    return $value;
}

sub _validate_http_triplet {
    my ($scope, $receive, $send) = @_;
    croak 'Response requires an unblessed HTTP scope hashref'
        unless ref($scope) eq 'HASH' && !blessed($scope);
    croak 'Response requires HTTP scope type'
        unless defined $scope->{type} && !ref($scope->{type}) && $scope->{type} eq 'http';
    croak 'Response receive must be a coderef' unless ref($receive) eq 'CODE';
    croak 'Response send must be a coderef' unless ref($send) eq 'CODE';
    return;
}

1;
