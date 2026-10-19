package PAGI::Response;

use strict;
use warnings;

use Carp qw(croak);
use Cookie::Baker ();
use Exporter qw(import);
use Future;
use Future::AsyncAwait;
use PAGI::Headers ();
use PAGI::Utils ();
use Scalar::Util qw(blessed);
use Socket ();

=encoding UTF-8

=head1 NAME

PAGI::Response - reusable HTTP response values and response factories

=head1 CLASS MODEL

Every response is a complete value. Its concrete class identifies its
representation or delivery behavior:

    Class                             Built by name
    --------------------------------  ---------------------
    PAGI::Response                    (PAGI::Response->new)
    PAGI::Response::Text              response('Text', ...)
    PAGI::Response::HTML              response('HTML', ...)
    PAGI::Response::JSON              response('JSON', ...)
    PAGI::Response::Problem           response('Problem', ...)
    PAGI::Response::Redirect          response('Redirect', ...)
    PAGI::Response::Empty             response('Empty', ...)
    PAGI::Response::File              response('File', ...)
    PAGI::Response::Stream            response('Stream', ...)
    PAGI::Response::NDJSON            response('NDJSON', ...)

Construct a class directly, or build it by name with L</response>:

    use PAGI::Response qw(response);
    use PAGI::Response::JSON ();
    my $one = PAGI::Response::JSON->new({ ok => \1 });
    my $two = response('JSON', { ok => \1 });

C<PAGI::Response> exports nothing by default; C<response> is its only export,
on request or through C<:all>. The Response subclasses export nothing.
C<response> resolves a name the way C<middleware()> and C<session_store()>
resolve theirs, so a Response class from another distribution is built the
same way, with a leading C<+>.

=head1 MEMORY AND DELIVERY

The base, Text, HTML, JSON, Problem, Redirect, and Empty classes hold their
complete encoded bytes in memory. JSON and Problem serialize one finite Perl
value; they do not turn iterators into incremental JSON. NDJSON streams one
encoded value per awaited write through its specialized Writer; it does not
buffer a whole sequence. File keeps a selected path and sends a PAGI C<file>
event after request-time preflight. Stream runs a fresh producer per invocation
and awaits each body send. Choose File or Stream explicitly when the complete
body should not be buffered.

The base class accepts one defined, unblessed, unflagged byte scalar and never
guesses an encoding. Unicode belongs to Text or HTML; structured data belongs
to JSON or Problem. Use L<PAGI::Response::NDJSON> for a JSON-value stream. For
another charset, encode explicitly and provide the matching Content-Type.

