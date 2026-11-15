package PAGI::Utils::_SendValidation;

use strict;
use warnings;
use namespace::autoclean;
use Carp qw(croak);
use Encode ();
use Scalar::Util ();

=head1 NAME

PAGI::Utils::_SendValidation - Private send-sequencing validation core

=head1 SYNOPSIS

    use PAGI::Utils::_SendValidation;

    my $sv = PAGI::Utils::_SendValidation->new(
        scope_type => 'http',
        extensions => { fullflush => 1 },
    );

    my $err = $sv->check({ type => 'http.response.start', status => 200 });
    die $err->message if $err;

    ...

    my $final_err = $sv->finalize;
    warn $final_err->message if $final_err;

=head1 DESCRIPTION

C<PAGI::Utils::_SendValidation> is a small, dependency-free, protocol-agnostic
send-sequencing validator for PAGI applications. It tracks the legal order
of events an application sends for one HTTP, WebSocket, SSE, or lifespan
scope and rejects events that arrive out of order, are unrecognized, or use
an extension the scope did not advertise.

This package and its nested C<::Error> class are private implementation
details. Application code must not depend on their names or interfaces; both
may change without a compatibility layer.

It is toolkit-internal infrastructure: it exists so every send path in
PAGI::Tools that needs to enforce the PAGI spec's send-sequencing rules
(currently L<PAGI::Test::Client> and the development Lint middleware) shares
one implementation instead of each reimplementing its own copy. Its rules
mirror the categories and intent of the reference server's
C<PAGI::Server::EventValidator> sequencing state machines, adapted to a
never-dies, single-object-per-scope interface.

It checks whether the event type is recognized for the scope, whether an
extension-gated type was advertised, whether the event's fields are what the
PAGI spec and RFC 9110 allow (see L</Fields>), and whether the event is legal
given what has already been sent. Fields are checked first, then the
sequence.

=head1 CONSTRUCTOR

=head2 new

    my $sv = PAGI::Utils::_SendValidation->new(
        scope_type => 'http' | 'websocket' | 'sse' | 'lifespan',
        extensions   => \%advertised,   # optional, default {}
        http_version => '1.1',          # optional: the scope's
        method       => 'GET',          # optional: the request's
    );

C<scope_type> is required and must be one of the four listed values;
anything else croaks. C<extensions> is an optional hash reference of
extension names the scope advertised (the same shape as the PAGI
C<extensions> scope key); omitted or false defaults to an empty hash
reference. C<http_version> is the scope's C<http_version>, when known: the
HTTP/1.x-only rules below (trailers after a Content-Length, and the body
count) apply only when it starts with C<1.>. C<method> is the request's
method, when known: a C<HEAD> response's body is not counted. Construction
is the only place this module croaks on ordinary
misuse -- it represents a caller bug (wiring the validator up wrong), not an
application-supplied event to reject.

=cut

my %INITIAL_STATE = (
    http      => 'initial',
    websocket => 'connecting',
    sse       => 'initial',
);

sub new {
    my ($class, %args) = @_;

    croak "PAGI::Utils::_SendValidation->new: 'scope_type' is required"
        unless defined $args{scope_type};
    croak "PAGI::Utils::_SendValidation->new: unknown scope_type '$args{scope_type}'"
        unless $args{scope_type} eq 'lifespan' || exists $INITIAL_STATE{$args{scope_type}};
    croak "PAGI::Utils::_SendValidation->new: 'extensions' must be a hash reference"
        if defined $args{extensions} && ref $args{extensions} ne 'HASH';

    return bless {
        scope_type        => $args{scope_type},
        extensions         => $args{extensions} || {},
        http_version       => $args{http_version},   # the scope's, when known
        method             => $args{method},         # the request's, when known
        state              => $INITIAL_STATE{$args{scope_type}}, # undef for lifespan
        trailers_declared  => 0,
        refusal_http_state => 'initial',
        refusal_trailers_declared => 0,
        phase              => 'startup', # lifespan only
        result_sent        => 0,         # lifespan only; reset by enter_phase
    }, $class;
}

=head1 METHODS

=head2 check

    my $err = $sv->check($event);

Validates C<$event> (a plain hash reference in PAGI wire form) against the
scope's send-sequencing rules. Returns C<undef> when the event is legal --
and, on that same success path, advances the validator's internal state so
the B<next> call to C<check> sees the new state. Returns a
L<PAGI::Utils::_SendValidation::Error> object when the event is illegal.

B<No-advance-on-error contract:> an illegal event never mutates internal
state. Calling C<check> again with the same or a different, legal event
behaves exactly as if the rejected call had never happened. C<check> never
C<die>s, regardless of what C<$event> is (including C<undef> or a
non-hash-reference value) -- every failure mode is reported as a returned
Error object, never an exception.

=head2 finalize

    my $err = $sv->finalize;

Returns C<undef> if the scope has reached a legal terminal state (nothing
more needs to be sent). Returns a L<PAGI::Utils::_SendValidation::Error> naming what
is still missing otherwise (for example, "awaiting a terminal body chunk"
or "awaiting declared http.response.trailers" for HTTP). Calling
C<finalize> does not itself change any state; it may be called at any
point, repeatedly, without side effects.

=head2 enter_phase

    $sv->enter_phase('startup' | 'shutdown');

Lifespan scopes only; croaks (a caller-bug guard, not an application-event
rejection) if called on a non-lifespan scope or with any other phase name.
Declares which lifespan phase the application is currently expected to
report a result for. This is driven externally by whatever is running the
lifespan protocol (it advances when the server delivers the shutdown
event to the app), not by C<check> itself -- C<check> only validates that
C<lifespan.startup.*>/C<lifespan.shutdown.*> results arrive while their
matching phase is current. The validator starts in the C<startup> phase.

