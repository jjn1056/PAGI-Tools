package PAGI::Response;

use v5.24;
use warnings;
use parent 'PAGI::App';
use Carp ();
use Future;
use Future::AsyncAwait;
use Class::Tiny qw(body), {
    status       => 200,
    headers      => sub { [] },
    trailers     => 0,
    content_type => sub { $_[0]->default_content_type },
};

# One positional first argument is the content.
sub BUILDARGS {
    my ($class, @args) = @_;
    unshift @args, 'content' if @args % 2;
    return {@args};
}

sub BUILD {
    my ($self, $args) = @_;
    # Rendered once, here, so a bad value fails on the line that built the
    # response; only the bytes are kept. What render returns is checked
    # whatever class wrote it. Undefined content is no content.
    my $body = '';
    # Whether there is content to know the length of: a class that sends a
    # body of its own gives none, so it never claims a length by accident.
    $self->{_has_content} = defined $args->{content};
    if (defined $args->{content}) {
        $body = $self->render($args->{content});
        Carp::croak(ref($self) . ' render returned undef') unless defined $body;
        $self->_must_be_bytes($body);
    }
    $self->body($body);
    # Copied, because cookies are added to it, and lowercased (Www.pod: names
    # MUST be lowercase). Names are bytes: tr changes ASCII letters only.
    $self->headers(_lowercase_names($self->headers));
    # A content-length that promises a body this status can't have would leave
    # an HTTP/1.1 client waiting for bytes that never come (RFC 9110 8.6). A
    # 304 may still say the length the full response would have had.
    my ($length) = map { $_->[1] } grep { $_->[0] eq 'content-length' } @{ $self->headers };
    if (defined $length) {
        my $status = $self->status;
        # Over HTTP/1.1 trailers need chunked coding; the server fails the send.
        Carp::croak("a response with trailers can't have a content-length: HTTP/1.1 sends trailers only in chunked coding")
            if $self->trailers && !$self->no_content_status;
        Carp::croak("a $status response has no body, so it can't have a content-length")
            if $status < 200 || $status == 204;
        Carp::croak("a 205 response has no body: its content-length must be 0, not $length")
            if $status == 205 && $length ne '0';
        # Content you gave has a known length: a header that disagrees would
        # hang an HTTP/1.1 client or cut the body short. (A 304 may state the
        # full length; with no content, the body and its promise are a
        # subclass's own.)
        Carp::croak("the content-length header says $length but the body is " . length($self->body) . ' bytes')
            if !$self->no_content_status && $self->{_has_content} && $length ne length $self->body;
    }
}


# The content as bytes: here, bytes as given. A representation (Text, JSON)
# overrides encode_chunk, and render is built on it, so a format already
# means "encode what you pull".
sub render {
    my ($self, $content) = @_;
    return $self->encode_chunk($content);
}

sub encode_chunk {
    my ($self, $chunk) = @_;
    $self->_must_be_bytes($chunk);
    return $chunk;
}

sub _must_be_bytes {
    my ($self, $bytes) = @_;
    Carp::croak(ref($self) . ' content must be a string, not a ' . ref($bytes) . ' reference') if ref $bytes;
    Carp::croak(ref($self) . ' content must be bytes: it has a character above 0xFF; encode it first, or use PAGI::Response::Text')
        if $bytes =~ /[^\x00-\xFF]/;
}

# The type and length of the buffered body: octet-stream for bytes with no
# type given (RFC 9110 8.3), none for an empty body; the length of the
# content given, or unknown when there was none, so the server frames it.
# A class that knows the length of a body of its own (File) overrides it.
sub default_content_type {
    my ($self) = @_;
    return undef unless length $self->body;
    return 'application/octet-stream';
}

sub content_length {
    my ($self) = @_;
    return $self->{_has_content} ? length $self->body : undef;
}

