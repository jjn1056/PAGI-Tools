package PAGI::Response::NDJSON;

use strict;
use warnings;

use Carp qw(croak);
use Exporter qw(import);
use parent 'PAGI::Response::Stream';
use PAGI::Response::NDJSON::Writer ();

=encoding UTF-8

=head1 NAME

PAGI::Response::NDJSON - reusable backpressured newline-delimited JSON response

=head1 SYNOPSIS

    use Future::AsyncAwait;
    use PAGI::Response qw(ndjson_response);

    return ndjson_response(async sub ($writer) {
        my $cursor = await $database->people_cursor;
        $writer->on_close(sub { return $cursor->close });

        while (!$writer->is_disconnected) {
            my $person = await $cursor->next_item;
            last unless defined $person;
            await $writer->write_item($person);
        }
    });

=head1 DESCRIPTION

NDJSON is a L<PAGI::Response::Stream> specialization with Content-Type
C<application/x-ndjson>. Each awaited C<write_item> encodes one Perl value as
UTF-8 JSON and appends one LF, producing exactly one record. Embedded CR and
LF in JSON strings are escaped; object key order is not a byte-level contract.
C<write_item(undef)> emits the JSON value C<null>. In the synopsis, the
cursor's C<undef> means EOF, while C<write_item(undef)> means JSON null.

The response does not parse input items, construct cursors, or buffer a whole
sequence. An encoding failure after response start follows the inherited
producer-failure path and cannot replace the started response. The Future from
C<write_item> is the generic Writer's delivery Future, so awaiting it preserves
real send-Future backpressure.

Each invocation receives a fresh specialized Writer and runs a fresh producer.
Connection and transport observation, disconnect handling, terminal delivery,
and cleanup remain owned by Stream and its generic Writer. The response is
reusable and inherits C<body-events-v1>. HEAD requests still run the producer,
so use an explicit lightweight HEAD route when that work is too expensive.

=head1 METHODS

=head2 new

    PAGI::Response::NDJSON->new($producer, %common_response_options)

Constructs the response. The producer must be a coderef. Common C<status>,
C<content_type>, and flat C<headers> options use the Response contract; the
default content type is C<application/x-ndjson>.

=head2 ndjson_response

    my $response = ndjson_response($producer, %common_response_options);

Optional export shorthand for the same constructor. C<PAGI::Response> also
exports it on request or through C<:all>.

=cut

our @EXPORT_OK = qw(ndjson_response);

sub ndjson_response {
    return PAGI::Response::NDJSON->new(@_);
}

sub default_content_type { 'application/x-ndjson' }

sub new {
    my ($class, $producer, @response_options) = @_;
    croak 'PAGI::Response::NDJSON->new requires a producer coderef'
        unless @_ >= 2 && ref($producer) eq 'CODE';

    my $adapted = sub {
        my ($writer) = @_;
        return $producer->(
            PAGI::Response::NDJSON::Writer->_new($writer)
        );
    };

    return $class->SUPER::new($adapted, @response_options);
}

1;
