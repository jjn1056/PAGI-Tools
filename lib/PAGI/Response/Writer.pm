package PAGI::Response::Writer;

use v5.24;
use warnings;
use Encode ();
use Future;
use Future::AsyncAwait;

# Built by PAGI::Response::Stream for one request, and given to its body.
sub _new {
    my ($class, %args) = @_;
    return bless { %args, on_close => [] }, $class;
}

# One body chunk. The first sends the start before it; an empty one sends
# nothing, not even the start.
async sub write {
    my ($self, $bytes) = @_;
    return unless defined $bytes && length $bytes;
    await $self->_start;
    await $self->{send}->({ type => 'http.response.body', body => $bytes, more => 1 });
    return;
}

# Characters, written as UTF-8. Text UTF-8 can't carry croaks here, at the
# call; your string is left as it was.
sub write_text {
    my ($self, $text) = @_;
    return $self->write(Encode::encode('UTF-8', $text, Encode::FB_CROAK));
}

# An item, written as the response's format_item makes it.
sub write_item {
    my ($self, $item) = @_;
    return $self->write($self->{response}->format_item($item));
}

# Every chunk of a source, written in turn: its next_chunk returns bytes or
# a Future of them, and undef when there are no more.
async sub pipe_from {
    my ($self, $source) = @_;
    while (defined(my $chunk = await Future->wrap($source->next_chunk))) {
        await $self->write($chunk);
    }
    return;
}

# Cleanup, run once the stream has ended: finished, left, or failed.
sub on_close {
    my ($self, $callback) = @_;
    push @{ $self->{on_close} }, $callback;
    return $self;
}

# How the stream ended: finished, disconnected or failed; undef while it runs.
sub outcome { return $_[0]{outcome} }

# The start, sent once, by whichever send comes first.
sub _start {
    my ($self) = @_;
    return $self->{start} //= $self->{response}->send_start($self->{send});
}

# The end: the start if nothing sent it, the last body event, then the
# trailers if the response declared them (none given is an empty list).
async sub _end {
    my ($self, $trailers) = @_;
    await $self->_start;
    await $self->{send}->({ type => 'http.response.body', body => '', more => 0 });
    return unless $self->{response}->has_trailers;
    await $self->{send}->({ type => 'http.response.trailers', headers => $trailers // [] });
    return;
}

# The stream ended: the outcome is set, then each on_close callback runs,
# in order, waited for; one that dies is warned about, and the rest run.
async sub _ended {
    my ($self, $outcome) = @_;
    $self->{outcome} = $outcome;
    for my $callback (@{ $self->{on_close} }) {
        my $ok = eval { await Future->wrap($callback->($self)); 1 };
        warn "on_close callback died: $@" unless $ok;
    }
    return;
}

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::Response::Writer - what a stream's body writes with

=head1 SYNOPSIS

    PAGI::Response::Stream->new(body => async sub ($writer) {
        $writer->on_close(sub ($writer) { warn 'ended: ', $writer->outcome, "\n" });
        await $writer->write("bytes\n");
        await $writer->write_text("characters, as UTF-8 🌍\n");
        await $writer->pipe_from($source);
    });

=head1 DESCRIPTION

L<PAGI::Response::Stream> makes one for each request and gives it to the
body. You don't build one yourself.

Each write returns a Future, done once the server has taken the chunk:
await it, and you write no faster than the server takes. Writes made
without waiting go out in the order you made them.

=head1 METHODS

=head2 write

    await $writer->write($bytes);

One chunk of the body. The first sends the start before it. An empty or
undefined chunk sends nothing, not even the start.

It sends what it's given as bytes, so encode text first, or use
C<write_text>. A character above 255 is refused at the send, but one below,
the C<ü> in C<"Grüße"> say, goes out as a single byte, which a UTF-8 client
reads wrong. See L<PAGI::Response::Stream/UTF-8>.

=head2 write_text

    await $writer->write_text($characters);

Characters, written as UTF-8. A character UTF-8 can't carry, a lone
surrogate such as C<"\x{D800}">, dies here, at the call, with L<Encode>'s
error. Your string is left as it was.

=head2 write_item

    await $writer->write_item($item);

The item, written as the response's
L<PAGI::Response::Stream/format_item> makes it. On a plain Stream that's the
item as it is.

=head2 pipe_from

    await $writer->pipe_from($source);

Writes each chunk a source gives, until it gives C<undef>. The source is any
object with C<next_chunk>, returning bytes or a Future of them; each chunk
is written, and waited for, before the next is asked for. Empty chunks are
skipped. The source should be the request's own: a client leaving cancels
the Future C<next_chunk> returned.

=head2 on_close

    $writer->on_close(sub ($writer) { ... });

Cleanup, run once the stream has ended: after the end was sent, after the
client left, or after the body died. Not if something cancels C<call>'s
Future: nothing after that point runs. To time a stream out, abort the
connection instead (L<PAGI::Response::Stream/TIMING OUT A STREAM>).
Callbacks run in
the order given, and each may return a Future, which is waited for before
the next runs. One that dies is warned about, and the rest still run.
C<call> returns, or dies, after them. Register them before the body's first
C<await>, so they're in place whatever happens next.

=head2 outcome

    my $how = $writer->outcome;

How the stream ended: C<finished>, C<disconnected> or C<failed>
(L<PAGI::Response::Stream/HOW A STREAM ENDS>). C<undef> while the body
runs; set before the C<on_close> callbacks run.

=head1 SEE ALSO

L<PAGI::Response::Stream>

=cut