# The body: the buffered one, as one event, then its trailers if declared.
# Stream and File override this.
async sub send_body {
    my ($self, $scope, $receive, $send) = @_;
    await $send->({ type => 'http.response.body', body => $self->body, more => 0 });
    await $send->({ type => 'http.response.trailers', headers => $self->trailers_for($scope) })
        if $self->trailers;
}

# The buffered body's trailers, per request: none unless a subclass says.
sub trailers_for { [] }

# Lowercased like the headers; names are bytes.
sub _lowercase_names {
    my ($pairs) = @_;
    return [ map { my $name = $_->[0]; $name =~ tr/A-Z/a-z/; [$name, $_->[1]] } @$pairs ];
}

# 1xx, 204, 205 and 304 carry no content (RFC 9110).
sub no_content_status {
    my ($self) = @_;
    my $status = $self->status;
    return $status < 200 || $status == 204 || $status == 205 || $status == 304;
}

# The header rules, in one place: no content-type or content-length on 1xx,
# 204 and 304; content-length 0 on 205; otherwise the content type unless the
# headers carry one, and the length when known and not given. A new list each
# call, so sending never changes the response.
sub response_headers {
    my ($self, $length) = @_;
    my @headers = map { [@$_] } @{ $self->headers };
    my %has = map { $_->[0] => 1 } @headers;
    my $status = $self->status;
    return \@headers if $status < 200 || $status == 204 || $status == 304;
    $length = 0 if $status == 205;
    $length = undef if $self->trailers;
    push @headers, ['content-type', $self->content_type]
        if defined $self->content_type && !$has{'content-type'};
    push @headers, ['content-length', $length]
        if defined $length && !$has{'content-length'};
    return \@headers;
}