=cut

sub enter_phase {
    my ($self, $phase) = @_;

    croak "PAGI::Utils::_SendValidation->enter_phase: only valid for scope_type 'lifespan'"
        unless $self->{scope_type} eq 'lifespan';
    croak "PAGI::Utils::_SendValidation->enter_phase: unknown phase '" . (defined $phase ? $phase : 'undef') . "'"
        unless defined $phase && ($phase eq 'startup' || $phase eq 'shutdown');

    $self->{phase}       = $phase;
    $self->{result_sent} = 0;
    return;
}

=head2 started

    my $bool = $sv->started;

True once at least one legal event has been accepted by C<check> (i.e. the
scope has moved off its initial state). Always false for a fresh validator
and for C<scope_type =E<gt> 'lifespan'> (lifespan has no "started" concept
distinct from its phase).

=head2 complete

    my $bool = $sv->complete;

True once the scope has reached the fully-sent terminal state for its
protocol: HTTP -- body terminal and any declared trailers sent; WebSocket --
C<websocket.close> sent after acceptance, or an HTTP refusal completed; SSE --
C<sse.close> sent, or an HTTP refusal completed. Always false for
C<scope_type =E<gt> 'lifespan'>.

=head2 closed

    my $bool = $sv->closed;

True for WebSocket and SSE scopes once C<close> has reached their protocol's
C<closed> state (WebSocket: C<websocket.close> sent; SSE: C<sse.close> sent).
An HTTP refusal completes its scope without setting C<closed>. Always false
for HTTP and lifespan scopes, which have no
"closed" concept distinct from C<complete>.

=head2 trailers_declared

    my $bool = $sv->trailers_declared;

True once an HTTP C<http.response.start> event declaring C<trailers =E<gt>
1> has been sent. Always false before that, and always false for non-HTTP
scopes.

=cut

=head1 RULES

The enforced rules: the fields every scope checks first, then the send
sequence, one per scope type. These are what C<check> and C<finalize>
actually enforce; read this section rather than the implementation to know
what is legal to send.

=head2 Fields

Checked before the sequence; a failure is C<malformed>. Every C<headers>
list (on C<http.response.start>, C<http.response.trailers>,
C<websocket.accept> and C<sse.start>) is an array of name/value pairs of
defined strings, each name an RFC 9110 token (S5.1) and each value an RFC
9110 field value (S5.5). The message names the event, the header's index
and its escaped name, and never the value:
C<http.response.start header 1 ('x-v'): value contains CR (\x0d) at offset 1>.

A C<status>, required on C<http.response.start> and optional on
C<sse.start>, is three digits from 200 to 599. An C<http.response.start>
carries at most one C<content-length>, compared case-insensitively, holding
one decimal number. The other fields have the types the PAGI spec gives
them: C<trailers> and C<more> 0 or 1; at most one of C<body>/C<file>/C<fh>,
with C<offset> and C<length> non-negative integers; C<websocket.send> exactly
one of C<bytes>/C<text>; a C<websocket.close> C<reason> at most 123 bytes as
UTF-8; a keepalive's C<interval> a non-negative number; C<sse.send>'s
C<data> a string and its C<event> and C<id> without newlines; and so on. A
WebSocket refusal's status is 300 or above (a C<sequence> failure).

Over HTTP/1.x (C<http_version>), a response that declares a
C<content-length> is counted: a body send that would go past it, or a
terminal one that leaves bytes owing, fails (C<sequence>) and changes
nothing, so the right bytes may still be sent. A C<file> counts its
C<length>, or its size less its C<offset>; an C<fh> counts its C<length>,
and one without a C<length> is not counted. HEAD (C<method>), 204 and 304
are not counted. Refusals are counted like any response.

=head2 http

States: C<initial>, C<started>, C<started_t> (trailers declared),
C<awaiting_trailers>, C<complete>. Starting state is C<initial>.

Illegal: an unrecognized event type; an event with no C<type>; a duplicate
C<http.response.start>; C<http.response.body> before C<http.response.start>;
a body chunk after the body is already terminal (C<more =E<gt> 1> is what
keeps it non-terminal -- C<more> absent, false, or a C<file>/C<fh> body all
count as terminal); C<http.response.trailers> without
C<trailers =E<gt> 1> declared on start, or before the body has reached its
terminal chunk; any event at all once trailers have been sent;
C<http.fullflush> when C<fullflush> is not in the scope's C<extensions>, or
when sent before C<http.response.start> or once C<complete>; a body that
isn't bytes -- a plain reference, or a string with a character above 0xFF
(both C<malformed>; PAGI::Server refuses the second); over HTTP/1.x
(C<http_version>), C<http.response.trailers> on a response whose start
declared a C<Content-Length>, since trailers there need chunked coding
(C<sequence>, as PAGI::Server refuses it).

C<http.fullflush>, when the C<fullflush> extension is declared, is legal in
any non-C<initial>, non-C<complete> state -- including C<awaiting_trailers>
-- and never changes the state.

Legal terminal state for C<finalize>: C<complete>.

=head2 websocket

States: C<connecting>, C<accepted>, C<refusing>, C<refusal_complete>,
C<closed>. Starting state is C<connecting>.

