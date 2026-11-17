package PAGI::Response;

use v5.24;
use warnings;
use parent 'PAGI::App';
use Carp ();
use Future;
use Class::Tiny;   # new, BUILDARGS and BUILD; the fields are this class's own

# A response is immutable: built once, from what you give it, and only
# read after that, except that cookies can be added. Everything, the
# headers included, is worked out here, once; nothing it's worked out
# from can change after, so nothing derived can go stale.
sub BUILD {
    my ($self, $args) = @_;
    $self->prepare($args);
}

# The constructor's arguments, made into the response's fields: one step
# per argument. Each step returns its value and prepare keeps it; a step
# that depends on others is given their values, never left to read fields
# another step may not have set yet. A subclass with arguments of its own
# extends this, or the step for the argument it adds to.
sub prepare {
    my ($self, $args) = @_;
    my $status   = $self->{status}   = $self->prepare_status($args);
    my $body     = $self->{body}     = $self->prepare_body($args);
    my $type     = $self->{content_type}
                 = $self->prepare_content_type($args, status => $status, body => $body);
    $self->{headers} = $self->prepare_headers($args,
        status => $status, body => $body, content_type => $type);
    return;
}

# The status: yours, else 200.
sub prepare_status {
    my ($self, $args) = @_;
    return $args->{status} // 200;
}

# The content, rendered to bytes once.
sub prepare_body {
    my ($self, $args) = @_;
    return $self->render($args->{content});
}

# The type you gave, undef included; else the class's default, on every
# status: a 204 or 304 sends what it's given, and the server drops what it
# can't carry.
sub prepare_content_type {
    my ($self, $args, %prepared) = @_;
    return $args->{content_type} if exists $args->{content_type};
    return $self->default_content_type;
}

