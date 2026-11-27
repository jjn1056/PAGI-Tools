package PAGI::App::WebSocket::Echo;

use v5.24;
use warnings;
use parent 'PAGI::App';
use Future::AsyncAwait;

# Accepts the connection, then sends back each message as it came, text as
# text and bytes as bytes, until the connection ends.
async sub call {
    my ($self, $scope, $receive, $send) = @_;
    die "Unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'websocket';

    # Go on only with websocket.connect. The one other first event is
    # websocket.disconnect, from a client that went away during the
    # handshake: there's nothing to accept.
    my $event = await $receive->();
    return unless $event->{type} eq 'websocket.connect';
    await $send->({ type => 'websocket.accept' });

    # The session, run until the connection ends (the client closes, the
    # connection fails, or the server ends it) or the client says "bye".
    my $conn = $scope->{'pagi.connection'};
    await $conn->run_until_end(async sub {
        while (1) {
            my $frame = await $receive->();
            return if $frame->{type} eq 'websocket.disconnect';    # the connection ended
            return if ($frame->{text} // '') eq 'bye';              # we're done
            my $key = exists $frame->{text} ? 'text' : 'bytes';
            await $send->({ type => 'websocket.send', $key => $frame->{$key} });
        }
    });

    # Our Close, sent once, after the session, and only if the connection is
    # still up: the session ended on "bye". If the connection ended instead,
    # there's nothing to close, and a client's Close is answered by the
    # server.
    await $send->({ type => 'websocket.close', code => 1000 }) if $conn->is_connected;
    return;
}

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::App::WebSocket::Echo - A WebSocket that sends every message back

=head1 SYNOPSIS

    use v5.40;
    use PAGI::App::WebSocket::Echo;

    PAGI::App::WebSocket::Echo->new;

Serve it, and anything a client sends comes straight back, until it sends
the text C<bye>: then the echo closes the connection.

=head1 INHERITANCE

    PAGI::App::WebSocket::Echo
      PAGI::App
        Class::Tiny::Object

=head1 RATIONALE

Every WebSocket client needs something to talk to while you build it, and an
echo is the simplest thing that answers. This is that, ready made: point your
client at it to check that it connects, that text comes back as text and
bytes as bytes, and that it closes cleanly, whether your client closes or
the server does.

=head1 DESCRIPTION

It reads the client's C<websocket.connect>, accepts, then sends each message
back as it came, text as text and bytes as bytes, until one of two things
ends the session:

=over 4

=item * the client sends the text C<bye>. The echo closes the connection,
with code 1000. (C<bye> sent as bytes is echoed like any other message.)

=item * the connection ends: the client closes it, it fails, or the server
ends it. There's nothing left to close then, and a client's Close is
answered by the server.

=back

A client gone before the accept (its first event is C<websocket.disconnect>,
not C<websocket.connect>) is left alone: nothing is sent. It refuses any
scope but C<websocket>.

The session runs in C<pagi.connection>'s C<run_until_end>, as every
WebSocket session does (see L<PAGI::Spec::Www>), and the echo's Close is
sent once, after that call, only if C<< $conn->is_connected >> is still
true: so it's sent when the session ended on C<bye>, and not when the
connection had already ended.

It takes no arguments. To do more, watch connections come and go, say, copy
it: it's short, and written to be the shape a WebSocket app starts from.

=head1 SEE ALSO

L<PAGI::App>, L<PAGI::Spec::Www>

=cut