Illegal: C<websocket.send>, C<websocket.keepalive>, or C<websocket.close>
before C<websocket.accept>; any event once C<websocket.close> has been sent
(including a second close -- close is not idempotent here); a second
C<websocket.accept> once already accepted; an HTTP response event after
C<websocket.accept>; any WebSocket event once an HTTP refusal has started;
or any event once the refusal is complete. The removed
C<websocket.http.response.*> names are unrecognized event types.

Legal: before C<websocket.accept>, C<http.response.start> with a status of
C<300> or above starts a refusal without an extension gate. Its body,
trailers, and C<http.fullflush> follow the HTTP rules above, including
file/fh terminal bodies and the requirement to send declared trailers.

Legal terminal state for C<finalize>: C<closed> or C<refusal_complete>. A
completed refusal reports C<complete> true but C<closed> false because it is
not a C<websocket.close>.

=head2 sse

States: C<initial>, C<streaming>, C<refusing>, C<refusal_complete>,
C<closed>. Starting state is C<initial>.

Illegal: any stream event (C<sse.start>, C<sse.send>, C<sse.comment>,
C<sse.keepalive>, C<sse.close>) once a refusal has started; any HTTP response
event after C<sse.start>; any event once a refusal is complete; a duplicate
C<sse.start>; or C<http.fullflush> without the C<fullflush> extension. The
removed C<sse.http.response.*> names are unrecognized event types.

Legal: before C<sse.start>, C<http.response.start> starts a refusal and may
carry any status, including C<200>. Its body, trailers, and
C<http.fullflush> follow the HTTP rules above. C<sse.close> is idempotent
once C<closed>. C<http.fullflush>, when declared, is legal while streaming or
refusing and never changes the state.

Legal terminal state for C<finalize>: C<closed> or C<refusal_complete>.

=head2 lifespan

No event-driven state machine -- instead, C<enter_phase('startup'|
'shutdown')> declares which phase is current (starting phase:
C<startup>), driven externally by whatever is running the lifespan
protocol, not by C<check>. C<enter_phase> is trusted input: this module's
phase-matching guarantees hold only when the driver calls it on real
phase transitions (a real driver never opens C<shutdown> after
C<lifespan.startup.failed> -- lifespan is finished at that point, not
mid-startup); C<enter_phase> itself does not, and cannot, verify that.

Illegal: C<lifespan.startup.complete>/C<.failed> while the current phase is
not C<startup>; C<lifespan.shutdown.complete>/C<.failed> while the current
phase is not C<shutdown>; a second result event (of either kind) for the
same phase without an intervening C<enter_phase> call.

C<finalize> always returns C<undef> for lifespan scopes -- this module has
no terminal-state concept for the lifespan protocol.

=cut

sub started {
    my ($self) = @_;
    return 0 if $self->{scope_type} eq 'lifespan';
    return $self->{state} ne $INITIAL_STATE{$self->{scope_type}} ? 1 : 0;
}

sub complete {
    my ($self) = @_;
    my $type = $self->{scope_type};
    return $self->{state} eq 'complete' ? 1 : 0 if $type eq 'http';
    return ($self->{state} eq 'closed' || $self->{state} eq 'refusal_complete') ? 1 : 0
        if $type eq 'websocket' || $type eq 'sse';
    return 0;
}

sub closed {
    my ($self) = @_;
    my $type = $self->{scope_type};
    return $self->{state} eq 'closed' ? 1 : 0 if $type eq 'websocket' || $type eq 'sse';
    return 0;
}

sub trailers_declared { return $_[0]->{trailers_declared} ? 1 : 0 }

sub _error {
    my ($self, $category, $message) = @_;
    return PAGI::Utils::_SendValidation::Error->new(category => $category, message => $message);
}

sub check {
    my ($self, $event) = @_;

    return $self->_error(malformed => 'event must be a hash reference')
        unless ref $event eq 'HASH';

    my $type = $self->{scope_type};
    return $self->_check_http($event)      if $type eq 'http';
    return $self->_check_websocket($event) if $type eq 'websocket';
    return $self->_check_sse($event)       if $type eq 'sse';
    return $self->_check_lifespan($event)  if $type eq 'lifespan';
    return undef;
}

sub finalize {
    my ($self) = @_;

    my $type = $self->{scope_type};
    return $self->_finalize_http()      if $type eq 'http';
    return $self->_finalize_websocket() if $type eq 'websocket';
    return $self->_finalize_sse()       if $type eq 'sse';
    return undef; # lifespan: no terminal-state concept for this module
}

# =============================================================================
# HTTP -- see "=head2 http" in RULES above for the enforced rules.
# =============================================================================

# Event fields (PAGI Www.pod, RFC 9110). Each *_problem function returns
# undef for a good event, else the message.

sub _is_nonneg_int    { my ($v) = @_; return defined $v && !ref $v && $v =~ /\A[0-9]+\z/ }
sub _is_bool01        { my ($v) = @_; return defined $v && !ref $v && $v =~ /\A[01]\z/ }
sub _is_nonneg_number { my ($v) = @_; return defined $v && !ref $v && $v =~ /\A[0-9]+(?:\.[0-9]+)?\z/ }

# Bytes are characters <= 0xFF, whatever Perl's internal UTF-8 flag says; a
# wider character can't be written to a socket (PAGI::Server refuses it too).
sub _is_bytes {
    my $copy = $_[0];
    return utf8::downgrade($copy, 1);
}

# A response's status is final: three digits, 200 to 599. 1xx belongs to the
# server, and a leading zero, sign, fraction or padding would go to the wire
# as given.
sub _status_problem {
    my ($event_type, $status) = @_;
    return undef if defined $status && !ref $status && $status =~ /\A[2-5][0-9]{2}\z/;
    my $got = defined $status ? _escape_nonprintable("$status") : 'undef';
    return "$event_type 'status' must be 200 to 599 (got '$got')";
}

