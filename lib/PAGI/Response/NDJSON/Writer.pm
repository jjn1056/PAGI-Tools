package PAGI::Response::NDJSON::Writer;

use strict;
use warnings;

use Carp qw(croak);
use JSON::MaybeXS ();

=encoding UTF-8

=head1 NAME

PAGI::Response::NDJSON::Writer - per-invocation structured-record stream writer

=head1 DESCRIPTION

This Writer is supplied only to a L<PAGI::Response::NDJSON> producer. It wraps
the public generic L<PAGI::Response::Writer> API and exposes structured-record
writing, cleanup registration, connection state, and transport observations.
It deliberately has no raw byte emission, source relaying, or close method:
generic Writer owns delivery/backpressure and Stream owns lifecycle and
terminal delivery.

=head1 METHODS

=head2 write_item

    await $writer->write_item($value);

Encodes one value as UTF-8 JSON, appends one LF, and returns the underlying
generic Writer write Future. Await it before the next record to retain
backpressure. C<undef> encodes as JSON C<null>; it is not an EOF marker.
Encoding failures croak before a record is delivered. JSON escapes embedded CR
and LF; object-member ordering is not promised.

=head2 on_close

    $writer->on_close(sub { return $resource->close });

Registers cleanup delegated to the generic Writer. Stream runs registered
cleanup when the producer completes, fails, is cancelled, or the connection
ends.

=head2 connection and transport observation

    $writer->is_closed
    $writer->is_disconnected
    $writer->disconnect_reason
    $writer->bytes_written
    $writer->buffered_amount
    $writer->high_water_mark
    $writer->low_water_mark
    $writer->is_writable
    $writer->on_high_water(sub { ... })
    $writer->on_drain(sub { ... })

These public observations delegate to the generic Writer. They report the
per-invocation connection and transport state without moving lifecycle
ownership into this class.

=cut

my $JSON = JSON::MaybeXS->new(utf8 => 1);

sub _new {
    my ($class, $writer) = @_;
    return bless { _writer => $writer }, $class;
}

sub write_item {
    my ($self, $value) = @_;
    my ($bytes, $ok);
    $ok = eval { $bytes = $JSON->encode($value); 1 };
    croak "NDJSON item encoding failed: $@" unless $ok;
    return $self->{_writer}->write($bytes . "\n");
}

sub on_close {
    my ($self, $callback) = @_;
    $self->{_writer}->on_close($callback);
    return $self;
}

sub is_closed         { return $_[0]{_writer}->is_closed }
sub is_disconnected   { return $_[0]{_writer}->is_disconnected }
sub disconnect_reason { return $_[0]{_writer}->disconnect_reason }
sub bytes_written     { return $_[0]{_writer}->bytes_written }
sub buffered_amount   { return $_[0]{_writer}->buffered_amount }
sub high_water_mark   { return $_[0]{_writer}->high_water_mark }
sub low_water_mark    { return $_[0]{_writer}->low_water_mark }
sub is_writable       { return $_[0]{_writer}->is_writable }

sub on_high_water {
    my ($self, $callback) = @_;
    $self->{_writer}->on_high_water($callback);
    return $self;
}

sub on_drain {
    my ($self, $callback) = @_;
    $self->{_writer}->on_drain($callback);
    return $self;
}

1;
