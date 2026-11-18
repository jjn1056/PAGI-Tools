package PAGI::Response::JSON;

use v5.24;
use warnings;
use parent 'PAGI::Response';
use JSON::MaybeXS ();

# The encoder the body is made with, a new one each time, so changing one changes no
# other response. UTF-8 bytes, as a body must be. allow_nonref: the body may
# be any JSON value (null, a string, a number), not only an object or an
# array, and not every backend JSON::MaybeXS picks allows that by default.
# convert_blessed: an object is sent as its TO_JSON returns, the Perl
# convention. A subclass gives its own.
sub json_encoder {
    return JSON::MaybeXS->new(utf8 => 1, allow_nonref => 1, convert_blessed => 1);
}

# The body: the content as JSON, encoded when you build the response, so
# content JSON can't carry dies there, with the encoder's error. undef is
# null.
sub prepare_body {
    my ($self, $args) = @_;
    return $self->json_encoder->encode($args->{content});
}

# JSON is UTF-8 by definition (RFC 8259), so the type names no charset.
sub default_content_type { return 'application/json' }

1;

=encoding UTF-8

=head1 NAME

PAGI::Response::JSON - a response whose content is data, sent as JSON

=head1 SYNOPSIS

An application that answers with JSON:

    use v5.40;
    use Future::AsyncAwait;
    use PAGI::Response::JSON;

    my $app = async sub ($scope, $receive, $send) {
        die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';
        my $response = PAGI::Response::JSON->new(content => { hello => 'world' });
        await $response->call($scope, $receive, $send);
    };

    $app;

A response is itself an application, so one that's the same for everyone
can be the whole file:

    use v5.40;
    use PAGI::Response::JSON;

    PAGI::Response::JSON->new(content => { status => 'ok' });

=head1 DESCRIPTION

A L<PAGI::Response> whose content is data. It's encoded as JSON, in UTF-8,
when you build the response, and its type is C<application/json> unless
you give one. Everything else, from the status and headers to C<call>, is
L<PAGI::Response>'s.

=head1 CONSTRUCTOR ARGUMENTS

As L<PAGI::Response>'s, with these differences.

=over 4

=item content

Any JSON value: a hash or array reference, a string, a number, or C<undef>
(or none) for C<null>. Strings are characters, encoded as UTF-8. An object
is sent as what its C<TO_JSON> method returns, so it decides what it
shows:

    package User { sub TO_JSON ($self) { { name => $self->{name} } } }   # not the password

It's encoded by L<JSON::MaybeXS> when you build the response, so content
JSON can't carry, a code reference say, or an object with no C<TO_JSON>,
dies at C<new> with the encoder's error. A C<TO_JSON> that dies, dies there
too, with its own error untouched.
Object members come in no particular order, so don't rely on the
bytes being the same from one run to the next.

Give it by name. A hash reference on its own is taken as the arguments, not
the content, so nothing is sent but C<null>:

    PAGI::Response::JSON->new(content => { hello => 'world' });   # {"hello":"world"}
    PAGI::Response::JSON->new({ hello => 'world' });              # null: hello isn't an argument

=item content_type

C<application/json> unless you give one. A type you give is sent as given,
C<application/problem+json> say, with no charset added.

=back

=head1 METHODS

=head2 prepare_body

    my $body = $response->prepare_body($args);

The content as JSON, in UTF-8 bytes, as described under L</content>,
encoded with L</json_encoder>.

=head2 json_encoder

    my $encoder = PAGI::Response::JSON->json_encoder;

The L<JSON::MaybeXS> object C<prepare_body> encodes with: C<utf8>,
C<allow_nonref> and C<convert_blessed>. It's a new one each time, so
changing the one you're given changes no response. A subclass that wants
its own settings, sorted keys say, gives its own:

    package SortedJSON {
        use v5.40;
        use parent 'PAGI::Response::JSON';

        sub json_encoder ($self) {
            return JSON::MaybeXS->new(utf8 => 1, allow_nonref => 1, convert_blessed => 1, canonical => 1);
        }
    }

=head2 default_content_type

    my $type = $response->default_content_type;   # 'application/json'

=head1 SEE ALSO

L<PAGI::Response>, L<PAGI::Response::Text>, L<JSON::MaybeXS>

=cut
