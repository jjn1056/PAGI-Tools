package PAGI::Response;

use v5.24;
use warnings;
use parent 'PAGI::App';
use Carp ();
use Future::AsyncAwait;
use Class::Tiny;   # new, BUILDARGS and BUILD; the fields are this class's own

# One positional first argument is the content.
sub BUILDARGS {
    my ($class, @args) = @_;
    unshift @args, 'content' if @args % 2;
    return {@args};
}

# A response is immutable: built once, from what you give it, and only
# read after that. Everything, the headers included, is worked out here,
# once; nothing can change after, so nothing derived can go stale.
sub BUILD {
    my ($self, $args) = @_;
    $self->prepare($args);
}

# The constructor's arguments, made into the response's fields: one step
# per argument. A subclass with arguments of its own extends this, or the
# step for the argument it adds to.
sub prepare {
    my ($self, $args) = @_;
    $self->prepare_status($args);
    $self->prepare_body($args);
    $self->prepare_content_type($args);   # after the body: the default may depend on it
    $self->prepare_trailers($args);
    $self->prepare_cookies($args);
    $self->prepare_headers($args);        # last: the headers depend on all of the above
    return;
}

# The status: yours, else 200.
sub prepare_status {
    my ($self, $args) = @_;
    $self->{status} = $args->{status} // 200;
    return;
}

