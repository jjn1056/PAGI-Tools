package PAGI::Utils::ReceiveBuffer::TempFile;

use strict;
use warnings;
use Carp qw(croak);
use File::Temp qw(tempfile);
use Future;
use Storable qw(nfreeze thaw);
use PAGI::Utils ();

our $SPOOL_THRESHOLD = 64 * 1024;    # 64KB held in memory before spooling to disk

sub new {
    my ($class, %args) = @_;
    my $threshold = exists $args{spool_threshold} ? $args{spool_threshold} : $SPOOL_THRESHOLD;
    croak 'PAGI::Utils::ReceiveBuffer::TempFile spool_threshold must be a number of bytes, 0 or more'
        unless defined($threshold) && !ref($threshold) && $threshold =~ /\A[0-9]+\z/;
    my $temp_dir = delete $args{temp_dir};
    delete $args{spool_threshold};
    PAGI::Utils::_reject_unknown_options('PAGI::Utils::ReceiveBuffer::TempFile', \%args);

    return bless {
        spool_threshold => $threshold,
        temp_dir        => $temp_dir // $ENV{TMPDIR} // '/tmp',
        size            => 0,
        events          => [],
        fh              => undef,
        read_at         => 0,
    }, $class;
}

sub append {
    my ($self, $event) = @_;
    $self->{size} += length for grep { defined && !ref } values %$event;
    if (!$self->{fh} && $self->{size} > $self->{spool_threshold}) {
        $self->_start_spool;
    }
    if ($self->{fh}) {
        $self->_write($event);
    }
    else {
        push @{$self->{events}}, $event;
    }
    return Future->done;
}

sub take {
    my ($self) = @_;
    return Future->done(shift @{$self->{events}}) unless $self->{fh};
    return Future->done($self->_read);
}

# The file is created without a name in temp_dir, so it is removed when the
# buffer is freed, or when the process ends, however it ends.
sub _start_spool {
    my ($self) = @_;
    my $fh = tempfile(DIR => $self->{temp_dir});
    binmode $fh;
    $self->{fh} = $fh;
    $self->_write($_) for splice @{$self->{events}};
}

# Each event is a 4-byte length followed by the frozen event.
sub _write {
    my ($self, $event) = @_;
    my $frozen = nfreeze($event);
    my $fh = $self->{fh};
    seek($fh, 0, 2) or croak "PAGI::Utils::ReceiveBuffer::TempFile cannot seek its temp file: $!";
    print {$fh} pack('N', length $frozen), $frozen
        or croak "PAGI::Utils::ReceiveBuffer::TempFile cannot write its temp file: $!";
}

sub _read {
    my ($self) = @_;
    my $fh = $self->{fh};
    seek($fh, $self->{read_at}, 0) or croak "PAGI::Utils::ReceiveBuffer::TempFile cannot seek its temp file: $!";
    my $got = read($fh, my $length, 4);
    croak "PAGI::Utils::ReceiveBuffer::TempFile cannot read its temp file: $!" unless defined $got;
    return undef unless $got;
    $length = unpack('N', $length);
    croak 'PAGI::Utils::ReceiveBuffer::TempFile temp file is truncated'
        unless $got == 4 && read($fh, my $frozen, $length) == $length;
    $self->{read_at} = tell $fh;
    return thaw($frozen);
}

1;

__END__

=head1 NAME

PAGI::Utils::ReceiveBuffer::TempFile - Keeps received events for replay, in a temp file over a size

=head1 SYNOPSIS

    use PAGI::Utils::ReceiveBuffer::TempFile;
    use PAGI::Utils::Middleware qw(record_receive);

    my $buffer = PAGI::Utils::ReceiveBuffer::TempFile->new(
        spool_threshold => 1024 * 1024,    # 1MB in memory, then a temp file
    );
    my ($reading, $replaying) = record_receive($receive, buffer => $buffer);

=head1 DESCRIPTION

A buffer for L<PAGI::Utils::Middleware/record_receive>, which otherwise
keeps the events a middleware reads in memory: give it this one, with
C<< buffer => PAGI::Utils::ReceiveBuffer::TempFile->new >>, when bodies may
be large. Small bodies stay in memory; over a size they go to a temp file. Events are held in memory until
their size passes C<spool_threshold> (64KB by default); from then on every
event, the ones already held included, lives in a temporary file.

The size counted is that of each event's plain values (a request body's
bytes, its type, and so on). Events in memory are handed back as the same
hashes that were appended. Spooled events are copies, frozen with
L<Storable>, so an event must hold only plain data, as received events do.

Writing and reading the temporary file blocks, as the temporary files of
L<PAGI::Request>'s buffered uploads do: regular files offer no readiness to
wait on, so a loop-agnostic module has no asynchronous way to use them. For
a buffer that does not block, or one that keeps events elsewhere, such as
Redis, write a class with the same two methods (see L</WRITING A BUFFER>).

The temporary file has no name: it is removed when the buffer is freed, or
when the process ends.

=head1 METHODS

=head2 new

    my $buffer = PAGI::Utils::ReceiveBuffer::TempFile->new(%options);

Options:

=over 4

=item * spool_threshold (default: 65536)

The number of bytes held in memory. Once the events appended exceed it, they
are spooled to a temporary file. C<0> spools from the first event.

=item * temp_dir (default: C<$ENV{TMPDIR}>, else F</tmp>)

Where the temporary file is created.

=back

=head2 append

    await $buffer->append($event);

Keeps C<$event>, after the events already kept. Returns a L<Future>.

=head2 take

    my $event = await $buffer->take;

Removes and returns the oldest event kept, or C<undef> when none are left.
Returns a L<Future>.

=head1 WRITING A BUFFER

Any object with C<append> and C<take>, behaving as above and returning
Futures, can be given to C<record_receive>. All the events are appended
before the first is taken. A buffer is made for one request, so it can
release what it holds when it is freed.

=head1 SEE ALSO

L<PAGI::Utils::Middleware/record_receive>, L<PAGI::Middleware/WRITING MIDDLEWARE>

=cut