# The headers the start sends, worked out once from what the other steps
# prepared: yours, copied (so changing your list later changes nothing)
# with each name lowercased (names are bytes, so tr changes ASCII letters
# only), then the body's length and the type unless you gave them. No
# length on a status that has no body (RFC 9110), nor without a body.
sub prepare_headers {
    my ($self, $args, %prepared) = @_;
    my @headers = map { my $name = $_->[0]; $name =~ tr/A-Z/a-z/; [$name, $_->[1]] } @{ $args->{headers} // [] };
    my %has = map { $_->[0] => 1 } @headers;
    push @headers, ['content-length', length $prepared{body}]
        if defined $prepared{body} && !$has{'content-length'} && !_without_content($prepared{status});
    push @headers, ['content-type', $prepared{content_type}]
        if defined $prepared{content_type} && !$has{'content-type'};
    return \@headers;
}

# The getters. Given a value, each croaks: nothing about a response changes.

sub status {
    my $self = shift;
    _immutable('status') if @_;
    return $self->{status};
}

# Not only the headers you gave: those, normalized (names lowercased), plus
# the ones worked out for you (Content-Length, Content-Type), then any
# cookies set. This is what the start sends. The response's own list, as a
# Moose 'ro' attribute returns it: don't change it; set_cookie adds to it.
sub headers {
    my $self = shift;
    _immutable('headers') if @_;
    return $self->{headers};
}

# Always false here: a buffered body is known before the start goes out, so
# what a trailer would carry goes in a header. A streaming subclass sets it.
sub has_trailers {
    my $self = shift;
    _immutable('has_trailers') if @_;
    return $self->{has_trailers};
}

sub body {
    my $self = shift;
    _immutable('body') if @_;
    return $self->{body};
}

sub content_type {
    my $self = shift;
    _immutable('content_type') if @_;
    return $self->{content_type};
}

sub _immutable {
    my ($name) = @_;
    Carp::croak("response is immutable: \$response->$name can't be set; build a new response");
}

# Cookies are the one thing added after a response is built. A Set-Cookie
# header is worked out from nothing else, and nothing is worked out from
# it, so adding one leaves nothing stale. The start sends the headers as
# they are when it goes out, so add cookies before you serve the response.
sub set_cookie {
    my ($self, $name, $value, %attributes) = @_;
    push @{ $self->{headers} }, ['set-cookie', _set_cookie($name, $value, %attributes)];
    return $self;
}

# The cookie, emptied and expired. Given the attributes it was set with,
# the same path and domain, the browser removes the one it has.
sub delete_cookie {
    my ($self, $name, %attributes) = @_;
    return $self->set_cookie($name, '', %attributes, max_age => 0, expires => 0);
}

# A Set-Cookie header's value. Each field is checked on its own (RFC 6265),
# and a bad one croaks with the fix rather than having it made for you, so
# what you set is what's sent. The value is raw: encode it yourself. The
# path is / unless you give one, and undef sends none.
sub _set_cookie {
    my ($name, $value, %attributes) = @_;
    my %cookie = (path => '/', %attributes);
    Carp::croak('a cookie needs a name') unless defined $name && length $name;
    Carp::croak("cookie name contains '$1': a name is an RFC 6265 token")
        if $name =~ /([^!#\$%&'*+\-.^_`|~0-9A-Za-z])/;
    Carp::croak('cookie value must be a string, not ' . (defined $value ? 'a ' . ref($value) . ' reference' : 'undef'))
        if !defined $value || ref $value;
    Carp::croak("cookie value contains '$1', which browsers can't carry: encode it first (Base64 or URI::Escape)")
        if $value =~ /([^\x21\x23-\x2B\x2D-\x3A\x3C-\x5B\x5D-\x7E])/;
    my $bytes = length($name) + length($value);
    Carp::croak("cookie $name is $bytes bytes of name and value: browsers ignore one over 4096") if $bytes > 4096;
    # No ; and no control character: either would end or break the header.
    # An epoch expires is digits, so only a date string can fail this.
    for my $attribute (qw(path domain expires)) {
        Carp::croak("cookie $attribute can't contain ';' or a control character")
            if defined $cookie{$attribute} && $cookie{$attribute} =~ /[;\x00-\x1F\x7F]/;
    }
    Carp::croak('max_age must be a whole number of seconds')
        if defined $cookie{max_age} && $cookie{max_age} !~ /\A-?\d+\z/;
    Carp::croak('samesite must be lax, strict or none')
        if defined $cookie{samesite} && $cookie{samesite} !~ /\A(?:lax|strict|none)\z/i;

    my @parts = ("$name=$value");
    push @parts, "Path=$cookie{path}"                      if defined $cookie{path};
    push @parts, "Domain=$cookie{domain}"                  if defined $cookie{domain};
    push @parts, 'Expires=' . _date($cookie{expires})      if defined $cookie{expires};
    push @parts, "Max-Age=$cookie{max_age}"                if defined $cookie{max_age};
    push @parts, 'SameSite=' . ucfirst lc $cookie{samesite} if defined $cookie{samesite};
    push @parts, 'Secure'      if $cookie{secure};
    push @parts, 'HttpOnly'    if $cookie{httponly};
    push @parts, 'Partitioned' if $cookie{partitioned};
    return join '; ', @parts;
}

my @DAY   = qw(Sun Mon Tue Wed Thu Fri Sat);
my @MONTH = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);

# An epoch number as an HTTP date (RFC 9110 5.6.7); a string is yours, as given.
sub _date {
    my ($expires) = @_;
    return $expires unless $expires =~ /\A\d+\z/;
    my ($sec, $min, $hour, $mday, $mon, $year, $wday) = gmtime $expires;
    return sprintf '%s, %02d %s %04d %02d:%02d:%02d GMT',
        $DAY[$wday], $mday, $MONTH[$mon], $year + 1900, $hour, $min, $sec;
}

# 204 and 304 responses cannot contain content (RFC 9110 6.4.1), so the
# length of the content given isn't theirs to declare: a 204 MUST NOT carry
# one, and a 304's would be its 200's.
sub _without_content {
    my ($status) = @_;
    # As strings: a status that isn't a number is the send's to refuse, not
    # ours to warn about.
    return $status eq '204' || $status eq '304';
}

# The content as bytes: here, as given, and no content is an empty body.
# Whether a body is bytes is checked where every send is, by the server
# (and PAGI::Test::Client), not here.
sub render {
    my ($self, $content) = @_;
    return defined $content ? $content : '';
}

# The class's type: none here, as Starlette's Response has no media_type. A
# format sets its own.
sub default_content_type { return undef }

# Serving the response: the start, then the body as one event, issued once
# the start's send has succeeded. The Future returned is this call's own,
# settled from the sends' Futures, so a caller that cancels it (a timeout)
# cancels neither of the server's sends. It aborts the connection instead:
# the start has gone out, so the response can't be finished, and the client
# gets a cut connection rather than a last body event saying it's complete.
# No body follows; a send already issued is left to settle. It isn't an
# async sub: cancelling one cancels the Future it's awaiting, here the
# server's send, which the PAGI spec says an application shouldn't do, and
# its CANCEL block, which would do the abort, is experimental.
sub call {
    my ($self, $scope, $receive, $send) = @_;
    my $done  = Future->new;
    my $start = Future->call(sub { $self->send_start($send) });
    $done->on_cancel(sub {
        my $connection = $scope->{'pagi.connection'};
        $connection->abort('response cancelled by caller') if $connection;
    });
    $start->on_ready(sub {
        my ($started) = @_;
        return if $done->is_cancelled;
        return _settle($done, $started, 'start') unless $started->is_done;
        Future->call(sub { $send->({ type => 'http.response.body', body => $self->body, more => 0 }) })
            ->on_ready(sub { _settle($done, $_[0], 'body') });
    });
    return $done;
}

# Settles call's Future from a send's: its failure, details included, else
# done. A send Future cancelled by someone else fails it, rather than leave
# call waiting or say the response went out.
sub _settle {
    my ($done, $sent, $what) = @_;
    return $done->fail($sent->failure) if $sent->is_failed;
    return $done->fail("the ${what}'s send was cancelled\n") if $sent->is_cancelled;
    return $done->done;
}

# The start: the status, a copy of the headers (a middleware may edit it),
# and whether trailers follow.
sub send_start {
    my ($self, $send) = @_;
    return $send->({
        type    => 'http.response.start',
        status  => $self->status,
        headers => [map { [@$_] } @{ $self->headers }],
        ($self->has_trailers ? (trailers => 1) : ()),
    });
}

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::Response - An HTTP response, and the base for every other kind

=head1 SYNOPSIS

    use v5.40;
    use PAGI::Response;

    open my $fh, '<:raw', 'logo.png' or die "Can't read logo.png: $!\n";
    my $logo  = PAGI::Response->new(content => do { local $/; <$fh> }, content_type => 'image/png');
    my $empty = PAGI::Response->new(status => 204);   # each is an application: serve it, or call it from yours

=head1 INHERITANCE

    PAGI::Response
      PAGI::App
        Class::Tiny::Object

C<to_app> comes from L<PAGI::App>, and C<new> from L<Class::Tiny>.

=head1 RATIONALE

This is Starlette's C<Response>, ported, with one change that shapes the
rest: once you've built a response, it can't be changed, apart from adding
cookies.

Starlette works a response out when you build it, then lets you keep
changing it, so what it worked out can fall behind: change the body after
and the Content-Length is wrong. We decide everything once, when you build
it, from what you gave it: the status, the headers, the body's bytes, its
Content-Length and its Content-Type. None of that changes after, so nothing has
to be checked again when it's sent, and nothing can go stale. When you want
something different, build a new one.

Cookies are the exception, and you add them as you would with Starlette,
with C<set_cookie> and C<delete_cookie> after the response is built. A
Set-Cookie header is worked out from nothing else, and nothing is worked out
from it, so adding one can't make anything stale:

    PAGI::Response::Text->new(content => "Welcome back\n")
        ->set_cookie(session => $id, httponly => 1, secure => 1);

Unlike Starlette's, they add only what you ask for: Starlette sends
SameSite=Lax unless you say otherwise, and we send no SameSite at all.

Code that adds a header to a response it didn't build does it the way
middleware does: on the start event, as it's sent.

Where else we differ from Starlette, it's for Perl or for PAGI. The base
sends no Content-Type unless you give one; L<PAGI::Response::Text> and
L<PAGI::Response::JSON> have their own. Nor does it add a charset to a type you
give: it's given bytes, so it can't know their encoding. L<PAGI::Response::Text>
encodes, so it does. And trailers belong to L<PAGI::Response::Stream>, whose
body has them at its end.

Build a response for each request, in the handler that answers it. One
that's the same for everyone can be sent more than once, but that's not what
it's for, and one that carries anything about a user (a cookie, a name) must
never be.

=head1 DESCRIPTION

Use C<PAGI::Response> as it is for bytes, or for a response with no body.
For text, HTML or JSON, use the class for it. For a format of your own,
override C<render> and C<default_content_type>; for arguments of your own,
extend C<prepare> or one of its steps; see L</COOKBOOK>.

=head1 CONSTRUCTOR ARGUMENTS

    PAGI::Response->new(content => $content, %args);

=over 4

=item content

What to send, given by name. It's rendered to bytes once, by C<render>,
and kept as C<body>. Here it must already be bytes: a string with a
character above 0xFF, or a reference, fails when it's sent, as the PAGI
spec has a server refuse it (L<PAGI::Test::Client> refuses it too, so your
tests see it). With none, or C<undef>, the body is empty.

Always give it by name. Content on its own, C<< new('abc') >>, dies with
Class::Tiny's odd-number-of-arguments error. A reference on its own is
worse: Class::Tiny takes a lone hash reference as the arguments, not the
content, so nothing tells you it went wrong:

    PAGI::Response::JSON->new(content => { hello => 'world' });   # {"hello":"world"}
    PAGI::Response::JSON->new({ hello => 'world' });              # null: hello isn't an argument

=item status

The status code. Defaults to 200.

=item headers

Your headers, as the PAGI spec writes them: C<[[name, value], ...]>, values
as bytes. They're copied, with each name lowercased (ASCII letters only,
since names are bytes). A C<content-type> or C<content-length> you give is
the one sent.

=item content_type

The Content-Type, when C<headers> has none. Defaults to the class's
C<default_content_type>, which is none here, on every status. One you give
is sent as given: no charset is added, and C<undef> sends none.

=back

=head1 METHODS

=head2 status, headers, content_type, has_trailers, body

    my $status = $response->status;

What the response was built with: C<content_type> is the one you gave,
else the class's default; C<has_trailers> is always false, since a
buffered body is known before the start goes out and what a trailer would
carry goes in a header. They only read: given a value, each croaks, since a
response can't be changed (see L</RATIONALE>).

C<body> is the rendered content, as bytes, here and in the classes that
render content. On a L<PAGI::Response::Stream> it's the code you gave,
which writes the body when the response is served. Code that looks at
responses it didn't build checks C<< $response->isa('PAGI::Response::Stream') >>
before treating C<body> as bytes.

C<headers> is not only the headers you set: it's those, normalized (each
name lowercased), plus the ones worked out for you, the Content-Length and
the Content-Type. It's the list the start sends, as
C<[[name, value], ...]>. It's the response's own list, as a Moose C<ro>
attribute returns it: don't change what's in it. L</set_cookie> adds to it.

