package PAGI::Response;

use v5.24;
use warnings;
use parent 'PAGI::App';
use Carp ();
use Future::AsyncAwait;
use Class::Tiny qw(body content_type), {
    status   => 200,
    headers  => sub { [] },
    trailers => 0,
};

# One positional first argument is the content.
sub BUILDARGS {
    my ($class, @args) = @_;
    unshift @args, 'content' if @args % 2;
    return {@args};
}

# Everything is worked out once, here: the body, then the headers the start
# sends. Serving the response sends them as they are.
sub BUILD {
    my ($self, $args) = @_;
    $self->body($self->render($args->{content}));
    # The class's default type, unless you gave one or the status has no
    # content (RFC 9110 15.4.5: a 304 doesn't describe a representation).
    $self->content_type($self->default_content_type)
        unless exists $args->{content_type} || _without_content($self->status);
    $self->headers($self->init_headers($self->headers));
}

# 204 and 304 responses cannot contain content (RFC 9110 6.4.1), nor can a
# 1xx, which is never a final response (RFC 9110 15.2).
sub _without_content {
    my ($status) = @_;
    return $status < 200 || $status == 204 || $status == 304;
}

# The content as bytes. A Perl string doesn't say whether it's bytes, so we
# refuse what can't be: a reference, or a character above 0xFF.
sub render {
    my ($self, $content) = @_;
    return '' unless defined $content;
    Carp::croak(ref($self) . ' content must be bytes: encode it first, or use PAGI::Response::Text')
        if ref $content || $content =~ /[^\x00-\xFF]/;
    return $content;
}

# Bytes with no type given are sent as what RFC 9110 8.3 says a recipient
# may assume anyway; an empty body has no type.
sub default_content_type {
    my ($self) = @_;
    return length($self->body // '') ? 'application/octet-stream' : undef;
}

# Your headers, lowercased (names are bytes: tr changes ASCII letters only),
# then the body's length and the type unless you gave them. No length on a
# status that has no body (RFC 9110), nor with trailers, which HTTP/1.1 sends
# only in chunked coding.
sub init_headers {
    my ($self, $given) = @_;
    my @headers = map { my $name = $_->[0]; $name =~ tr/A-Z/a-z/; [$name, $_->[1]] } @$given;
    my %has = map { $_->[0] => 1 } @headers;
    my $status = $self->status;
    push @headers, ['content-length', length $self->body]
        if defined $self->body && !$has{'content-length'} && !$self->trailers
        && !_without_content($status);
    push @headers, ['content-type', $self->content_type]
        if defined $self->content_type && !$has{'content-type'};
    return \@headers;
}

async sub call {
    my ($self, $scope, $receive, $send) = @_;
    await $send->({
        type    => 'http.response.start',
        status  => $self->status,
        headers => [map { [@$_] } @{ $self->headers }],   # a fresh list: a middleware may edit it
        ($self->trailers ? (trailers => 1) : ()),
    });
    await $send->({ type => 'http.response.body', body => $self->body });
    await $send->({ type => 'http.response.trailers', headers => $self->trailers_for($scope) })
        if $self->trailers;
}

# The trailers for one request, when trailers are declared: none here.
sub trailers_for { [] }

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

C<to_app> comes from L<PAGI::App>, and C<new> from L<Class::Tiny>.

=head1 RATIONALE

This is Starlette's C<Response>, ported. You give it content, and it works
out everything once, when you build it: the body, as bytes, and the headers
the start will send, with the Content-Length and Content-Type filled in
unless you gave them. Serving it sends the start and then the body. That
makes a response a value: build it once and serve it to any number of
requests.

Where we differ, it's for Perl or for PAGI. A Perl string doesn't say
whether it's bytes, so C<render> refuses what can't be. Bytes with no type
are sent as C<application/octet-stream>. We don't add a charset to the
type you give. And PAGI has trailers, so we do too.

=head1 DESCRIPTION

Use C<PAGI::Response> as it is for bytes, or for a response with no body.
For text, HTML or JSON, use the class for it. For a format of your own,
override C<render> and C<default_content_type>; see L</COOKBOOK>.

=head1 CONSTRUCTOR ARGUMENTS

    PAGI::Response->new($content, %args);
    PAGI::Response->new(content => $content, %args);

=over 4

=item content

What to send: one argument before the others is the content. It's rendered
to bytes once, by C<render>, and kept as C<body>. Here it must already be
bytes; with none, or C<undef>, the body is empty.

=item status

The status code. Defaults to 200.

=item headers

Your headers, as the PAGI spec writes them: C<[[name, value], ...]>, values
as bytes. They're copied, with each name lowercased (ASCII letters only,
since names are bytes). A C<content-type> or C<content-length> you give is
the one sent.

=item content_type

The Content-Type, when C<headers> has none. Defaults to the class's
C<default_content_type>, except on a 1xx, 204 or 304 response, which has no
content to describe. One you give is sent as given, on any status: no
charset is added, and C<undef> sends none.

=item trailers

True to send trailers after the body (L<PAGI::Spec::Www/Response Trailers>):
the start declares them, there's no Content-Length (HTTP/1.1 sends trailers
only in chunked coding), and C<trailers_for> gives them. Defaults to false.

=back

=head1 METHODS

=head2 body, status, headers, content_type, trailers

The rendered body, and what the response was built with. C<headers> is the
list the start sends: yours, then the Content-Length and Content-Type
worked out for you. A response is a value you may share between requests,
so set these when you build it, not while it's being served.

=head2 call

    await $response->call($scope, $receive, $send);

The response as a PAGI application; C<to_app> returns a code reference that
calls it. It sends the start, the body as one event and, if declared, the
trailers. Each start gets its own copy of the headers, so a middleware that
changes them changes only that request.

=head2 render

    my $bytes = $response->render($content);

The content as bytes, called once, when you build the response. Here,
C<undef> is an empty body, and bytes are kept as they are; a reference or a
character above 0xFF croaks (encode it first, or use
L<PAGI::Response::Text>). Override it for a format of your own.

=head2 default_content_type

The type when none is given: here, C<application/octet-stream> when there
is a body, since RFC 9110 8.3 says a recipient may assume that anyway, and
none when there isn't.

=head2 init_headers

    my $headers = $response->init_headers($given);

The headers the start sends, worked out once, when you build the response:
the ones given, lowercased, then the Content-Length unless one was given
(none on 1xx, 204 and 304, which have no body, nor with trailers), then the
Content-Type unless one was given (the class's default isn't used on 1xx,
204 and 304; see L</content_type>).

=head2 trailers_for

    sub trailers_for ($self, $scope) { [[name, value], ...] }

The trailers for one request, when C<trailers> is declared: none here.

=head1 COOKBOOK

=head2 A format of your own

Override C<render> to say how your content becomes bytes, and give the
class a type. The content is rendered when you build the response, so a bad
value fails there, not halfway through a request:

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

=head2 Trailers

Trailers are headers sent after the body. For a buffered body, give them
with C<trailers_for>, which runs for each request:

    package Signed {
        use v5.40;
        use parent 'PAGI::Response';
        use Digest::SHA qw(sha256_hex);

        sub trailers_for ($self, $scope) { [['x-checksum', 'sha256=' . sha256_hex($self->body)]] }
    }

    my $download = Signed->new("%PDF-1.7 ...", content_type => 'application/pdf', trailers => 1);

Many clients, browsers among them, don't show trailers to the application,
so don't put anything there a client can't do without.

=head1 SEE ALSO

L<PAGI::App>, L<PAGI::Spec::Www>

=cut