# The headers the start sends, worked out once: yours, copied (so changing
# your list later changes nothing) with each name lowercased (names are
# bytes, so tr changes ASCII letters only), then the body's length and the
# type unless you gave them. No length on a status that has no body (RFC
# 9110), nor with trailers, which HTTP/1.1 sends only in chunked coding, nor
# without a body.
sub prepare_headers {
    my ($self, $args) = @_;
    my @headers = map { my $name = $_->[0]; $name =~ tr/A-Z/a-z/; [$name, $_->[1]] } @{ $args->{headers} // [] };
    my %has = map { $_->[0] => 1 } @headers;
    push @headers, ['content-length', length $self->{body}]
        if defined $self->{body} && !$has{'content-length'} && !$self->{trailers}
        && !_without_content($self->{status});
    push @headers, ['content-type', $self->{content_type}]
        if defined $self->{content_type} && !$has{'content-type'};
    $self->{headers} = \@headers;
    return;
}

# The type you gave, undef included; else the class's default, except on a
# status without content (RFC 9110 15.4.5: a 304 doesn't describe a
# representation).
sub prepare_content_type {
    my ($self, $args) = @_;
    $self->{content_type} = exists $args->{content_type}  ? $args->{content_type}
                          : _without_content($self->{status}) ? undef
                          :                                  $self->default_content_type($self->{body});
    return;
}

# Whether trailers follow the body.
sub prepare_trailers {
    my ($self, $args) = @_;
    $self->{trailers} = $args->{trailers} ? 1 : 0;
    return;
}

# Cookies: none here. The step where a response takes its cookies.
sub prepare_cookies { return }

# The content, rendered to bytes once.
sub prepare_body {
    my ($self, $args) = @_;
    $self->{body} = $self->render($args->{content});
    return;
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

sub trailers {
    my $self = shift;
    _immutable('trailers') if @_;
    return $self->{trailers};
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
    Carp::croak("PAGI::Response is immutable: \$response->$name can't be set; build a new response");
}

# 204 and 304 responses cannot contain content (RFC 9110 6.4.1), nor can a
# 1xx, which is never a final response (RFC 9110 15.2).
sub _without_content {
    my ($status) = @_;
    return $status < 200 || $status == 204 || $status == 304;
}

# The content as bytes: here, as given, and no content is an empty body.
# Whether a body is bytes is checked where every send is, by the server
# (and PAGI::Test::Client), not here.
sub render {
    my ($self, $content) = @_;
    return defined $content ? $content : '';
}

# The class's type for a body: here, what RFC 9110 8.3 says a recipient may
# assume for bytes with no type, and none for an empty body. Given the body
# rather than reading it, so it can be called at any point, by anyone.
sub default_content_type {
    my ($self, $body) = @_;
    return length($body // '') ? 'application/octet-stream' : undef;
}

async sub call {
    my ($self, $scope, $receive, $send) = @_;
    await $send->({
        type    => 'http.response.start',
        status  => $self->status,
        headers => [map { [@$_] } @{ $self->headers }],   # a copy: a middleware may edit it
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

This is Starlette's C<Response>, ported. You give it content, and it
renders the body to bytes once, when you build it. Serving it sends the
start, with the Content-Length and Content-Type filled in unless you gave
them, and then the body.

Unlike Starlette's, a response can't be changed once it's built. We do that
to make it safer and simpler.

Safer, because a response is a value you build once and serve many times:
the not-found page you make at startup and return for every missing path.
If it could be changed, a handler that added something to it for one
request (a cookie, a header) would change it for every request after, and
one user's session cookie would go out to the next. Nothing here can be
changed, so that can't happen.

Simpler, because there's nothing to keep in step. Everything is decided
once, when you build it, from what you gave it, and nothing can change
after: no status that moves while its Content-Length stays put. When you
want a variation, build a new response: rendering it is the only work, and
it happens once.

Where else we differ from Starlette, it's for Perl or for PAGI. Bytes with
no type are sent as C<application/octet-stream>. We don't add a charset to the
type you give. And PAGI has trailers, so we do too.

=head1 DESCRIPTION

Use C<PAGI::Response> as it is for bytes, or for a response with no body.
For text, HTML or JSON, use the class for it. For a format of your own,
override C<render> and C<default_content_type>; for arguments of your own,
extend C<prepare> or one of its steps; see L</COOKBOOK>.

=head1 CONSTRUCTOR ARGUMENTS

    PAGI::Response->new($content, %args);
    PAGI::Response->new(content => $content, %args);

=over 4

=item content

What to send: one argument before the others is the content. It's rendered
to bytes once, by C<render>, and kept as C<body>. Here it must already be
bytes: a string with a character above 0xFF, or a reference, fails when
it's sent, as the PAGI spec has a server refuse it (L<PAGI::Test::Client>
refuses it too, so your tests see it). With none, or C<undef>, the body is
empty.

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

=head2 status, headers, content_type, trailers, body

    my $status = $response->status;

What the response was built with: C<content_type> is the one you gave,
else the class's default (none on 1xx, 204 and 304); C<body> is the
rendered content. They only read: given a value, each croaks, since a
response can't be changed (see L</RATIONALE>).

C<headers> is not only the headers you set: it's those, normalized (each
name lowercased), plus the ones worked out for you, the Content-Length and
the Content-Type. It's the list the start sends, as
C<[[name, value], ...]>. It's the response's own list, as a Moose C<ro>
attribute returns it: don't change what's in it.

=head2 call

    await $response->call($scope, $receive, $send);

The response as a PAGI application; C<to_app> returns a code reference that
calls it. It sends the start, the body as one event and, if declared, the
trailers. The start carries a copy of C<headers>, so a middleware that
changes it changes only that request.

=head2 prepare

    sub prepare ($self, $args) { ... }

Makes the constructor's arguments into the response's fields, once, when
you build it (C<BUILD> calls it with the arguments by name), one step per
argument, in this order: C<prepare_status>, C<prepare_body>,
C<prepare_content_type>, C<prepare_trailers>, C<prepare_cookies>, and
C<prepare_headers> last, since the headers depend on the rest. A subclass
with arguments of its own extends it, or the step for the argument it adds
to, calling the class it inherits from first:

    sub prepare_headers ($self, $args) {
        $self->SUPER::prepare_headers($args);
        push $self->{headers}->@*, ['location', $args->{location}];
    }

=head2 prepare_status

The status you gave, else 200. Extend it for another default.

=head2 prepare_headers

The headers the start sends, worked out once: your C<headers>, copied, with
each name lowercased (ASCII letters only), then the Content-Length unless
you gave one (none without a body, on 1xx, 204 and 304, which have no
body, or with trailers, which HTTP/1.1 sends only in chunked coding), then
the Content-Type unless you gave one.

=head2 prepare_content_type

The C<content_type> you gave, C<undef> included; else the class's
C<default_content_type>, except on a 1xx, 204 or 304 response, which has no
content to describe. It runs after C<prepare_body>, since the default may
depend on the body.

=head2 prepare_trailers

Whether C<trailers> follow the body.

=head2 prepare_cookies

Cookies: none here. It's the step where a response takes its cookies.

=head2 prepare_body

The content, rendered to bytes once, by C<render>.

=head2 render

    my $bytes = $response->render($content);

The content as bytes, called once, when you build the response. Here,
C<undef> is an empty body, and bytes are kept as they are. Override it for a
format of your own, returning bytes: encode text first, or use
L<PAGI::Response::Text>.

=head2 default_content_type

    my $type = $response->default_content_type($body);

The type for C<$body> when none is given: here, C<application/octet-stream>
when there is a body, since RFC 9110 8.3 says a recipient may assume that
anyway, and none when there isn't. It's given the body rather than reading
the response's, so it depends on nothing else having been prepared.
Override it for a format of your own.

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