=head2 set_cookie

    $response->set_cookie($name, $value, %attributes);

    PAGI::Response->new(status => 303, headers => [['location', '/']])
        ->set_cookie(session => $id, max_age => 86400, httponly => 1, secure => 1);

Adds a Set-Cookie header, after the others, and returns the response, so
calls chain. Each call adds one; the same name set twice is sent twice. Add
cookies before you serve the response: the start sends the headers as they
are when it goes out.

The name is an RFC 6265 token (letters, digits and C<!#$%&'*+-.^_`|~>). The
value is sent as given, so it must be cookie-octets: no space, C<">, C<,>,
C<;>, C<\>, control character or non-ASCII byte. Browsers end a value at
C<;>, and other readers split on C<,> or strip quotes, so only these read
back unchanged through every client. We don't encode anything else for
you; L</"In a cookie"> says why, and what to do with text. A name and value
over 4096 bytes together croak: browsers ignore the cookie (RFC 6265bis
5.6).

The attributes, each written only if you give it:

=over 4

=item path

Defaults to C</>, the only default. Without a Path, a browser keeps the
cookie for the directory of the page that set it (RFC 6265 5.1.4), so a
session set by C</account/login> would be sent only under C</account/>.
C<undef> sends no Path.

=item domain

=item expires

An epoch number, sent as an HTTP date (C<time + 3600> for an hour from
now), or a date string, sent as given.

=item max_age

Seconds, a whole number.

=item samesite

C<lax>, C<strict> or C<none>, any case; sent capitalized.

=item secure, httponly, partitioned

True to send the flag.

=back

A path, domain or expires string with a C<;> or a control character
croaks, as does a bad C<max_age> or C<samesite>. Each croaks with what to
fix, from the line that set the cookie; nothing is fixed for you. What
browsers require of attributes together is yours to get right, and a
browser drops a cookie that gets it wrong: a C<__Secure-> or C<__Host->
name needs C<secure>, and C<__Host-> also the path C</> and no domain;
C<< samesite => 'none' >> and C<partitioned> need C<secure>.

=head2 delete_cookie

    $response->delete_cookie($name, %attributes);

Adds the Set-Cookie header that removes a cookie: this name, emptied, with
C<< max_age => 0 >> and an expiry in 1970, and returns the response. A
browser removes a cookie only when the name, path and domain match, so give
it the attributes you set the cookie with. One hash used for both keeps
them the same:

    my %session = (path => '/app', httponly => 1, secure => 1);
    $response->set_cookie(session => $id, %session);    # logging in
    $response->delete_cookie('session', %session);      # logging out

=head2 call

    await $response->call($scope, $receive, $send);

The response as a PAGI application; C<to_app> returns a code reference that
calls it. It sends the start (C<send_start>), then, once the start's send
has succeeded, the body as one event, the last. On a 204 or 304 the body is
sent as it is, and the server discards it.

It returns a Future of its own, settled by the sends: it fails with a send's
error when one fails (no body is sent if the start failed), and is done once
the body has gone. Cancelling it cancels neither of the server's sends.

Cancelling it (a timeout, say) aborts the response: the start has already
gone out, so C<call> calls C<< $scope->{'pagi.connection'}->abort('response
cancelled by caller') >> and sends no body, and the client gets a cut
connection rather than a response that looks complete. With no
C<pagi.connection> in the scope it just sends no body.

A client that disconnects doesn't make C<call> fail: under the PAGI spec, a
send to a connection that has closed succeeds and does nothing. So C<call>
being done means the response was handed to the server, not that the client
has it. Whether the client is still there is the connection's to say
(C<< $scope->{'pagi.connection'} >>; see L<PAGI::Spec::Www>).

=head2 send_start

    await $response->send_start($send);

The start: the status, a copy of C<headers> (so a middleware that changes
it changes only that request), and, if C<has_trailers>, that trailers
follow. It returns the send's Future.

=head2 prepare

    sub prepare ($self, $args) { ... }

Makes the constructor's arguments into the response's fields, once, when
you build it (C<BUILD> calls it with the arguments by name), one step per
argument, in this order: C<prepare_status>, C<prepare_body>,
C<prepare_content_type>, and C<prepare_headers> last. Each step returns
its value, and C<prepare> keeps it. A step that depends on others is given
their values, after the arguments, as name/value pairs, so it never reads
a field another step may not have set yet.

A subclass with arguments of its own extends the step for the argument it
adds to, calling the class it inherits from first and returning the
value:

    sub prepare_headers ($self, $args, %prepared) {
        my $headers = $self->SUPER::prepare_headers($args, %prepared);
        push @$headers, ['location', $args->{location}];
        return $headers;
    }

=head2 prepare_status

    my $status = $response->prepare_status($args);

The status you gave, else 200. Extend it for another default.

=head2 prepare_body

    my $body = $response->prepare_body($args);

The content, rendered to bytes once, by C<render>.

=head2 prepare_content_type

    my $type = $response->prepare_content_type($args, status => $status, body => $body);

The C<content_type> you gave, C<undef> included; else the class's
C<default_content_type>, on every status. The status and body are given
for a subclass that decides from them.

=head2 prepare_headers

    my $headers = $response->prepare_headers($args,
        status => $status, body => $body, content_type => $type);

The headers the start sends, worked out once from what the other steps
prepared: your C<headers>, copied, with each name lowercased (ASCII
letters only), then the Content-Length unless you gave one (none without a
body, or on 204 and 304, which have no body), then the Content-Type unless
you gave one.

=head2 render

    my $bytes = $response->render($content);

The content as bytes, called once, when you build the response. Here,
C<undef> is an empty body, and bytes are kept as they are. Override it for a
format of your own, returning bytes: encode text first, or use
L<PAGI::Response::Text>.

=head2 default_content_type

    my $type = $response->default_content_type;

The class's type, used when you give none. Here it's C<undef>: no
Content-Type is sent. It takes no arguments. Override it for a format of
your own; a type that depends on the content is decided in
C<prepare_content_type>.

=head1 UTF-8

A response sends bytes. Text is characters, so somewhere it has to become
bytes, and we don't do that behind your back.

=head2 In the body

C<PAGI::Response> sends its content as given, so give it bytes. For text,
encode it yourself, or use L<PAGI::Response::Text>, which takes characters,
encodes them as UTF-8 and says so in its type:

    use utf8;
    use Encode ();

    PAGI::Response->new(content => Encode::encode('UTF-8', "Hello, 🌍!\n"),
        content_type => 'text/plain; charset=utf-8');
    PAGI::Response::Text->new(content => "Hello, 🌍!\n");   # the same response

For text in another charset, see L</"Text in another charset">.

=head2 In a cookie

We don't encode cookie values. A value is sent exactly as you give it, so it
must be cookie-octets (see L</set_cookie>): ASCII, with no space, C<">,
C<,>, C<;> or C<\>. Anything else croaks and tells you to encode it first.

Why not encode it for you? Because a cookie has more than one reader, and
they all have to agree on how it was encoded. Your application reads it
back; JavaScript in your page may read it from C<document.cookie>; another
service on your domain may read it too. There are several common encodings
(percent-escaping, Base64, quoting) and they aren't interchangeable. If we
picked one quietly, every one of those readers would have to know our
choice, and a value written by any other code would read back wrong. So the
choice is yours, made in your code where you can see it. A framework that
wants to encode for you can add that on top.

For text, encode it to UTF-8 bytes, then escape the bytes into
cookie-octets; to read it, undo both, in the other order. Percent-escaping
is readable, and JavaScript's C<decodeURIComponent> reads it:

    use utf8;
    use Encode ();
    use URI::Escape qw(uri_escape_utf8 uri_unescape);

    $response->set_cookie(username => uri_escape_utf8('Zoë 🌍'));
    # Set-Cookie: username=Zo%C3%AB%20%F0%9F%8C%8D; Path=/

    my $username = Encode::decode('UTF-8', uri_unescape($value));   # 'Zoë 🌍'

where C<$value> is the cookie's value as the request sent it.

For data rather than text, URL-safe Base64 is shorter, and every character
of it is a cookie-octet. L<MIME::Base64> comes with Perl, and C<encode_json>
already gives UTF-8 bytes:

    use JSON::MaybeXS qw(encode_json decode_json);
    use MIME::Base64 qw(encode_base64url decode_base64url);

    $response->set_cookie(prefs => encode_base64url(encode_json({ theme => 'dark' })));

    my $prefs = decode_json(decode_base64url($value));   # { theme => 'dark' }

See F<examples/response/cookie.pl> for a whole application that does this.

=head1 COOKBOOK

=head2 A format of your own

Override C<render> to say how your content becomes bytes, and give the
class a type. The content is rendered when you build the response, so a bad
value fails there, not halfway through a request.

If your content is text in UTF-8, subclass L<PAGI::Response::Text>
instead: it does the encoding and the charset for you (see
L<PAGI::Response::Text/SUBCLASSING>). Subclass C<PAGI::Response> when the
bytes are yours to make, as they are for text in another charset.

=head2 Text in another charset

L<PAGI::Response::Text> is UTF-8 all the way through. For another encoding,
subclass C<PAGI::Response>, which adds no charset: encode in C<render>, and
name the charset in the type, so the two agree:

    use v5.40;
    use utf8;

    package Latin1 {
        use v5.40;
        use parent 'PAGI::Response';
        use Encode ();

        sub default_content_type { 'text/plain; charset=iso-8859-1' }

        # A character Latin-1 can't hold croaks, rather than going out as '?'.
        sub render ($self, $text) {
            return Encode::encode('iso-8859-1', $text // '', Encode::FB_CROAK);
        }
    }

    my $hello = Latin1->new(content => "Grüße\n");   # 6 bytes, one for each character

=head1 SEE ALSO

L<PAGI::App>, L<PAGI::Spec::Www>

=cut