=head1 SYNOPSIS

    use Encode qw(encode);
    use PAGI::Response qw(response);
    use PAGI::Utils qw(invoke_app);

    my $json = response('JSON',
        { created => \1 },
        status  => 201,
        headers => ['X-Request-ID' => $request_id],
    );

    my $latin1 = PAGI::Response->new(
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

A Response is not a terminal deployed root. C<to_app> produces a native
application that emits ordinary HTTP response events. It accepts HTTP scopes
and can emit a preaccept WebSocket refusal or prestart SSE refusal on the
original protocol scope. Use L<PAGI::WebSocket/deny> or L<PAGI::SSE/decline>
to validate refusal admission and invoke the Response on those original
protocol channels.

Place the Response at a Route when a routing root needs L<PAGI::Compose>
lifespan, HEAD suppression, ErrorHandler, and incomplete-response policy;
Compose itself accepts only structural C<routes>, not a Response. Invoking a
Response app with lifespan or an unsupported scope type croaks before sending.
That is an application failure, not a guaranteed denial wire response.

A L<PAGI::Pages> refusal stays an ordinary application value at every supported
boundary. Pass it directly to the protocol owner:

    use Future::AsyncAwait;
    use PAGI::Auth qw(www_authenticate);
    use PAGI::Pages;

    my $failure = PAGI::Pages->status(
        401,
        as      => 'json',
        headers => [
            'WWW-Authenticate' =>
                www_authenticate('Bearer', realm => 'private'),
        ],
    );

    async sub denied_socket {
        my ($ws) = @_;
        await $ws->deny($failure);
        return;
    }

C<response_for> creates only fresh local Response state; it performs no send or
receive, and remains available when code intentionally needs a concrete
Response. L<PAGI::Utils/invoke_app>, L<PAGI::WebSocket/deny>, and
L<PAGI::SSE/decline> convert application values through their public C<to_app>
contract and invoke them with the original scope, receive, and send channels.
The protocol helpers validate admission and prevent their streaming protocol
from starting after the response slot is claimed. The invoked application owns
response emission, while connection terminal notification independently drives
helper cleanup. A mapped start send resolves when the server accepts and owns
the response slot (or finishes discarding it after disconnect), not when the
client receives bytes.

=head1 VALUES FROM OTHER CODE

Wherever a response takes a string, such as a body, it also takes a blessed
object whose class overloads stringification (C<""> directly, or through a
parent class), such as L<URI>, L<Path::Tiny>, L<DateTime> or an exception
object. The overload is called once and its string is used.

Every other value that is not a plain string croaks: an unblessed
reference, an object that does not overload C<"">, an object that overloads
only numeric or boolean conversion (Perl would otherwise invent a string
such as C<42> or C<1> for it), and an object whose C<""> returns undef. An
exception thrown by the object's own C<""> propagates unchanged.

JSON data is not stringified: L<PAGI::Response::JSON> and
L<PAGI::Response::NDJSON> encode their data as JSON, and their encoder
refuses every blessed object.

=head1 BYTES AND CHARACTERS

A byte API (C<new>, a Stream writer's C<write>, an explicit File C<etag>)
takes bytes: a string whose characters are all at most 0xFF. Perl's internal
UTF-8 flag only records how a string is stored, so it does not matter: a
string Perl happens to have flagged, such as ASCII from C<Encode::decode> or
built with a decoded string, is accepted, and is sent as plain bytes. A
character above 0xFF cannot be a byte and croaks, naming the fix.

Two mistakes look alike and cannot be told apart at runtime, so they are
documented instead:

=over 4

=item * Text through a byte API. Decoded text whose characters are all at
most 0xFF is sent as one byte per character, which is ISO-8859-1, not UTF-8:
C<"caf\x{e9}"> goes out as C<63 61 66 E9>. Send text with
L<PAGI::Response::Text> or L<PAGI::Response::HTML>, which encode it as UTF-8,
or encode it yourself.

=item * Bytes through a text API. Already-encoded bytes given to Text or HTML
are encoded again.

=back

=head1 METHODS

=head2 response

    use PAGI::Response qw(response);

    my $text  = response('Text', 'Hello');
    my $json  = response('JSON', { ok => \1 }, status => 201);
    my $mine  = response('+MyApp::Response::XML', $document);

Builds a Response by class name. A short name is resolved under
C<PAGI::Response::> (C<'JSON'> is L<PAGI::Response::JSON>), a name already
under that namespace is kept, and a leading C<+> names an exact package, so a
Response class from another distribution needs no change here. A class
already defined -- declared in the application file, or loaded before -- is
used as it is; otherwise its file is loaded, and a name with no file, or a
file that fails to load, dies C<response('...'): cannot load ...>. The class
must be a C<PAGI::Response>, and is constructed with the remaining arguments
unchanged; each class documents its own arguments.

Dies with C<response('NAME'): cannot load CLASS: ...> when the class cannot
be loaded -- including a name whose case differs from the file's, which a
case-insensitive filesystem would otherwise load under the wrong package --
and C<response('NAME'): CLASS is not a PAGI::Response> for a helper such as
L<PAGI::Response::Writer>. The base byte response is
C<< PAGI::Response->new($bytes, %options) >>.

=head2 new

    PAGI::Response->new($bytes, %options)
    PAGI::Response->new                    # the empty value, for staging

Creates a complete buffered response. C<$bytes> is a string of encoded bytes
(L</BYTES AND CHARACTERS>), or an object that stringifies to one
(L</VALUES FROM OTHER CODE>); C<undef>, or no content at all, is an empty
body. The
supported options are C<status>,
C<content_type>, and C<headers>, where C<headers> is a flat
C<[name =E<gt> value, ...]> list, C<[[name, value], ...]> pairs as the PAGI
spec writes headers, or a L<PAGI::Headers> object (copied; later changes to
it do not reach the response), whose values follow C<header> (L</metadata>). Every
C<headers> argument in PAGI-Tools takes these three shapes.
Unknown, duplicate, odd, or malformed options
croak synchronously. Status defaults to 200. Default Content-Type is
C<application/octet-stream>, written only when the body has bytes: an empty
body has no Content-Type unless one is given, as in Starlette's base
C<Response>.

A status whose HTTP semantics forbid content (1xx, 204, 205, 304) takes an
empty body, in this class and in every buffered class built on it (Text,
HTML, Problem, Redirect): C<< response('Text', '', status => 204) >> is a
204. A body with bytes on such a status croaks ("response body is forbidden
for status N"), at construction or when C<status> is set later; so does JSON,
whose C<undef> renders as C<null>, and so do Stream, NDJSON and File, which
always have a body to deliver. L<PAGI::Response::Empty> remains the class for
a response that must never carry a Content-Type.

On 1xx, 204 and 304 no Content-Length is sent (205 keeps its
C<Content-Length: 0>), and the class's default Content-Type is not written:
unlike Starlette, which adds its media type whatever the status. That is
decided when the value is built: C<< response('Text', '')->status(204) >>
keeps the C<text/plain; charset=utf-8> it was built with. A Content-Type the
caller gives is sent.

C<< PAGI::Response->new >> with no arguments is the empty value: no explicit
status (C<has_status> is false), no Content-Type, an empty body. As an
application it sends 200 with an empty body and no Content-Type. A framework
can stage C<status>, C<header> and C<cookie> on it before it knows the
final class, then build the class named C<$name> with what was staged:

    response($name // '+PAGI::Response', $body,
        ($staged->has_status ? (status => $staged->status) : ()),
        headers => $staged->headers);

How a staged value merges with the final one (which wins, which headers
add) is the framework's policy; PAGI-Tools adds none.

=head2 to_app

Returns an async HTTP application coderef retaining this exact Response.
Deliberate later mutation affects later invocations. Concurrent mutation while
an invocation derives its delivery values is unsupported.

At a native triplet boundary, use L<PAGI::Utils/invoke_app> to invoke this or
any other application value. Every send Future is awaited. Preflight errors
occur before start where possible; a genuine failed send Future propagates,
and failure after start never sends a replacement response. Cancelling a
buffered invocation stops further emission but does not cancel a send already
submitted to the server; it does not promise a transport abort. There is no
public Response-specific emission method.

=head2 metadata

    status / has_status / status_try
    headers / header / header_all / has_header / header_try / remove_header
    content_type / has_content_type / content_type_try
    cookie / delete_cookie
    is_buffered / body

C<header($name, $value)> appends and preserves repeated-field order;
C<content_type> replaces Content-Type, and C<content_type(undef)> gives back the
class's default type (Text's C<text/plain; charset=utf-8>, for one), so a typed
body always says what it is; Empty and File have none, File's coming from the
file name. However a Content-Type arrives -- the C<content_type> option, a
Content-Type pair in the C<headers> option, or C<header('Content-Type', ...)>
later -- it goes through the class's C<content_type>, so it replaces the one
already there and keeps the class's rule: Text and HTML add their charset,
Empty refuses one. Given both the option and a pair, the option wins. A
Content-Type added straight to the container returned by C<headers> bypasses
the rule. The C<*_try> setters are chainable and
do not overwrite an explicit value. C<body> is read-only encoded bytes for
buffered responses and croaks for File and Stream. C<is_buffered> reports the
memory strategy, independently of protocol adaptation.

Header values, the Content-Type, and a cookie's value, domain and path may be
objects that stringify (L</VALUES FROM OTHER CODE>); a cookie part that is
not a string croaks rather than being sent as C<HASH(0x...)>. That includes an
undef value: C<< cookie(name => undef) >> does not remove a cookie, and
C<delete_cookie> is what does. A header added
straight to the container returned by C<headers> is checked as the response
is sent: a value that is neither a string nor an object that stringifies
croaks then, naming the header, before anything is sent.

Header values and cookie parts are bytes (L</BYTES AND CHARACTERS>), as
HTTP field values are octets: a character above 0xFF croaks, naming the
header or cookie part, and text with one is encoded first (a non-ASCII
download name is: File encodes C<filename> itself, following RFC 8187).

Header names are HTTP tokens (RFC 9110): letters, digits and
C<!#$%&'*+-.^_`|~>. A name with anything else (a space, a colon, a
character above 0x7E) croaks, naming it; one added straight to the
container croaks as the response is sent.

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
class and Route example, built with C<response('+...')>.
See L<PAGI::Tools::Cookbook/"Streaming Response Formats"> for writing a
streaming format.

Constructor dispatch through C<SUPER::new> preserves subclass identity. A
class may combine construction-time normalization with a new C<render> method
when it genuinely owns both concerns, but validation and document assembly
should not be hidden inside an encoder.

Delivery internals used by File and Stream are not a public subclass seam.

=head1 STREAMING AND FILE RESPONSES

=head2 Stream

    my $response = response('Stream',
        sub {
            my ($writer) = @_;
            return $writer->write('encoded bytes');
        },
        content_type => 'application/octet-stream',
    );

Constructs a reusable L<PAGI::Response::Stream>. The callback receives a fresh
per-invocation L<PAGI::Response::Writer>; await every write Future to preserve
backpressure.

=head2 NDJSON

    my $response = response('NDJSON', async sub ($writer) {
        await $writer->write_item({ id => 1 });
    });

Constructs a reusable L<PAGI::Response::NDJSON>. Each C<write_item> sends one
value as UTF-8 JSON followed by one LF. Buffered C<response('JSON', ...)>
serializes one finite Perl value; it is not an incremental JSON sequence.

=head2 File

    my $response = response('File', '/srv/reports/monthly.pdf');

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
our @EXPORT_OK = qw(response);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

# Resolve NAME under PAGI::Response:: (or exactly, with a leading '+'), load
# it, and construct it with the remaining arguments, unchanged.
sub response {
    my ($name, @arguments) = @_;
    croak 'response() requires a Response class name'
        unless defined($name) && !ref($name) && length($name);
    require PAGI::Utils;
    my $class = PAGI::Utils::_resolve_class('PAGI::Response', $name, 'response');
    my $error = PAGI::Utils::_load_class($class, "response('$name')", sub { $_[0]->isa('PAGI::Response') });
    croak $error if defined $error;
    croak "response('$name'): $class is not a PAGI::Response"
        unless $class->isa('PAGI::Response');
    return $class->new(@arguments);
}

sub new {
    my ($class, $value, @pairs) = @_;
    my $options = _parse_options(@pairs);

    my $self = bless { _headers => PAGI::Headers->new }, $class;
    $self->{_body} = _require_bytes('response body', $self->render($value));

    $self->status($options->{status}) if exists $options->{status};
    if (exists $options->{headers}) {
        my ($pairs, $refused) = PAGI::Utils::_header_pairs('PAGI::Response', $options->{headers});
        croak $refused if $refused;
        $self->header(@$_) for @$pairs;
    }
    $self->content_type($options->{content_type})
        if exists $options->{content_type};
    $self->content_type_try($self->_body_default_content_type);
    return $self;
}

sub default_content_type { 'application/octet-stream' }
# No content is an empty body; subclasses with their own render keep their
# own meaning of undef (JSON's null, Text's refusal).
sub render { $_[1] // '' }

# The type a response says it is when nothing else was given: the class's
# default, except that the base class's application/octet-stream describes
# bytes, so an empty buffered body has none (as Starlette's base Response,
# whose media type is None).
sub _body_default_content_type {
    my ($self) = @_;
    my $default = $self->default_content_type;
    return undef if defined $self->{_status} && _status_forbids_body($self->{_status});
    return undef
        if defined $default && $default eq 'application/octet-stream'
        && $self->_has_empty_buffered_body;
    return $default;
}

# The body is buffered and renders to nothing. An unbuffered class (Stream,
# NDJSON, File) builds through an empty buffered constructor and then drops
# the body, so is_buffered, a class constant, keeps it out while it does.
sub _has_empty_buffered_body {
    my ($self) = @_;
    return $self->is_buffered && defined $self->{_body} && $self->{_body} eq '';
}

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
    if (defined(my $refused = PAGI::Utils::_header_name_refusal($name))) {
        croak $refused;
    }
    # A Content-Type set any way goes through the class's own content_type
    # rule (Text and HTML keep their charset, Empty refuses one), and
    # replaces rather than adds: a response has one type.
    return $self->content_type($value)
        if defined $value && lc($name) eq 'content-type';
    my ($bytes, $not) = PAGI::Utils::_sendable_header_value($value);
    croak 'Header value is required' if ($not // '') eq 'not a string';
    croak "header '$name' value contains a character above 0xFF: encode it first" if $not;
    $self->{_headers}->add($name, $bytes);
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
    # The caller's own undef removes the type; an object that gives undef
    # is not a type, and croaks.
    if (defined $value) {
        my ($bytes, $not) = PAGI::Utils::_sendable_header_value($value);
        croak 'Content-Type must be a scalar' if ($not // '') eq 'not a string';
        croak "header 'Content-Type' value contains a character above 0xFF: encode it first" if $not;
        $value = $bytes;
        $self->{_headers}->set('Content-Type', $value);
    } elsif (defined(my $default = $self->_body_default_content_type)) {
        # Clearing a typed body gives back its default, so it always says
        # what it is; a class with no default (Empty, File) sends none.
        $self->{_headers}->set('Content-Type', $default);
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
    # The name is an identifier, so it is not stringified; it is bytes.
    if (defined $name && !ref $name) {
        defined($name = PAGI::Utils::_byte_string($name))
            or croak 'cookie name contains a character above 0xFF: encode it first';
    }
    $value = _cookie_string('value', $value);
    for my $option (qw(domain path)) {
        $options{$option} = _cookie_string($option, $options{$option}) if defined $options{$option};
    }
    my %cookie = (value => $value, path => $options{path} // '/');
    $cookie{domain}    = $options{domain}  if defined $options{domain};
    $cookie{expires}   = $options{expires} if defined $options{expires};
    $cookie{'max-age'} = $options{max_age} if defined $options{max_age};
    $cookie{secure}    = $options{secure} if $options{secure};
    $cookie{httponly}  = $options{httponly} if $options{httponly};
    $cookie{samesite}  = $options{samesite} if defined $options{samesite};
    return $self->header('Set-Cookie', Cookie::Baker::bake_cookie($name, \%cookie));
}

# A cookie's value, domain or path as a string, or croak: Cookie::Baker
# would otherwise send a reference as HASH(0x...).
sub _cookie_string {
    my ($what, $value) = @_;
    $value = PAGI::Utils::_stringified($value);
    croak "cookie $what must be a string or an object that overloads stringification"
        unless defined $value && !ref($value);
    defined(my $bytes = PAGI::Utils::_byte_string($value))
        or croak "cookie $what contains a character above 0xFF: encode it first";
    return $bytes;
}

sub delete_cookie {
    my ($self, $name, %options) = @_;
    return $self->cookie($name, '', %options, max_age => 0, expires => 0);
}

sub is_buffered { 1 }

# A content type for a body sent as UTF-8 says so: one without a charset gets
# "; charset=utf-8". JSON is UTF-8 by definition and takes no charset.
sub _with_utf8_charset {
    my ($type) = @_;
    return $type if $type =~ /charset=/i;
    my ($media) = $type =~ m{\A\s*([^;\s]+)};
    return $type
        if defined $media && (lc($media) eq 'application/json' || $media =~ m{\+json\z}i);
    return "$type; charset=utf-8";
}

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

# The header pairs to send, each value a string. A value reaches the
# container unchecked through $response->headers, so an object that
# stringifies is sent as its string and any other non-string croaks here,
# naming the header, before anything is sent.
sub _sendable_header_pairs {
    my ($self) = @_;
    my ($pairs, $refused) = PAGI::Utils::_sendable_headers('PAGI::Response', $self->{_headers});
    croak $refused if $refused;
    return $pairs;
}

sub _wire_headers {
    my ($self, $length) = @_;
    my $headers = $self->_sendable_header_pairs;
    @$headers = grep {
        my $name = $_->[0];
        $name =~ tr/A-Z/a-z/;
        $name ne 'content-length' && $name ne 'transfer-encoding';
    } @$headers;
    # 1xx, 204 and 304 carry no Content-Length; 205 keeps its 0 (RFC 9110).
    my $status = $self->status;
    push @$headers, ['content-length', $length]
        unless $status >= 100 && $status < 200 || $status == 204 || $status == 304;
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
    })->without_cancel;
    await $send->({
        type => 'http.response.body', body => $plan->{body}, more => 0,
    })->without_cancel;
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

# The encoded bytes $value stands for, or croak naming it.
sub _require_bytes {
    my ($name, $value) = @_;
    $value = PAGI::Utils::_stringified($value);
    croak "$name must be a defined unblessed scalar of encoded bytes"
        unless defined $value && !ref($value);
    defined(my $bytes = PAGI::Utils::_byte_string($value))
        or croak "$name must be encoded bytes: it contains a character above 0xFF; encode text first, or use Text or HTML";
    return $bytes;
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

# A buffered response with an empty body may carry a no-body status; a body
# with bytes, or one still to be delivered (Stream, NDJSON, File), may not.
sub _allows_body_forbidden_status { $_[0]->_has_empty_buffered_body }

sub _validate_uri_reference {
    my ($label, $value) = @_;
    $value = PAGI::Utils::_stringified($value);
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
    croak 'Response requires an unblessed supported scope hashref'
        unless ref($scope) eq 'HASH' && !blessed($scope);
    croak 'Response requires supported scope type (http, websocket, or sse)'
        unless defined $scope->{type} && !ref($scope->{type})
            && $scope->{type} =~ /\A(?:http|websocket|sse)\z/;
    croak 'Response receive must be a coderef' unless ref($receive) eq 'CODE';
    croak 'Response send must be a coderef' unless ref($send) eq 'CODE';
    return;
}

1;
