package PAGI::Response::Text;

use v5.24;
use warnings;
use parent 'PAGI::Response';
use Carp ();
use Encode ();
use overload ();

# The content as UTF-8 bytes: made into text, then encoded.
sub render {
    my ($self, $content) = @_;
    return $self->encode_text($self->as_text($content));
}

# The content as characters: no content is empty, and an object that
# stringifies is its string. Any other reference isn't text.
sub as_text {
    my ($self, $content) = @_;
    return '' unless defined $content;
    Carp::croak('content must be text: pass a string, or an object that stringifies')
        if ref $content && !overload::Method($content, '""');
    return "$content";
}

# Characters as UTF-8 bytes. A character UTF-8 can't carry (a lone
# surrogate) dies with Encode's error rather than being sent as a substitute.
sub encode_text {
    my ($self, $text) = @_;
    return Encode::encode('UTF-8', $text, Encode::FB_CROAK);
}

# The type, saying the body is UTF-8: a text/* type that names no charset
# gets one, as Starlette's does. Any other type, or none, is as given. A
# Content-Type you put in headers is yours, and sent untouched.
sub prepare_content_type {
    my ($self, $args, %prepared) = @_;
    my $type = $self->SUPER::prepare_content_type($args, %prepared);
    return $type unless defined $type && $type =~ m{\Atext/} && $type !~ /charset=/i;
    return "$type; charset=utf-8";
}

# The body is UTF-8, and plain text unless you say otherwise.
sub default_content_type { return 'text/plain; charset=utf-8' }

1;

=encoding UTF-8

=head1 NAME

PAGI::Response::Text - a response whose content is text, sent as UTF-8

=head1 SYNOPSIS

An application that answers with text:

    use v5.40;
    use utf8;   # the characters in this file are characters, not bytes
    use Future::AsyncAwait;
    use PAGI::Response::Text;

    my $app = async sub ($scope, $receive, $send) {
        die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';
        my $response = PAGI::Response::Text->new(content => "Hello, 🌍\n");
        await $response->call($scope, $receive, $send);
    };

    $app;

A response is itself an application, so one that's the same for everyone
can be the whole file:

    use v5.40;
    use utf8;
    use PAGI::Response::Text;

    PAGI::Response::Text->new(content => "Hello, 🌍\n");

Serve either with C<pagi-server --app hello.pl>.

=head1 DESCRIPTION

A L<PAGI::Response> whose content is characters. They're encoded as UTF-8
when you build the response, and its type is
C<text/plain; charset=utf-8> unless you give one. Everything else, from the
status and headers to C<call>, is L<PAGI::Response>'s.

=head1 CONSTRUCTOR ARGUMENTS

As L<PAGI::Response>'s, with these differences.

=over 4

=item content

Characters, encoded as UTF-8 when you build the response; C<undef>, or none,
is an empty body. An object that overloads stringification is its string.
Any other reference dies at C<new>, as does a character UTF-8 can't carry (a
lone surrogate such as C<"\x{D800}">): the response is never sent with a
substitute in its place.

Give characters, not bytes you've encoded already: those would be encoded a
second time. For bytes, use L<PAGI::Response>.

=item content_type

The body is UTF-8, and the type says so: a C<text/*> type that names no
charset gets C<; charset=utf-8>, as Starlette's does, so C<text/csv> is sent
as C<text/csv; charset=utf-8>. With none given, it's
C<text/plain; charset=utf-8>. Any other type (C<application/xml>, say) is
sent as given, and so is C<undef>, which sends none. A Content-Type you put
in C<headers> is yours, and sent untouched.

Text always sends UTF-8. A type that names another charset is sent as
given, but the body is still UTF-8, so the two disagree. For text in another
encoding, see L</"Another charset">.

=back

=head1 METHODS

=head2 render

    my $bytes = $response->render($content);

The content as UTF-8 bytes, as described under L</content>: C<encode_text>
of C<as_text>. Override either of those rather than this.

=head2 as_text

    my $text = $response->as_text($content);

The content as characters: C<undef> is empty, and an object that overloads
stringification is its string. Any other reference dies. A format whose
content isn't a string overrides this to make the text; see
L</A text format of your own>.

=head2 encode_text

    my $bytes = $response->encode_text($text);

The characters as UTF-8 bytes. A character UTF-8 can't carry, a lone
surrogate such as C<"\x{D800}">, dies with L<Encode>'s error. A subclass
that wants something else, a replacement character say, overrides this;
the body must still be UTF-8 (see L</Another charset>).

=head2 prepare_content_type

The type you gave, else the class's, with the charset added to a C<text/*>
type as described under L</content_type>.

=head2 default_content_type

    my $type = $response->default_content_type;   # 'text/plain; charset=utf-8'

=head1 SUBCLASSING

=head2 A text format of your own

Text is the base for any format whose content is text: subclass it and set
C<default_content_type>, and the encoding and the charset are done for you.
To take something other than a string, override C<as_text> to make the
text, and Text encodes it:

    package CSV {
        use v5.40;
        use parent 'PAGI::Response::Text';

        sub default_content_type { 'text/csv' }   # sent as text/csv; charset=utf-8

        sub as_text ($self, $rows) {
            return join '', map { join(',', @$_) . "\r\n" } @$rows;
        }
    }

    my $report = CSV->new(content => [['id', 'name'], [1, 'Ada']]);

=head2 Another charset

Text is UTF-8 all the way through: even a subclass that encoded some other
way would still have C<; charset=utf-8> added to a type given without one.
For text in another encoding, subclass L<PAGI::Response> instead. It adds no
charset, so you encode in C<render> and name the charset in the type; see
L<PAGI::Response/"Text in another charset">.

=head1 SEE ALSO

L<PAGI::Response>, L<PAGI::Response::JSON>

=cut
