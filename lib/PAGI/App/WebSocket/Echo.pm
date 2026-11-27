package PAGI::App::WebSocket::Echo;

use v5.24;
use warnings;
use parent 'PAGI::App';
use Class::Tiny qw(on_connect on_disconnect);
use Future::AsyncAwait;

# Accepts the connection, then sends back each message as it came, text as
# text and bytes as bytes, until the connection ends.
async sub call {
    my ($self, $scope, $receive, $send) = @_;
    die "Unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'websocket';
    my $conn = $scope->{'pagi.connection'};

    my $event = await $receive->();
    die "Expected websocket.connect, got $event->{type}\n" unless $event->{type} eq 'websocket.connect';
    await $send->({ type => 'websocket.accept' });
    $self->on_connect->($scope) if $self->on_connect;

    # The session, run until the connection ends: the client closes, the
    # connection fails, or the server ends it. An echo would end the same
    # way without run_until_end, since every end reaches the receive as a
    # disconnect; it's here because it's how every WebSocket session runs,
    # and the first thing you add when you copy this, a Close of your own,
    # is what it guards (send it after, only if $conn->is_connected).
    await $conn->run_until_end(async sub {
        while (1) {
            my $frame = await $receive->();
            return if $frame->{type} eq 'websocket.disconnect';
            my $key = exists $frame->{text} ? 'text' : 'bytes';
            await $send->({ type => 'websocket.send', $key => $frame->{$key} });
        }
    });

    # An echo never ends a session itself, so there's no Close of ours to
    # send: the session ended with the connection. What the client sent, if
    # anything, is on the connection, and disconnect_reason says why it
    # ended otherwise.
    $self->on_disconnect->($scope, $conn->close_code, $conn->close_reason) if $self->on_disconnect;
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

Serve it, and anything a client sends comes straight back.

=head1 INHERITANCE

    PAGI::App::WebSocket::Echo
      PAGI::App
        Class::Tiny::Object

=head1 RATIONALE

Every WebSocket client needs something to talk to while you build it, and an
echo is the simplest thing that answers. This is that, ready made: point your
client at it to check that it connects, that text comes back as text and
bytes as bytes, and that it closes cleanly.

=head1 DESCRIPTION

It reads the client's C<websocket.connect>, accepts, then sends each message
back as it came, text as text and bytes as bytes, until the connection ends:
the client closes it, it fails, or the server ends it. It never closes the
connection itself. It refuses any scope but C<websocket>.

The session runs in C<pagi.connection>'s C<run_until_end>, as every
WebSocket session does (see L<PAGI::Spec::Www>). An app that closes the
connection itself sends its C<websocket.close> after that call, only if
C<< $conn->is_connected >> is still true.

=head1 CONSTRUCTOR ARGUMENTS

Both are optional.

=over 4

=item on_connect

A code reference, called with the scope once the connection is accepted.

=item on_disconnect

A code reference, called once the connection has ended, with the scope, then
the close code and the reason the client sent: C<close_code> and
C<close_reason> from the scope's C<pagi.connection>. When no Close came from
the client, because the connection failed or the server ended it, they're
C<1006> and undef, and C<< $scope->{'pagi.connection'}->disconnect_reason >>
says why.

=back

=head1 COOKBOOK

=head2 Seeing who comes and goes

The two callbacks are enough to log connections while you test a client:

    use v5.40;
    use PAGI::App::WebSocket::Echo;

    PAGI::App::WebSocket::Echo->new(
        on_connect    => sub ($scope) { say "connected: $scope->{path}" },
        on_disconnect => sub ($scope, $code, $reason) {
            my $why = $scope->{'pagi.connection'}->disconnect_reason;
            say "closed: $code", defined $reason ? " ($reason)" : '', defined $why ? ", $why" : '';
        },
    );

=head1 SEE ALSO

L<PAGI::App>, L<PAGI::Spec::Www>

=cut
