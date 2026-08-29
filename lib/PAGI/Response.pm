package PAGI::Response;

use strict;
use warnings;

use Carp qw(croak);
use Cookie::Baker ();
use Exporter qw(import);
use Future;
use Future::AsyncAwait;
use PAGI::Headers ();
use Scalar::Util qw(blessed);
use Socket ();

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

=head2 stream_response

    my $response = stream_response(
        sub {
            my ($writer) = @_;
            return $writer->write('encoded bytes');
        },
        content_type => 'application/octet-stream',
    );

Constructs a reusable L<PAGI::Response::Stream>. The callback receives a fresh
per-invocation L<PAGI::Response::Writer>; await every write Future to preserve
backpressure.

=head2 file_response

    my $response = file_response('/srv/reports/monthly.pdf');

Constructs a reusable L<PAGI::Response::File> for one trusted, already
selected filesystem path. Use L<PAGI::App::File> instead when an untrusted
request URL path must be resolved under a configured root.

=cut

my %KNOWN_OPTIONS = map { $_ => 1 } qw(status content_type headers);
my %DIRECT_PROTOCOL_RESPONSE = map { $_ => 1 } qw(
    PAGI::Response
    PAGI::Response::Text
    PAGI::Response::HTML
    PAGI::Response::JSON
    PAGI::Response::Problem
    PAGI::Response::Redirect
    PAGI::Response::Empty
    PAGI::Response::Stream
);

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
        unless defined($value) && !ref($value) && _is_uri_reference($value);
    return $value;
}

sub _is_uri_reference {
    my ($reference) = @_;
    my $fragment_at = index($reference, '#');
    my $before_fragment = $fragment_at >= 0
        ? substr($reference, 0, $fragment_at) : $reference;
    my $fragment = $fragment_at >= 0 ? substr($reference, $fragment_at + 1) : undef;
    return 0 if defined($fragment) && index($fragment, '#') >= 0;
    return 0 if defined($fragment) && !_valid_query_or_fragment($fragment);

    my $query_at = index($before_fragment, '?');
    my $hier_part = $query_at >= 0
        ? substr($before_fragment, 0, $query_at) : $before_fragment;
    my $query = $query_at >= 0 ? substr($before_fragment, $query_at + 1) : undef;
    return 0 if defined($query) && !_valid_query_or_fragment($query);

    if ($hier_part =~ /\A[A-Za-z][A-Za-z0-9+.-]*:(.*)\z/) {
        return _valid_hier_part($1);
    }
    return _valid_relative_part($hier_part);
}

sub _valid_hier_part {
    my ($part) = @_;
    return _valid_authority_and_path(substr($part, 2)) if $part =~ /\A\/\//;
    return _valid_path($part);
}

sub _valid_relative_part {
    my ($part) = @_;
    return _valid_authority_and_path(substr($part, 2)) if $part =~ /\A\/\//;
    return 1 unless length $part;
    return _valid_path($part) if $part =~ /\A\//;
    my ($first_segment) = split /\//, $part, 2;
    return 0 if index($first_segment, ':') >= 0;
    return _valid_path($part);
}

sub _valid_authority_and_path {
    my ($authority_and_path) = @_;
    my $slash = index($authority_and_path, '/');
    my ($authority, $path) = $slash >= 0
        ? (substr($authority_and_path, 0, $slash), substr($authority_and_path, $slash))
        : ($authority_and_path, '');
    return _valid_authority($authority) && _valid_path($path);
}

sub _valid_authority {
    my ($authority) = @_;
    my ($userinfo, $host_port);
    if ($authority =~ /\A(.*)@(.*)\z/) {
        ($userinfo, $host_port) = ($1, $2);
        return 0 unless _valid_pchar_component($userinfo);
    } else {
        $host_port = $authority;
    }

    if ($host_port =~ /\A\[([^\]]+)\](?::([0-9]*))?\z/) {
        return _valid_ip_literal($1);
    }
    return 0 if $host_port =~ /[\[\]]/;

    my ($host, $port) = ($host_port, undef);
    if (index($host_port, ':') >= 0) {
        return 0 unless $host_port =~ /\A([^:]*):([0-9]*)\z/;
        ($host, $port) = ($1, $2);
    }
    return 0 unless length($host) || (!defined($userinfo) && !defined($port));
    return _valid_reg_name($host);
}

