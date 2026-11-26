package PAGI::Response::NDJSON;

use v5.24;
use warnings;
use parent 'PAGI::Response::Stream';
use PAGI::Response::JSON;

sub default_content_type { return 'application/x-ndjson' }

# JSON's settings, so the two formats encode alike.
sub json_encoder { return PAGI::Response::JSON->json_encoder }

# JSON's encoding, and its error when an item isn't plain data.
sub format_item {
    my ($self, $item) = @_;
    return PAGI::Response::JSON::_encode($self->json_encoder, $item) . "\n";
}

1;

=encoding UTF-8

=head1 NAME

PAGI::Response::NDJSON - a stream of JSON values, one a line

=head1 SYNOPSIS

    use v5.40;
    use Future::AsyncAwait;
    use PAGI::Response::NDJSON;

    my $app = async sub ($scope, $receive, $send) {
        die "unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'http';
        my $response = PAGI::Response::NDJSON->new(body => async sub ($writer) {
            while (defined(my $person = await $cursor->next)) {
                await $writer->write_item($person);    # one line of JSON
            }
        });
        await $response->call($scope, $receive, $send);
    };

    $app;

=head1 DESCRIPTION

A L<PAGI::Response::Stream> for newline-delimited JSON. Each
C<< $writer->write_item($value) >> sends the value as JSON, encoded as UTF-8,
then a newline. JSON escapes a newline inside a string, so each value is one
line, and C<undef> is C<null>. The type is C<application/x-ndjson> unless you
give one. Everything else, the body, the writer, the end and C<on_close>, is
Stream's.

Items are plain data, as L<PAGI::Response::JSON>'s content is: an object,
whatever methods it has, or a code reference, dies in the body with JSON's
message, and the stream ends C<failed>, as any body that dies does. Turn an
object into data before you write it, or give the response an encoder that
converts objects (L</json_encoder>).

NDJSON is also Stream's example of a format: a default type and a
C<format_item>. See L<PAGI::Response::Stream/SUBCLASSING> to make one of your
own.

=head1 METHODS

=head2 format_item

    my $line = $response->format_item($value);

C<$value> as JSON from C<json_encoder>, then a newline.

=head2 json_encoder

    my $encoder = $response->json_encoder;

The JSON encoder, the same one L<PAGI::Response::JSON> uses: UTF-8 output,
any JSON value (not only objects and arrays), and no object conversion.
Object keys come out in no particular order. To change the settings, sorted
keys or a JSON module of your choosing say, override it, as described under
L<PAGI::Response::JSON/json_encoder>:

    package Sorted::NDJSON {
        use v5.40;
        use parent 'PAGI::Response::NDJSON';
        use JSON::MaybeXS ();
        sub json_encoder ($self) { JSON::MaybeXS->new(utf8 => 1, canonical => 1) }
    }

=head2 default_content_type

    my $type = $response->default_content_type;   # 'application/x-ndjson'

=head1 SEE ALSO

L<PAGI::Response::Stream>, L<PAGI::Response::JSON>

=cut
