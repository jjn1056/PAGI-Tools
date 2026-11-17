package PAGI::Response;

use v5.24;
use warnings;
use parent 'PAGI::App';
use Carp ();
use Future;
use Class::Tiny;   # new, BUILDARGS and BUILD; the fields are this class's own

# A response is immutable: built once, from what you give it, and only
# read after that. Everything, the headers included, is worked out here,
# once; nothing can change after, so nothing derived can go stale.
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
# the ones worked out for you (Content-Length, Content-Type). This is what
# the start sends. The response's own list, as a Moose 'ro' attribute
# returns it: don't change it.
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
rest: once you've built a response, it can't be changed.

Starlette works a response out when you build it, then lets you keep
changing it, so what it worked out can fall behind: change the body after
and the Content-Length is wrong. We decide everything once, when you build
it, from what you gave it: the status, the headers, the body's bytes, its
Content-Length and its Content-Type. Nothing changes after, so nothing has
to be checked again when it's sent, and nothing can go stale. When you want
something different, build a new one.

So everything goes to C<new>, cookies included. Starlette adds a cookie with
C<set_cookie> after the response is built; here a cookie is a header you
give, from L<PAGI::Cookie>:

    PAGI::Response::Text->new(
        content => "Welcome back\n",
        headers => [ $cookie->header ],
    );

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
attribute returns it: don't change what's in it.

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
