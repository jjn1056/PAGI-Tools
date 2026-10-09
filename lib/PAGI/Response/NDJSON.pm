package PAGI::Response::NDJSON;

use strict;
use warnings;

use Carp qw(croak);
use JSON::MaybeXS ();
use parent 'PAGI::Response::Stream';

=encoding UTF-8

=head1 NAME

PAGI::Response::NDJSON - stream newline-delimited JSON, one record per item

=head1 SYNOPSIS

    use Future::AsyncAwait;
    use PAGI::Response qw(response);

    return response('NDJSON', async sub {
        my ($writer) = @_;
        $writer->on_close(sub { return $cursor->close });   # also on disconnect or cancel
        while (defined(my $person = await $cursor->next_item)) {
            await $writer->write_item($person);
        }
    });

=head1 DESCRIPTION

A L<PAGI::Response::Stream> for newline-delimited JSON. Each
C<< $writer->write_item($value) >> sends one record: the value as UTF-8 JSON,
then a newline. C<undef> is sent as C<null>. Content-Type defaults to
C<application/x-ndjson>. Backpressure, disconnects, cancellation and cleanup
are Stream's.

You could stream NDJSON from a plain Stream by writing
C<encode_json($value) . "\n"> yourself. This class packages that so producers
only write items, and is the example of a Stream format: a default content
type plus L</format_item>.

=head1 METHODS

=head2 format_item

    my $line = $response->format_item($value);

Returns C<$value> as UTF-8 JSON followed by a newline. Newlines inside strings
are escaped by JSON, so every record is one line. Object key order is not
guaranteed. Croaks C<NDJSON item encoding failed: ...> for a value JSON cannot
represent, such as a blessed object.

Also built by name: C<< response('NDJSON', $producer, %options) >> (see
L<PAGI::Response/response>); C<status>, C<content_type> and C<headers> are the
usual options.

=cut

my $JSON = JSON::MaybeXS->new(utf8 => 1);

sub default_content_type { 'application/x-ndjson' }

sub format_item {
    my ($self, $value) = @_;
    my $json;
    eval { $json = $JSON->encode($value); 1 }
        or croak "NDJSON item encoding failed: $@";
    return "$json\n";
}

1;
