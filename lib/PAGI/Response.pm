package PAGI::Response;

use strict;
use warnings;

use Carp qw(croak);
use Cookie::Baker ();
use Exporter qw(import);
use Future;
use Future::AsyncAwait;
use PAGI::Headers ();
use PAGI::Utils qw(request_ended_abnormally);
use Scalar::Util qw(blessed);
use Socket ();

=encoding UTF-8

=head1 NAME

PAGI::Response - reusable HTTP response values and response factories

=head1 CLASS MODEL

Every response is a complete value. Its concrete class identifies its
representation or delivery behavior:

    Class                             Factory
    --------------------------------  -----------------
    PAGI::Response                    response
    PAGI::Response::Text              text_response
    PAGI::Response::HTML              html_response
    PAGI::Response::JSON              json_response
    PAGI::Response::Problem           problem_response
    PAGI::Response::Redirect          redirect_response
    PAGI::Response::Empty             empty_response
    PAGI::Response::File              file_response
    PAGI::Response::Stream            stream_response

Use either explicit class construction or the matching optional export:

    use PAGI::Response qw(json_response);
    use PAGI::Response::JSON ();
    my $one = PAGI::Response::JSON->new({ ok => \1 });
    my $two = json_response({ ok => \1 });

C<PAGI::Response> exports nothing by default. C<:all> exports all nine
factories. Each concrete subclass may export only its own factory. Factory
functions have fixed class mappings; they do not inspect the caller or choose
an application subclass.

=head1 MEMORY AND DELIVERY

The base, Text, HTML, JSON, Problem, Redirect, and Empty classes hold their
complete encoded bytes in memory. JSON and Problem serialize one finite Perl
value; they do not turn iterators into incremental JSON. File keeps a selected
path and sends a PAGI C<file> event after request-time preflight. Stream runs a
fresh producer per invocation and awaits each body send. Choose File or Stream
explicitly when the complete body should not be buffered.

The base class accepts one defined, unblessed, unflagged byte scalar and never
guesses an encoding. Unicode belongs to Text or HTML; structured data belongs
to JSON or Problem. For another charset, encode explicitly and provide the
matching Content-Type.

=head1 SYNOPSIS

    use Encode qw(encode);
    use PAGI::Response qw(response json_response);
    use PAGI::Utils qw(invoke_app);

    my $json = json_response(
        { created => \1 },
        status  => 201,
        headers => ['X-Request-ID' => $request_id],
    );

    my $latin1 = response(
        encode('ISO-8859-1', $text),
        content_type => 'text/plain; charset=iso-8859-1',
    );

    await invoke_app($json, $scope, $receive, $send);

=head1 VALUE AND APPLICATION BOUNDARIES

A Response stores no request scope, receive/send callbacks, connection,
Writer, or per-request mutation. An unchanged value can be emitted
concurrently. Header mutation before emission is supported, but mutating a
Response concurrently with emission is not. C<to_app> retains the exact
Response object. Each invocation derives its own plain delivery values before
response start, so deliberate mutation affects later invocations without
splitting an invocation already in progress.

A Response is not a terminal deployed root. C<to_app> produces one HTTP-only
native application. Place the Response at a Route when a routing root needs
L<PAGI::Compose> lifespan, HEAD suppression, ErrorHandler, and incomplete-
response policy; Compose itself accepts only structural C<routes>, not a
Response. Invoking a Response app with WebSocket, SSE, lifespan, or another
non-HTTP scope croaks before sending. That is an application failure, not a
guaranteed denial wire response. Use L<PAGI::WebSocket/deny> or
L<PAGI::SSE/decline> for controlled pre-start protocol rejection.

=head1 METHODS

=head2 new

    PAGI::Response->new($bytes, %options)

Creates a complete buffered response.  The supported options are C<status>,
C<content_type>, and C<headers>, where C<headers> is an even-length flat
arrayref of name/value pairs. Unknown, duplicate, odd, or malformed options
croak synchronously. Status defaults to 200 and body-bearing construction
rejects 1xx, 204, 205, and 304. Default Content-Type is
C<application/octet-stream>.