# A header name is an RFC 9110 token (S5.1). A value is an RFC 9110 field
# value (S5.5): empty, or bytes 0x21-0x7E and 0x80-0xFF with SP and HTAB only
# between two of them. A message shows the offending character by code and
# offset; it may show the name, escaped, and never shows the value.

my %CHAR_NAME = ("\t" => 'HTAB', ' ' => 'SP', "\r" => 'CR', "\n" => 'LF',
    "\0" => 'NUL', "\x7F" => 'DEL');

sub _describe_char {
    my ($c) = @_;
    my $ord = ord $c;
    return "a character above 0xFF (" . sprintf('\x{%x}', $ord) . ")" if $ord > 0xFF;
    my $code = sprintf '\x%02x', $ord;
    return "$CHAR_NAME{$c} ($code)"       if exists $CHAR_NAME{$c};
    return "a control character ($code)" if $ord < 0x20;
    return "a non-ASCII byte ($code)"    if $ord >= 0x80;
    return "'$c' ($code)";
}

sub _escape_nonprintable {
    my ($text) = @_;
    $text =~ s/([^\x20-\x7E])/ord $1 > 0xFF ? sprintf('\x{%x}', ord $1) : sprintf('\x%02x', ord $1)/ge;
    return $text;
}

sub _header_name_problem {
    my ($name) = @_;
    return 'name is empty' if $name eq '';
    return undef unless $name =~ /[^!#\$%&'*+\-.^_`|~0-9A-Za-z]/;
    my $at = $-[0];
    return "name '" . _escape_nonprintable($name) . "' contains " . _describe_char(substr $name, $at, 1)
        . " at offset $at (a header name must be an RFC 9110 token)";
}

sub _header_value_problem {
    my ($value) = @_;
    if ($value =~ /[^\t\x20-\x7E\x80-\xFF]/) {
        my $at = $-[0];
        my $c  = substr $value, $at, 1;
        return 'value contains ' . _describe_char($c) . " at offset $at"
            . (ord $c > 0xFF ? ' (encode it to bytes)' : '');
    }
    return 'value starts with ' . _describe_char($1) . '; trim it' if $value =~ /\A([ \t])/;
    return 'value ends with '   . _describe_char($1) . '; trim it' if $value =~ /([ \t])\z/;
    return undef;
}

sub _headers_problem {
    my ($headers, $event_type) = @_;
    return "$event_type 'headers' must be an array reference"
        unless ref $headers eq 'ARRAY';
    for my $i (0 .. $#$headers) {
        my $h = $headers->[$i];
        return "$event_type headers: each header must be a 2-element array reference"
            unless ref $h eq 'ARRAY' && @$h == 2;
        return "$event_type headers: header name and value must be defined strings"
            if !defined $h->[0] || !defined $h->[1] || ref $h->[0] || ref $h->[1];
        if (defined(my $problem = _header_name_problem($h->[0]))) {
            return "$event_type header $i: $problem";
        }
        if (defined(my $problem = _header_value_problem($h->[1]))) {
            return "$event_type header $i ('" . _escape_nonprintable($h->[0]) . "'): $problem";
        }
    }
    return undef;
}

# A response frames its body by content-length, so it may carry one field
# line holding one decimal number (RFC 9110 S8.6). A list ('5, 5') or a
# second line, equal or not, is a framing ambiguity.
sub _content_length_problem {
    my ($headers, $event_type) = @_;
    my $first;
    for my $i (0 .. $#$headers) {
        my ($name, $value) = @{ $headers->[$i] };
        next unless lc $name eq 'content-length';
        my $where = "$event_type header $i ('" . _escape_nonprintable($name) . "')";
        return "$where: content-length appears more than once (also header $first)"
            if defined $first;
        return "$where: content-length must be one decimal number"
            unless $value =~ /\A[0-9]+\z/;
        $first = $i;
    }
    return undef;
}

# The body length that headers already checked declare, or undef.
sub _declared_content_length {
    my ($headers) = @_;
    for my $h (@{ $headers // [] }) {
        return 0 + $h->[1] if lc $h->[0] eq 'content-length';
    }
    return undef;
}

sub _http_start_problem {
    my ($event) = @_;
    return "http.response.start requires 'status' field"
        unless exists $event->{status};
    my $problem = _status_problem('http.response.start', $event->{status});
    return $problem if $problem;
    if (defined $event->{headers}) {
        $problem = _headers_problem($event->{headers}, 'http.response.start')
            // _content_length_problem($event->{headers}, 'http.response.start');
        return $problem if $problem;
    }
    return "http.response.start 'trailers' must be 0 or 1"
        if defined $event->{trailers} && !_is_bool01($event->{trailers});
    return undef;
}

sub _http_body_problem {
    my ($event) = @_;
    my $count = grep { exists $event->{$_} } qw(body file fh);
    return "http.response.body requires exactly one of body/file/fh (got $count)"
        if $count > 1;   # none is an empty body
    # A body is bytes (PAGI Www.pod): not a plain reference, which would go
    # out as ARRAY(0x...), nor a string with a character above 0xFF.
    return "http.response.body 'body' must be bytes, not a " . ref($event->{body}) . ' reference'
        if ref $event->{body} && !Scalar::Util::blessed($event->{body});
    return "http.response.body 'body' contains a character above 0xFF (encode it to bytes)"
        if defined $event->{body} && !ref $event->{body} && !_is_bytes($event->{body});
    for my $field (qw(offset length)) {
        return "http.response.body '$field' must be a non-negative integer"
            if defined $event->{$field} && !_is_nonneg_int($event->{$field});
    }
    return "http.response.body 'more' must be 0 or 1"
        if defined $event->{more} && !_is_bool01($event->{more});
    return undef;
}

# The http.response.* events, on an http scope or as a refusal.
sub _http_event_problem {
    my ($event) = @_;
    my $type = $event->{type};
    return _http_start_problem($event) if $type eq 'http.response.start';
    return _http_body_problem($event)  if $type eq 'http.response.body';
    return _headers_problem($event->{headers}, 'http.response.trailers')
        if $type eq 'http.response.trailers' && defined $event->{headers};
    return undef;
}

sub _keepalive_problem {
    my ($event) = @_;
    my $type = $event->{type};
    return "$type requires 'interval' field" unless exists $event->{interval};
    return "$type 'interval' must be a non-negative number"
        unless _is_nonneg_number($event->{interval});
    return undef;
}

sub _websocket_event_problem {
    my ($event) = @_;
    my $type = $event->{type};
    return _http_event_problem($event) if $type =~ /\Ahttp\./;
    return _headers_problem($event->{headers}, 'websocket.accept')
        if $type eq 'websocket.accept' && defined $event->{headers};
    if ($type eq 'websocket.send') {
        my $count = grep { defined $event->{$_} } qw(bytes text);
        return "websocket.send requires exactly one of bytes/text (got $count)"
            unless $count == 1;
        return "websocket.send 'bytes' must be bytes, not a " . ref($event->{bytes}) . ' reference'
            if ref $event->{bytes} && !Scalar::Util::blessed($event->{bytes});
        return "websocket.send 'bytes' contains a character above 0xFF (encode it to bytes, or send text)"
            if defined $event->{bytes} && !ref $event->{bytes} && !_is_bytes($event->{bytes});
    }
    if ($type eq 'websocket.close') {
        return "websocket.close 'code' must be a non-negative integer"
            if defined $event->{code} && !_is_nonneg_int($event->{code});
        if (defined $event->{reason}) {
            return "websocket.close 'reason' must be a string" if ref $event->{reason};
            # RFC 6455 5.5: a close frame's payload is at most 125 bytes, the
            # 2-byte code and the reason, which is sent as UTF-8.
            my $bytes = $event->{reason};
            utf8::encode($bytes);
            return "websocket.close 'reason' must be at most 123 bytes as UTF-8 (got " . length($bytes) . ')'
                if length($bytes) > 123;
        }
    }
    if ($type eq 'websocket.keepalive') {
        my $problem = _keepalive_problem($event);
        return $problem if $problem;
        return "websocket.keepalive 'timeout' must be a non-negative number"
            if defined $event->{timeout} && !_is_nonneg_number($event->{timeout});
    }
    return undef;
}

sub _sse_event_problem {
    my ($event) = @_;
    my $type = $event->{type};
    return _http_event_problem($event) if $type =~ /\Ahttp\./;
    if ($type eq 'sse.start') {
        my $problem = defined $event->{status} ? _status_problem('sse.start', $event->{status}) : undef;
        return $problem if $problem;
        return _headers_problem($event->{headers}, 'sse.start') if defined $event->{headers};
    }
    if ($type eq 'sse.send') {
        return "sse.send requires 'data' field" unless exists $event->{data};
        return "sse.send 'data' must be a string" unless defined $event->{data} && !ref $event->{data};
        for my $field (qw(event id)) {
            next unless defined $event->{$field};
            return "sse.send '$field' must be a string" if ref $event->{$field};
            return "sse.send '$field' must not contain newline characters"
                if $event->{$field} =~ /[\r\n]/;
        }
        return "sse.send 'retry' must be a non-negative integer"
            if defined $event->{retry} && !_is_nonneg_int($event->{retry});
    }
    if ($type eq 'sse.comment') {
        return "sse.comment requires 'comment' field" unless exists $event->{comment};
        return "sse.comment 'comment' must be a string"
            unless defined $event->{comment} && !ref $event->{comment};
    }
    if ($type eq 'sse.keepalive') {
        my $problem = _keepalive_problem($event);
        return $problem if $problem;
        # A copy: Encode::encode with FB_CROAK consumes its input.
        my $comment = $event->{comment};
        return "sse.keepalive 'comment' must be a UTF-8-encodable string"
            if defined $comment
                && (ref $comment || !eval { Encode::encode('UTF-8', $comment, Encode::FB_CROAK); 1 });
    }
    return "sse.close 'reason' must be a string"
        if $type eq 'sse.close' && ref $event->{reason};
    return undef;
}

sub _lifespan_event_problem {
    my ($event) = @_;
    my $type = $event->{type};
    return "$type 'message' must be a string"
        if $type =~ /\.failed\z/ && ref $event->{message};
    return undef;
}

# A WebSocket refusal's status is 300 or above: 101 is the HTTP/1.1
# acceptance and any HTTP/2 2xx answer to the CONNECT opens the tunnel.
sub _refusal_status_problem {
    my ($event) = @_;
    return undef unless $event->{type} eq 'http.response.start' && $event->{status} < 300;
    return "WebSocket refusal status must be 300 or above (got $event->{status})";
}

# One body send counted against a declared content-length: undef when it
# fits, else the problem.
sub _count_problem {
    my ($count, $bytes, $terminal) = @_;
    my ($declared, $remaining) = @$count{qw(declared remaining)};
    return "http.response.body would send $bytes bytes, " . ($bytes - $remaining)
        . " more than the declared content-length ($declared)"
        if $bytes > $remaining;
    my $left = $remaining - $bytes;
    return "http.response.body ends the response $left bytes short of the declared content-length ($declared)"
        if $terminal && $left > 0;
    return undef;
}

# The bytes a body send writes, known when it is sent; undef for an fh
# without a length, whose size is known only once it is read, and for a
# file that isn't there (the send that reads it says so).
sub _body_send_bytes {
    my ($event) = @_;
    my ($file, $fh) = @$event{qw(file fh)};
    if (defined $file) {
        return undef unless -f $file;
        my $bytes = $event->{length} // ((-s $file) - ($event->{offset} // 0));
        return $bytes < 0 ? 0 : $bytes;
    }
    return $event->{length} if defined $fh;
    return length($event->{body} // '');
}

sub _http_body_is_opaque {
    my ($event) = @_;
    return defined $event->{file} || defined $event->{fh};
}

sub _http_body_is_terminal {
    my ($event) = @_;
    return 1 if _http_body_is_opaque($event);
    return !($event->{more} // 0);
}

# The declared content-length a response start begins counting, or undef.
# HTTP/1.x frames the body by it; HEAD, 204 and 304 carry no body to count.
sub _body_count {
    my ($self, $event) = @_;
    return undef unless ($self->{http_version} // '') =~ /\A1\./;
    return undef if ($self->{method} // '') eq 'HEAD' || $event->{status} == 204 || $event->{status} == 304;
    my $declared = _declared_content_length($event->{headers});
    return defined $declared ? +{ declared => $declared, remaining => $declared } : undef;
}

sub _check_http_response_event {
    my ($self, $event, $state_key, $trailers_key) = @_;
    my $type  = $event->{type};
    my $state = $self->{$state_key};

    if ($type eq 'http.fullflush') {
        return $self->_error(extension => "Extension not enabled: fullflush")
            unless exists $self->{extensions}{fullflush};
        return $self->_error(sequence => "cannot send http.fullflush before http.response.start")
            if $state eq 'initial';
        return $self->_error(sequence => "cannot send http.fullflush: response already complete")
            if $state eq 'complete';
        return undef;
    }

    return $self->_error(sequence => "cannot send '$type': response already complete")
        if $state eq 'complete';

    if ($type eq 'http.response.start') {
        return $self->_error(sequence => 'cannot send duplicate http.response.start')
            unless $state eq 'initial';
        my $declares_trailers = $event->{trailers} ? 1 : 0;
        $self->{$state_key}    = $declares_trailers ? 'started_t' : 'started';
        $self->{$trailers_key} = $declares_trailers;
        $self->{"${state_key}_content_length"} = defined _declared_content_length($event->{headers});
        $self->{"${state_key}_count"} = $self->_body_count($event);
        return undef;
    }

    if ($type eq 'http.response.body') {
        return $self->_error(sequence => 'cannot send http.response.body before http.response.start')
            if $state eq 'initial';
        return $self->_error(sequence => 'cannot send http.response.body: body already terminal, awaiting trailers')
            if $state eq 'awaiting_trailers';
        # A response's body is inline events or one file/fh event, never both
        # (PAGI Www.pod "Payload kinds do not mix within a response").
        return $self->_error(sequence => 'cannot send a file/fh body after inline body bytes')
            if _http_body_is_opaque($event) && $self->{"${state_key}_inline"};

        my $count = $self->{"${state_key}_count"};
        my $bytes = $count && _body_send_bytes($event);
        if (defined $bytes) {
            my $problem = _count_problem($count, $bytes, _http_body_is_terminal($event));
            return $self->_error(sequence => $problem) if $problem;
            $self->{"${state_key}_count"} = +{ %$count, remaining => $count->{remaining} - $bytes };
        }
        $self->{"${state_key}_inline"} = 1 unless _http_body_is_opaque($event);
        if (_http_body_is_terminal($event)) {
            $self->{$state_key} = ($state eq 'started_t') ? 'awaiting_trailers' : 'complete';
        }
        return undef;
    }

    return $self->_error(sequence => 'cannot send http.response.trailers before http.response.start')
        if $state eq 'initial';
    return $self->_error(sequence => 'cannot send http.response.trailers: trailers were not declared or body is not complete')
        unless $state eq 'awaiting_trailers';
    # HTTP/1.x carries trailers only in chunked coding, which a declared
    # content-length rules out; HTTP/2 has no such limit (PAGI Www.pod
    # "Response Trailers").
    return $self->_error(sequence => 'http.response.trailers requires chunked framing (response declared content-length)')
        if $self->{"${state_key}_content_length"} && ($self->{http_version} // '') =~ /\A1\./;
    $self->{$state_key} = 'complete';
    return undef;
}

sub _check_http {
    my ($self, $event) = @_;
    my $type = defined $event->{type} ? $event->{type} : '';

    return $self->_error(malformed => "http send event missing 'type' field")
        if $type eq '';

    return $self->_error(unknown_type => "unrecognized event type '$type' for http protocol")
        unless $type eq 'http.response.start'
            || $type eq 'http.response.body'
            || $type eq 'http.response.trailers'
            || $type eq 'http.fullflush';

    # Fields first, then the sequence.
    if (my $problem = _http_event_problem($event)) {
        return $self->_error(malformed => $problem);
    }
    return $self->_check_http_response_event($event, 'state', 'trailers_declared');
}

sub _finalize_http {
    my ($self) = @_;
    my $state = $self->{state};

    return undef if $state eq 'complete';
    return $self->_error(incomplete => 'response never sent http.response.start')
        if $state eq 'initial';
    return $self->_error(incomplete => 'response awaiting a terminal body chunk')
        if $state eq 'started' || $state eq 'started_t';
    return $self->_error(incomplete => 'response awaiting declared http.response.trailers'); # awaiting_trailers
}

# =============================================================================
# WebSocket -- see "=head2 websocket" in RULES above for the enforced rules.
# =============================================================================

sub _check_websocket {
    my ($self, $event) = @_;
    my $type = defined $event->{type} ? $event->{type} : '';

    return $self->_error(malformed => "websocket send event missing 'type' field")
        if $type eq '';

    my $is_http = $type eq 'http.response.start'
        || $type eq 'http.response.body'
        || $type eq 'http.response.trailers'
        || $type eq 'http.fullflush';
    return $self->_error(unknown_type => "unrecognized event type '$type' for websocket protocol")
        unless $is_http || $type eq 'websocket.accept' || $type eq 'websocket.send'
            || $type eq 'websocket.close' || $type eq 'websocket.keepalive';

    # Fields first, then the sequence.
    if (my $problem = _websocket_event_problem($event)) {
        return $self->_error(malformed => $problem);
    }
    if (my $problem = _refusal_status_problem($event)) {
        return $self->_error(sequence => $problem);
    }

    if ($self->{state} eq 'closed') {
        return $self->_error(sequence => "cannot send '$type' after websocket.close");
    }
    if ($self->{state} eq 'refusal_complete') {
        return $self->_error(sequence => "cannot send '$type': refusal already complete");
    }

    if ($self->{state} eq 'connecting') {
        if ($type eq 'websocket.accept') { $self->{state} = 'accepted'; return undef; }
        if ($is_http) {
            my $err = $self->_check_http_response_event(
                $event, 'refusal_http_state', 'refusal_trailers_declared',
            );
            return $err if $err;
            $self->{state} = $self->{refusal_http_state} eq 'complete'
                ? 'refusal_complete' : 'refusing';
            return undef;
        }
        return $self->_error(sequence => "cannot send '$type' before websocket.accept");
    }

    if ($self->{state} eq 'refusing') {
        if ($is_http) {
            my $err = $self->_check_http_response_event(
                $event, 'refusal_http_state', 'refusal_trailers_declared',
            );
            return $err if $err;
            $self->{state} = 'refusal_complete'
                if $self->{refusal_http_state} eq 'complete';
            return undef;
        }
        return $self->_error(sequence => "cannot send '$type' after http.response.start");
    }

    # $self->{state} eq 'accepted'
    return $self->_error(sequence => "cannot send '$type' after websocket.accept")
        if $is_http;
    return undef if $type eq 'websocket.send' || $type eq 'websocket.keepalive';
    if ($type eq 'websocket.close') { $self->{state} = 'closed'; return undef; }
    return $self->_error(sequence => 'cannot send duplicate websocket.accept')
        if $type eq 'websocket.accept';
    return $self->_error(sequence => "cannot send '$type' after websocket.accept");
}

sub _finalize_websocket {
    my ($self) = @_;

    return undef if $self->{state} eq 'closed' || $self->{state} eq 'refusal_complete';
    return $self->_error(incomplete => 'websocket connection awaiting websocket.accept or an HTTP refusal')
        if $self->{state} eq 'connecting';
    if ($self->{state} eq 'refusing') {
        return $self->_error(incomplete => 'websocket refusal awaiting declared http.response.trailers')
            if $self->{refusal_http_state} eq 'awaiting_trailers';
        return $self->_error(incomplete => 'websocket refusal awaiting a terminal body chunk');
    }
    return $self->_error(incomplete => 'websocket connection awaiting websocket.close'); # accepted
}

# =============================================================================
# SSE -- see "=head2 sse" in RULES above for the enforced rules.
# =============================================================================

my %SSE_RECOGNIZED = map { $_ => 1 } qw(
    sse.start sse.send sse.comment sse.keepalive sse.close
    http.response.start http.response.body http.response.trailers http.fullflush
);

sub _check_sse {
    my ($self, $event) = @_;
    my $type = defined $event->{type} ? $event->{type} : '';

    return $self->_error(malformed => "sse send event missing 'type' field")
        if $type eq '';

    return $self->_error(unknown_type => "unrecognized event type '$type' for sse protocol")
        unless $SSE_RECOGNIZED{$type};

    my $is_http = $type eq 'http.response.start'
        || $type eq 'http.response.body'
        || $type eq 'http.response.trailers'
        || $type eq 'http.fullflush';

    # Fields first, then the sequence.
    if (my $problem = _sse_event_problem($event)) {
        return $self->_error(malformed => $problem);
    }

    if ($self->{state} eq 'closed') {
        return undef if $type eq 'sse.close'; # idempotent, like the reference server
        return $self->_error(sequence => "cannot send '$type' after sse.close");
    }
    return $self->_error(sequence => "cannot send '$type': refusal already complete")
        if $self->{state} eq 'refusal_complete';

    if ($self->{state} eq 'initial') {
        if ($type eq 'sse.start') { $self->{state} = 'streaming'; return undef; }
        if ($is_http) {
            my $err = $self->_check_http_response_event(
                $event, 'refusal_http_state', 'refusal_trailers_declared',
            );
            return $err if $err;
            $self->{state} = $self->{refusal_http_state} eq 'complete'
                ? 'refusal_complete' : 'refusing';
            return undef;
        }
        return $self->_error(sequence => "cannot send '$type' before sse.start");
    }

    if ($self->{state} eq 'streaming') {
        if ($type eq 'http.fullflush') {
            return $self->_error(extension => 'Extension not enabled: fullflush')
                unless exists $self->{extensions}{fullflush};
            return undef;
        }
        return $self->_error(sequence => "cannot send '$type' after sse.start")
            if $is_http;
        return undef if $type eq 'sse.send' || $type eq 'sse.comment' || $type eq 'sse.keepalive';
        if ($type eq 'sse.close') { $self->{state} = 'closed'; return undef; }
        return $self->_error(sequence => 'cannot send duplicate sse.start')
            if $type eq 'sse.start';
        return $self->_error(sequence => "cannot send '$type' after sse.start");
    }

    # $self->{state} eq 'refusing'
    if ($is_http) {
        my $err = $self->_check_http_response_event(
            $event, 'refusal_http_state', 'refusal_trailers_declared',
        );
        return $err if $err;
        $self->{state} = 'refusal_complete'
            if $self->{refusal_http_state} eq 'complete';
        return undef;
    }
    return $self->_error(sequence => "cannot send '$type' after http.response.start");
}

sub _finalize_sse {
    my ($self) = @_;
    my $state = $self->{state};

    return undef if $state eq 'closed' || $state eq 'refusal_complete';
    return $self->_error(incomplete => 'sse stream never started (no sse.start and no refusal)')
        if $state eq 'initial';
    return $self->_error(incomplete => 'sse stream awaiting sse.close')
        if $state eq 'streaming';
    return $self->_error(incomplete => 'sse refusal awaiting declared http.response.trailers')
        if $self->{refusal_http_state} eq 'awaiting_trailers';
    return $self->_error(incomplete => 'sse refusal awaiting a terminal body chunk'); # refusing
}

# =============================================================================
# Lifespan -- see "=head2 lifespan" in RULES above for the enforced rules.
# =============================================================================

my %LIFESPAN_RECOGNIZED = map { $_ => 1 } qw(
    lifespan.startup.complete lifespan.startup.failed
    lifespan.shutdown.complete lifespan.shutdown.failed
);

sub _check_lifespan {
    my ($self, $event) = @_;
    my $type = defined $event->{type} ? $event->{type} : '';

    return $self->_error(malformed => "lifespan send event missing 'type' field")
        if $type eq '';
    return $self->_error(unknown_type => "unrecognized event type '$type' for lifespan protocol")
        unless $LIFESPAN_RECOGNIZED{$type};
    if (my $problem = _lifespan_event_problem($event)) {
        return $self->_error(malformed => $problem);
    }

    my $expected_phase = ($type =~ /^lifespan\.startup\./) ? 'startup' : 'shutdown';
    return $self->_error(sequence => "cannot send '$type' during lifespan phase '$self->{phase}'")
        unless $self->{phase} eq $expected_phase;
    return $self->_error(sequence => "cannot send '$type': a result was already sent for lifespan phase '$self->{phase}'")
        if $self->{result_sent};

    $self->{result_sent} = 1;
    return undef;
}

package PAGI::Utils::_SendValidation::Error;

use strict;
use warnings;
use overload
    q{""} => 'message',
    bool  => sub { 1 }, # an Error is always true, even with an empty message
    fallback => 1;

=head1 NAME

PAGI::Utils::_SendValidation::Error - Illegal-send diagnostic returned by PAGI::Utils::_SendValidation

=head1 DESCRIPTION

A plain, throwable-free diagnostic value: C<PAGI::Utils::_SendValidation::check> and
C<finalize> return one of these instead of dying when an event is illegal or
a scope has not reached a legal terminal state. It stringifies to its
C<message>, so C<warn $err> and C<diag $err> work directly.

=head1 CONSTRUCTOR

=head2 new

    my $err = PAGI::Utils::_SendValidation::Error->new(
        category => $category,
        message  => $message,
    );

Both C<category> and C<message> are stored as given; this class does not
validate them itself (only C<PAGI::Utils::_SendValidation> constructs these).

=head1 ACCESSORS

=head2 message

A human-readable string describing what was illegal.

=head2 category

One of:

=over 4

=item * C<malformed> -- the argument to C<check> was not even a usable
event: not a hash reference, or a hash reference with no C<type> field
(missing key, or an undefined/empty value), so there is no type string to
evaluate; or an event whose fields break L</Fields>.

=item * C<unknown_type> -- C<type> is a defined, non-empty string, but not
one this scope recognizes (and, where applicable, not a declared
extension's type either).

=item * C<sequence> -- the event's C<type> is recognized, but it is out of
order for what has already been sent (or, for lifespan, sent in the wrong
phase, or a second result for a phase already reported), including a body
that doesn't fit its declared content-length.

=item * C<extension> -- the event's type requires an advertised extension
(currently just C<http.fullflush>) that is not present in this scope's
C<extensions>.

=item * C<incomplete> -- C<finalize> only: the scope has not reached a
legal terminal state.

=back

C<malformed> and C<unknown_type> are deliberately distinct: C<malformed>
is a structurally broken event (nothing to dispatch on), while
C<unknown_type> is an event with a real, but wrong, type string -- callers
that want to distinguish "app sent garbage" from "app sent a genuinely
unrecognized event type" can branch on this.

=cut

sub new {
    my ($class, %args) = @_;
    return bless {
        message  => $args{message},
        category => $args{category},
    }, $class;
}

sub message  { return $_[0]->{message} }
sub category { return $_[0]->{category} }

1;

__END__

=head1 SEE ALSO

L<PAGI::Server::EventValidator> -- the reference server's authoritative
event-shape and send-sequencing validator, whose category intent this
module mirrors.

=cut
