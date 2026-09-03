package PAGI::Response::NDJSON::Writer;

use strict;
use warnings;

use Carp qw(croak);
use JSON::MaybeXS ();

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