=head2 to_app

Returns an async HTTP application coderef retaining this exact Response.
Deliberate later mutation affects later invocations. Concurrent mutation while
an invocation derives its delivery values is unsupported.

At a native triplet boundary, use L<PAGI::Utils/invoke_app> to invoke this or
any other application value. Every send Future is awaited. Preflight errors
occur before start where possible; a genuine failed send Future propagates,
and failure after start never sends a replacement response. There is no public
Response-specific emission method.

=head2 metadata

    status / has_status / status_try
    headers / header / header_all / has_header / header_try / remove_header
    content_type / has_content_type / content_type_try
    cookie / delete_cookie
    is_buffered / body

C<header($name, $value)> appends and preserves repeated-field order;
C<content_type> replaces Content-Type. The C<*_try> setters are chainable and
do not overwrite an explicit value. C<body> is read-only encoded bytes for
buffered responses and croaks for File and Stream. C<is_buffered> reports the
memory strategy, independently of protocol adaptation.

=head2 protocol_response_capability

    my $capability = $response->protocol_response_capability;

Returns the inheritable versioned token C<body-events-v1>. It promises that
C<to_app> emits one C<http.response.start> followed only by ordinary byte
C<http.response.body> events: no trailers and no opaque C<file> or C<fh> body.
The token describes event vocabulary, not memory strategy;
L<PAGI::Response::Stream> inherits it while retaining incremental emission and
real send-Future backpressure. A subclass that introduces another delivery
form must override this method and return C<undef> unless a later specification
defines a matching capability.

L<PAGI::Response::File> returns C<undef>. PAGI Www denial bodies permit only
the body form and do not use C<file> or C<fh>; see
L<PAGI::Spec::Www/"WebSocket Denial Response (extension)"> and
L<PAGI::Spec::Www/"Decline SSE - send event">.

=head1 SUBCLASSING

Buffered application subclasses have two supported extension seams.

Override C<render($value)> when the subclass introduces a different encoding
or representation. It must return encoded bytes. Override
C<default_content_type> when that representation has a different media type:

    package MyApp::CSVResponse;
    use parent 'PAGI::Response';

    sub default_content_type { 'text/csv; charset=utf-8' }
    sub render {
        my ($self, $rows) = @_;
        return encode_rows_as_utf8($rows);
    }

Override C<new> when the subclass specializes the semantic input while
retaining an existing representation. Validate and normalize that input at
construction, then delegate the completed value and the untouched response
option list to C<SUPER::new>. For example, a company collection class can
inherit JSON encoding while constructing its standard envelope first:

    package MyCompany::CollectionResponse;
    use parent 'PAGI::Response::JSON';

    sub new {
        my ($class, $source, @response_options) = @_;
        die 'collection source must be a hashref'
            unless ref($source) eq 'HASH';
        die 'items must be an arrayref'
            unless ref($source->{items}) eq 'ARRAY';

        my $document = {
            data => $source->{items},
            meta => { count => scalar @{$source->{items}} },
        };

        return $class->SUPER::new($document, @response_options);
    }

Keeping C<@response_options> as a list lets the base constructor retain its
unknown-, duplicate-, and malformed-option checks. Application subclasses
must not call private Response parsing or emission methods. See
L<PAGI::Tools::Cookbook/Company Collection JSON Response> for a complete
factory and Route example.

Constructor dispatch through C<SUPER::new> preserves subclass identity. A
class may combine construction-time normalization with a new C<render> method
when it genuinely owns both concerns, but validation and document assembly
should not be hidden inside an encoder.

Delivery internals used by File and Stream are not a public subclass seam. A
delivery subclass that emits something outside ordinary body events must override
C<protocol_response_capability> and opt out unless a matching future token is
defined.

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

