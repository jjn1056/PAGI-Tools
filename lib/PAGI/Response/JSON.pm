package PAGI::Response::JSON;

use v5.24;
use warnings;
use parent 'PAGI::Response';

# The encoder the body is made with, a new one each time, so changing one changes no
# other response. UTF-8 bytes, as a body must be. allow_nonref: the body may
# be any JSON value (null, a string, a number), not only an object or an
# array, and not every backend JSON::MaybeXS picks allows that by default.
# No object conversion: content is plain data, and an object dies, on every
# backend. (convert_blessed would try TO_JSON, but Cpanel::JSON::XS then
# sends the first object of a class without one as null.) JSON::MaybeXS is
# loaded here, not when the class is, so a subclass with an encoder of its
# own needn't have it.
sub json_encoder {
    require JSON::MaybeXS;
    return JSON::MaybeXS->new(utf8 => 1, allow_nonref => 1);
}

# The body: the content as JSON, encoded when you build the response, so
# content JSON can't carry dies there. undef is null.
sub prepare_body {
    my ($self, $args) = @_;
    return $self->encode_json($args->{content});
}

# Data as JSON, with json_encoder. A failure is the encoder's own error;
# a subclass that wants to say more, or something else, overrides this.
sub encode_json {
    my ($self, $data) = @_;
    return $self->json_encoder->encode($data);
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

Plain data: a hash or array reference, a string, a number, a boolean
(C<JSON::MaybeXS::true> and C<false>, or C<\1> and C<\0>), or C<undef> (or
none) for C<null>, nested as deep as you like. Strings are characters,
encoded as UTF-8. Object members come in no particular order, so don't rely
on the bytes being the same from one run to the next.

An object isn't data, so it dies at C<new>, the same on every JSON backend,
with the encoder's own error: JSON doesn't call its C<TO_JSON> or use its
string. Turn it into data yourself, saying what it shows:

    PAGI::Response::JSON->new(content => { user => { name => $user->name } });   # not the password

Nothing is coerced because there's no way to do it that's the same
everywhere: with object conversion turned on, whether an object without a
C<TO_JSON> is sent as its string, as C<null>, or dies depends on the
backend L<JSON::MaybeXS> picks, and Cpanel::JSON::XS sends the first one of
a class as C<null> and dies on the next. With it off, as here, every object
dies, on every backend. To send objects anyway, give your response an
encoder that converts them; see L</json_encoder>.

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

The content as JSON, in UTF-8 bytes, as described under L</content>, from
L</encode_json>.

=head2 encode_json

    my $json = $response->encode_json($data);

C<$data> as JSON, with L</json_encoder>. Every body is encoded through it.
When the encoder fails, it dies with the encoder's own error, which names
what it couldn't encode. A subclass that wants to say more, or handle the
failure some other way, overrides it:

    package FriendlyJSON {
        use v5.40;
        use parent 'PAGI::Response::JSON';

        sub encode_json ($self, $data) {
            my $json = eval { $self->SUPER::encode_json($data) };
            return $json if defined $json;
            die "Send plain data: flatten objects first ($@)";
        }
    }

=head2 json_encoder

    my $encoder = PAGI::Response::JSON->json_encoder;

The L<JSON::MaybeXS> object L</encode_json> encodes with: C<utf8> and
C<allow_nonref>. It's a new one each time, so changing the one you're given
changes no response. JSON::MaybeXS is loaded when this is called, not when
the class is, so a subclass with an encoder of its own needn't have it. A
subclass that wants its own settings, sorted keys say, gives its own:

    package SortedJSON {
        use v5.40;
        use parent 'PAGI::Response::JSON';
        use JSON::MaybeXS ();

        sub json_encoder ($self) {
            return JSON::MaybeXS->new(utf8 => 1, allow_nonref => 1, canonical => 1);
        }
    }

That's also how you choose the JSON module, which JSON::MaybeXS picks for
you (Cpanel::JSON::XS if it's installed, else JSON::PP, with no setting to
change that), and how you send objects. An encoder that converts objects is
yours, and so are its quirks: with C<< convert_blessed => 1 >>, an object
is sent as its C<TO_JSON> returns, but under Cpanel::JSON::XS the first
object of a class without one is sent as C<null>. JSON::PP dies on it every
time:

    package ObjectJSON {
        use v5.40;
        use parent 'PAGI::Response::JSON';
        use JSON::PP ();

        sub json_encoder ($self) {
            return JSON::PP->new->utf8->allow_nonref->convert_blessed;
        }
    }


=head2 default_content_type

    my $type = $response->default_content_type;   # 'application/json'

=head1 SEE ALSO

L<PAGI::Response>, L<PAGI::Response::Text>, L<JSON::MaybeXS>

=cut