sub _valid_ip_literal {
    my ($literal) = @_;
    return 1 if $literal =~ /\Av[0-9A-Fa-f]+\.(?:[A-Za-z0-9\-._~!\$&'\(\)\*\+,;=:])+\z/;
    return defined Socket::inet_pton(Socket::AF_INET6(), $literal) ? 1 : 0;
}

sub _valid_path {
    my ($value) = @_;
    return $value =~ /\A(?:[A-Za-z0-9\-._~!\$&'\(\)\*\+,;=:@\/]|%[0-9A-Fa-f]{2})*\z/;
}

sub _valid_query_or_fragment {
    my ($value) = @_;
    return $value =~ /\A(?:[A-Za-z0-9\-._~!\$&'\(\)\*\+,;=:@\/?]|%[0-9A-Fa-f]{2})*\z/;
}

sub _valid_pchar_component {
    my ($value) = @_;
    return $value =~ /\A(?:[A-Za-z0-9\-._~!\$&'\(\)\*\+,;=:@]|%[0-9A-Fa-f]{2})*\z/;
}

sub _valid_reg_name {
    my ($value) = @_;
    return $value =~ /\A(?:[A-Za-z0-9\-._~!\$&'\(\)\*\+,;=]|%[0-9A-Fa-f]{2})*\z/;
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

# Private bridge used by protocol handshake denials. It deliberately keeps the
# complete Response triplet intact: only the top-level scope type/method and
# emitted event type are adapted. The mapped send Future remains server-owned.
sub _validate_protocol_response {
    my ($response, $operation) = @_;
    $operation //= 'Protocol response';
    croak "$operation requires exactly one concrete PAGI::Response"
        unless blessed($response) && $response->isa('PAGI::Response');
    croak "$operation does not support PAGI::Response::File"
        if $response->isa('PAGI::Response::File');
    return;
}

async sub _respond_for_protocol {
    my ($response, $scope, $receive, $send, $prefix, $operation) = @_;
    _validate_protocol_response($response, $operation);
    croak "$operation requires a protocol scope hashref"
        unless ref($scope) eq 'HASH' && !blessed($scope);
    croak "$operation receive must be a coderef" unless ref($receive) eq 'CODE';
    croak "$operation send must be a coderef" unless ref($send) eq 'CODE';
    croak "$operation requires a protocol response prefix"
        unless defined($prefix) && !ref($prefix) && length($prefix);

    my %http_scope = (
        %$scope,
        type   => 'http',
        method => 'GET',
    );
    my $emission_state = 'initial';

    my $map_event = sub {
        my ($event) = @_;
        croak "$operation Response events must be unblessed hashrefs"
            unless @_ == 1 && ref($event) eq 'HASH' && !blessed($event);

        my $type = $event->{type} // '';
        croak "$operation cannot adapt opaque file/fh response bodies"
            if exists($event->{file}) || exists($event->{fh});

        my %mapped = %$event;
        if ($type eq 'http.response.start') {
            croak "$operation cannot adapt responses that declare trailers"
                if exists $event->{trailers};
            croak "$operation received duplicate or out-of-order response start"
                unless $emission_state eq 'initial';
            $mapped{type} = "$prefix.start";
            $emission_state = 'body';
        }
        elsif ($type eq 'http.response.body') {
            croak "$operation received response body before response start"
                unless $emission_state eq 'body';
            $mapped{type} = "$prefix.body";
            $emission_state = 'complete' unless $event->{more};
        }
        else {
            croak "$operation cannot adapt unknown HTTP response event '$type'";
        }

        return \%mapped;
    };

    my $mapped_send = async sub {
        my ($event) = @_;
        my $mapped = $map_event->($event);

        await Future->wrap($send->($mapped))->without_cancel;
        return;
    };

    if ($DIRECT_PROTOCOL_RESPONSE{ref $response}) {
        await Future->wrap(
            $response->respond(\%http_scope, $receive, $mapped_send),
        );
    }
    else {
        # An arbitrary Response subclass may emit its own event sequence. Fully
        # validate that finite sequence before replay so a late opaque/trailer/
        # unknown event cannot leave a partially started protocol response.
        my @mapped_events;
        my $validate_send = sub {
            my ($event) = @_;
            push @mapped_events, $map_event->($event);
            return Future->done;
        };
        await Future->wrap(
            $response->respond(\%http_scope, $receive, $validate_send),
        );
        croak "$operation Response did not emit response start"
            if $emission_state eq 'initial';
        croak "$operation Response did not emit a terminal response body"
            unless $emission_state eq 'complete';
        for my $event (@mapped_events) {
            await Future->wrap($send->($event))->without_cancel;
        }
    }

    croak "$operation Response did not emit response start"
        if $emission_state eq 'initial';
    croak "$operation Response did not emit a terminal response body"
        unless $emission_state eq 'complete';
    return;
}

1;