# The response as a PAGI application. The start goes out just before the
# first body event send_body sends, so a subclass can do its work first and
# a failure before then leaves call with nothing sent: the server, or a
# framework, sends a clean 500.
async sub call {
    my ($self, $scope, $receive, $send) = @_;
    die "Unsupported scope type: $scope->{type}\n"
        unless $scope->{type} =~ /\A(?:http|websocket|sse)\z/;
    # The start's Future, kept: every send waits for it, so sends that overlap
    # (Www.pod "Sends Are Sequential") reach the server in the order they were made.
    my $started;
    my $start = sub { $started //= $self->send_start($send, $self->content_length) };
    if ($self->no_content_status) {
        await $start->();
        return await $send->({ type => 'http.response.body', body => '', more => 0 });
    }
    my ($sent_body, $body_done, $sent_trailers, @waiting);
    # A plain sub, not an async one: its checks run in the caller's own frame,
    # so an error names the subclass's line. Once the start is out, the event
    # goes to the server at once, as in raw PAGI. Before then it waits on the
    # start's Future, and Futures run their callbacks in order, so sends keep
    # call order; those waiting sends are kept, so one whose Future the
    # subclass drops is still sent.
    await $self->send_body($scope, $receive, sub {
        my ($event) = @_;
        my $refuse = sub { my (undef, $file, $line) = caller 1; die "$_[0] at $file line $line.\n" };
        my $type = $event->{type};
        $refuse->('PAGI::Response sends the start; send_body sends only body events')
            if $type eq 'http.response.start';
        $refuse->('a body event after the trailers: the trailers end the response')
            if $sent_trailers && $type eq 'http.response.body';
        if ($type eq 'http.response.trailers') {
            $refuse->('trailers sent, but none were declared: build the response with trailers => 1')
                unless $self->trailers;
            $refuse->('trailers already sent: a response has one trailers event') if $sent_trailers;
            $refuse->("trailers before the body's last event: send it with more => 0 first") unless $body_done;
            $sent_trailers++;
            $event = { %$event, headers => _lowercase_names($event->{headers} // []) };
        }
        elsif ($type eq 'http.response.body') {
            $sent_body++;
            # A file or fh event is complete on its own (Www.pod "Response Body").
            $body_done = !$event->{more} || exists $event->{file} || exists $event->{fh};
        }
        return $send->($event) if $started && $started->is_done;
        my $sent = $start->()->then(sub { $send->($event) });
        push @waiting, $sent;
        return $sent;
    });
    await Future->needs_all(@waiting) if @waiting;
    return if $sent_trailers || ($body_done && !$self->trailers);
    # The client gone: stopping early is no error, and there's no one to tell.
    my $connection = $scope->{'pagi.connection'};
    return if $connection && !$connection->is_connected;
    # A terminal event is a claim that the response is complete, so we never
    # make one up for a body send_body started: the response is left
    # incomplete, for the server to end as truncated (Www.pod "Application
    # Left a Response Incomplete").
    die ref($self) . " send_body returned with the body unfinished: its last event had more => 1\n"
        if $sent_body && !$body_done;
    die ref($self) . " send_body returned without the trailers it declared: send one http.response.trailers event last\n"
        if $sent_body;
    # A send_body that sent nothing started nothing: its response is empty.
    await $start->();
    await $send->({ type => 'http.response.body', body => '', more => 0 });
    await $send->({ type => 'http.response.trailers', headers => [] }) if $self->trailers;
}

sub send_start {
    my ($self, $send, $length) = @_;
    return $send->({
        type    => 'http.response.start',
        ($self->trailers && !$self->no_content_status ? (trailers => 1) : ()),
        status  => $self->status,
        headers => $self->response_headers($length),
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
    my $logo  = PAGI::Response->new(do { local $/; <$fh> }, content_type => 'image/png');
    my $empty = PAGI::Response->new(status => 204);

    # A format of your own: say how content becomes bytes.
    package CSV {
        use v5.40;
        use parent 'PAGI::Response';
        use Encode ();

        sub default_content_type { 'text/csv; charset=utf-8' }

        sub render ($self, $rows) {
            Encode::encode('UTF-8', join '', map { join(',', @$_) . "\r\n" } @$rows);
        }
    }

    my $report = CSV->new([[1, 2], [3, 4]]);   # each is an application: serve it, or call it from yours

=head1 INHERITANCE

    PAGI::Response
      PAGI::App
        Class::Tiny::Object

Text, JSON, Stream, File and the other responses add themselves to the top.
C<to_app> comes from L<PAGI::App>, and C<new> from L<Class::Tiny>.

=head1 RATIONALE

A PAGI HTTP response is two things in order: one C<http.response.start>
event, with the status and headers, and then the body events. We split this
class the same way.

The start is always ours. The rules every response has to get right live in
one place: the statuses that carry no body (1xx, 204, 205, 304), when to send
a Content-Type and a Content-Length, lowercase header names, and trailers.

The body is C<send_body>, and it's the one method a different kind of
delivery overrides. Here it sends a buffered body: the content you gave,
rendered to bytes once, when you built the response, and sent as one event.
That's the common case, so it's the base. A stream overrides C<send_body> to
send many events, and a file to send the spec's C<file> event, and neither
touches the start.

If you know Starlette, this is its shape, with that one change. Starlette's
C<Response> is buffered too, but its streaming and file responses replace the
whole call, so each repeats the start and everything that touches it.

We send the start lazily: just before the first body event. That lets a
response do its work first, pulling a first chunk or opening a file, and if
that work fails, nothing has gone out yet, so the server or your framework
can still send a clean 500.

A response is a value. You can build one once and serve it to any number of
requests: C<send_body> runs per request, and sending never changes the
object. That's why it isn't the base of L<PAGI::WebSocket> or L<PAGI::SSE>:
those hold the state of one connection.

=head1 DESCRIPTION

Use C<PAGI::Response> as it is for bytes, or for a response with no body.
For text, HTML or JSON, use the class for it. To write your own, override
C<render> (or C<encode_chunk>) for a format, and C<send_body> for a delivery;
see L</COOKBOOK>.

=head1 CONSTRUCTOR ARGUMENTS

    PAGI::Response->new($content, %args);
    PAGI::Response->new(content => $content, %args);

=over 4

=item content

What to send. One argument before the others is the content. It's rendered
to bytes once, by C<render>, when you build the response, so a value that
can't be sent fails on the line that built it; only the bytes are kept, as
L</body>. Here it must already be bytes: a string with a character above
0xFF croaks (encode it first, or use L<PAGI::Response::Text>), as does a
reference. With no content, or undefined content, the body is empty and its
length unknown; give C<''> for an empty body with a C<content-length> of 0.

=item status

The status code. Defaults to 200.

=item headers

The headers, as the PAGI spec writes them: C<[[name, value], ...]>, values
as bytes. The list is copied, and each name lowercased (ASCII letters only,
since names are bytes). A C<content-type> or C<content-length> given here is
sent as given. A C<content-length> that would leave a client waiting for
bytes that never come croaks: one that disagrees with the content you gave,
any on a 1xx
or 204, one other than 0 on a 205, and any when trailers are declared. A 304
may carry the length the full response would have had (RFC 9110 8.6).

=item content_type

The Content-Type. Defaults to the class's C<default_content_type>. A
C<content-type> in C<headers> wins over this.

=item trailers

True to send trailers after the body. The start then declares them and
carries no Content-Length, since HTTP/1.1 can send trailers only in chunked
coding. Defaults to false. See L</Trailers>.

=back

=head1 METHODS

=head2 status, headers, content_type, trailers

    my $status  = $response->status;
    my $headers = $response->headers;        # [[name, value], ...], names lowercase
    my $type    = $response->content_type;

What the response was built with (see L</CONSTRUCTOR ARGUMENTS>);
C<content_type> is the class's default when none was given. A response is a
value you may share between requests, so set these when you build it, not
while it's being served.

=head2 body

    my $bytes = $response->body;

The rendered content: what the buffered body sends. C<''> with no content.

=head2 call

    await $response->call($scope, $receive, $send);

The response as a PAGI application; C<to_app> returns a code reference that
calls it. It answers C<http> scopes, and C<websocket> and C<sse> scopes too,
where an HTTP response is the spec's way to refuse the connection. Any other
scope dies C<Unsupported scope type: ...>.

For a status that carries no body (1xx, 204, 205, 304) it sends the start
and an empty final body event, and never calls C<send_body>. Otherwise it
calls C<send_body> and sends the start just before the first event that
sends. Sends keep the order they were made in, even ones you don't await.
If C<send_body> sends nothing, the response is empty: the start, an empty
body and, if declared, empty trailers. But we never finish a body
C<send_body> started: a last event is a claim that the body is complete, so
if it returns with the body open, or without the trailers it declared,
C<call> fails, and the server ends the response as truncated, which the
client can see (L<PAGI::Spec::Www/Application Left a Response Incomplete>).
If the client has already gone, nothing more is sent, and stopping early is
no error.

=head2 send_body

    async sub send_body ($self, $scope, $receive, $send) { ... }

Sends the body, through C<$send>, and returns a Future. Here it sends
L</body> as one C<http.response.body> event with C<< more => 0 >>, then,
with C<trailers> declared, the trailers L</trailers_for> gives.

Override it for a different delivery. Send C<http.response.body> events,
the last with C<< more => 0 >> (an event with C<file> or C<fh> is complete
on its own), and then, with C<trailers> declared, one
C<http.response.trailers> event. The start is ours: sending one croaks, as
do trailers that weren't declared, a second trailers event, trailers before
the body's last event, and a body event after the trailers. Each croak names
your line.

A class that sends a body of its own gives no content, so its length is
unknown and the server frames the body; if it does know the length (a
file's size), it overrides C<content_length>. It gives its own
C<default_content_type> too, since the base's describes L</body>.

=head2 render

    my $bytes = $response->render($content);

The content as bytes, called once, when you build the response. Here it's
C<encode_chunk> of the content. Override it for a format that needs the
whole value at once, such as JSON. What it returns must be bytes, whoever
wrote it: C<undef>, a reference or a character above 0xFF croaks.

=head2 encode_chunk

    my $bytes = $response->encode_chunk($chunk);

One piece of content as bytes. Here: bytes as given, croaking on a
reference or a character above 0xFF. Override it for a format that can
encode piece by piece, such as text, and C<render> uses it.

=head2 trailers_for

    sub trailers_for ($self, $scope) { [[name, value], ...] }

The buffered body's trailers, per request, when C<trailers> is declared.
None here. Names are lowercased as they're sent.

=head2 default_content_type

The class's Content-Type when none is given. Here,
C<application/octet-stream> when there is a body, since bytes with no type
are what RFC 9110 8.3 says a recipient may assume anyway, and C<undef> (no
header) when there isn't.

=head2 content_length

The body's length in bytes, or C<undef> if the class doesn't know it: here,
the length of L</body> when you gave content, and C<undef> when you didn't,
so the server frames the body itself (chunked, over HTTP/1.1). It's asked just before the start goes out, so a class that sends
its own body can report something that changes between requests, such as a
file's size.

=head2 no_content_status

True when the status carries no body: 1xx, 204, 205 or 304.

=head2 response_headers

    my $headers = $response->response_headers($length);

The headers the start sends, given the body's length (or C<undef>): the
headers you gave, then the Content-Type unless one was given, then the
Content-Length when known, not given, and no trailers are declared. No
Content-Type or Content-Length on 1xx, 204 and 304, and a length of 0 on
205 (RFC 9110). A new list each call.

=head2 send_start

    await $response->send_start($send, $length);

Sends the C<http.response.start> event. C<call> does this for you.

=head1 COOKBOOK

=head2 A format of your own

Override C<render> to say how your content becomes bytes, and give the
class a type. The content is rendered when you build the response, and what
C<render> returns must be bytes, so a bad value fails there, not halfway
through a request:

    package CSV {
        use v5.40;
        use parent 'PAGI::Response';
        use Encode ();

        sub default_content_type { 'text/csv; charset=utf-8' }

        sub render ($self, $rows) {
            Encode::encode('UTF-8', join '', map { join(',', @$_) . "\r\n" } @$rows);
        }
    }

    my $report = CSV->new([['id', 'name'], [1, 'Ada']]);

=head2 A delivery of your own

Override C<send_body> when the body isn't one buffer. Do the work that can
fail before your first C<$send>: if it dies there, nothing has been sent,
and the caller gets a clean 500 rather than half a response.

    package Quote {
        use v5.40;
        use parent 'PAGI::Response';
        use Class::Tiny qw(file);
        use Future::AsyncAwait;

        sub default_content_type { 'text/plain; charset=utf-8' }

        async sub send_body ($self, $scope, $receive, $send) {
            open my $fh, '<:raw', $self->file or die "Can't read the quotes: $!\n";
            my @quotes = <$fh>;
            await $send->({ type => 'http.response.body', body => $quotes[rand @quotes], more => 0 });
        }
    }

    Quote->new(file => '/srv/quotes.txt');

=head2 Trailers

Trailers are headers sent after the body, for what you only know once it's
sent: a checksum, a count, a status. Declare them with C<< trailers => 1 >>,
and send them last:

    package Lines {
        use v5.40;
        use parent 'PAGI::Response';
        use Class::Tiny qw(lines);
        use Future::AsyncAwait;

        sub default_content_type { 'text/plain' }

        async sub send_body ($self, $scope, $receive, $send) {
            my $count = 0;
            for my $line ($self->lines->@*) {
                await $send->({ type => 'http.response.body', body => "$line\n", more => 1 });
                $count++;
            }
            await $send->({ type => 'http.response.body', body => '', more => 0 });
            await $send->({ type => 'http.response.trailers', headers => [['x-line-count', $count]] });
        }
    }

    Lines->new(lines => ['one', 'two'], trailers => 1);

For a buffered body, override C<trailers_for> instead. Many clients, browsers
among them, don't show trailers to the application, so don't put anything
there a client can't do without.

=head1 SEE ALSO

L<PAGI::App>, L<PAGI::Spec::Www>

=cut