=head1 TEST RESPONSES ARE DIFFERENT VALUES

L<PAGI::Test::Response> is a captured-wire decoder returned by the test
client. It reconstructs status, headers, buffered body bytes, text, and JSON
from events, including C<file> and C<fh> events. It is not this production
Response value and cannot be returned from a handler or invoked as a production
application.

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

sub protocol_response_capability { return 'body-events-v1' }

sub body {
    my ($self) = @_;
    my $body = $self->{_body};
    return $body;
}

sub _emission_plan {
    my ($self) = @_;
    my $body = $self->body;
    return {
        body    => $body,
        status  => $self->status,
        headers => $self->_wire_headers(length $body),
    };
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

async sub _emit {
    my ($self, $scope, $receive, $send) = @_;
    _validate_http_triplet($scope, $receive, $send);
    my $plan = $self->_emission_plan;
    await $send->({
        type    => 'http.response.start',
        status  => $plan->{status},
        headers => $plan->{headers},
    });
    await $send->({
        type => 'http.response.body', body => $plan->{body}, more => 0,
    });
    return;
}

sub to_app {
    my ($self) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        await $self->_emit($scope, $receive, $send);
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

# Insert one already-raw query string before the target's first fragment.
# Validation policy belongs to the caller because middleware and Pages obtain
# their target/query data through different trust boundaries.
sub _location_with_raw_query {
    my ($target, $query) = @_;
    return $target unless defined($query) && !ref($query) && length($query);

    my $fragment = '';
    my $fragment_at = index($target, '#');
    if ($fragment_at >= 0) {
        $fragment = substr($target, $fragment_at);
        $target = substr($target, 0, $fragment_at);
    }

    if (index($target, '?') < 0) {
        $target .= '?';
    }
    elsif (!(substr($target, -1, 1) eq '?'
            && index($target, '?') == length($target) - 1)) {
        $target .= '&';
    }
    return $target . $query . $fragment;
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
    my $capability = $response->protocol_response_capability;
    croak "$operation cannot adapt " . ref($response)
        . " without the body-events-v1 protocol response capability"
        unless defined($capability) && !ref($capability)
            && $capability eq 'body-events-v1';
    return;
}

async sub _respond_for_protocol {
    my ($response, $scope, $receive, $send, $prefix, $operation, $on_start_committed) = @_;
    _validate_protocol_response($response, $operation);
    croak "$operation requires a protocol scope hashref"
        unless ref($scope) eq 'HASH' && !blessed($scope);
    croak "$operation receive must be a coderef" unless ref($receive) eq 'CODE';
    croak "$operation send must be a coderef" unless ref($send) eq 'CODE';
    croak "$operation requires a protocol response prefix"
        unless defined($prefix) && !ref($prefix) && length($prefix);
    croak "$operation requires a start-commit callback"
        unless ref($on_start_committed) eq 'CODE';

    my %http_scope = (
        %$scope,
        type   => 'http',
        method => 'GET',
    );
    my $emission_state = 'initial';
    my $start_committed = 0;

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
        my $type = ref($event) eq 'HASH' ? ($event->{type} // '') : '';
        my $mapped = $map_event->($event);

        await Future->wrap($send->($mapped));
        if ($type eq 'http.response.start') {
            $start_committed = 1;
            $on_start_committed->();
        }
        return;
    };

    await Future->wrap(
        $response->_emit(\%http_scope, $receive, $mapped_send),
    );

    croak "$operation Response did not emit response start"
        if $emission_state eq 'initial';
    unless ($emission_state eq 'complete') {
        # Unreachable today: this path serves only WebSocket deny and SSE
        # decline, whose scopes carry no pagi.connection. It becomes live if
        # connection state is ever extended to those scope types, so it is
        # kept correct rather than deleted.
        croak "$operation Response did not emit a terminal response body"
            unless $start_committed && request_ended_abnormally(\%http_scope);
    }
    return;
}

1;
