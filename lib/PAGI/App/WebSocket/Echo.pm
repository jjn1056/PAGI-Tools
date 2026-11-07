package PAGI::App::WebSocket::Echo;

use v5.24;
use warnings;
use parent 'PAGI::App';
use Class::Tiny qw(on_connect on_disconnect);
use Future::AsyncAwait;

# Accepts the connection, then sends back each message as it came, text as
# text and bytes as bytes, until the client goes away.
async sub call {
    my ($self, $scope, $receive, $send) = @_;
    die "Unsupported scope type: $scope->{type}\n" unless $scope->{type} eq 'websocket';

    await $send->({ type => 'websocket.accept' });
    $self->on_connect->($scope) if $self->on_connect;

    while (1) {
        my $event = await $receive->();

        if ($event->{type} eq 'websocket.receive') {
            my $key = exists $event->{text} ? 'text' : 'bytes';
            await $send->({ type => 'websocket.send', $key => $event->{$key} });
        }
        elsif ($event->{type} eq 'websocket.disconnect') {
            $self->on_disconnect->($scope, $event->{code}, $event->{reason})
                if $self->on_disconnect;
            return;
        }
    }
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

It accepts the connection, then sends each message back as it came, text as
text and bytes as bytes, until the client disconnects. It refuses any scope
but C<websocket>.

=head1 CONSTRUCTOR ARGUMENTS

Both are optional.

=over 4

=item on_connect

A code reference, called with the scope once the connection is accepted.

=item on_disconnect

A code reference, called when the client disconnects, with the scope, the
close code and the reason, when the client gave one.

=back

=head1 COOKBOOK

=head2 Seeing who comes and goes

The two callbacks are enough to log connections while you test a client:

    use v5.40;
    use PAGI::App::WebSocket::Echo;

    PAGI::App::WebSocket::Echo->new(
        on_connect    => sub ($scope) { say "connected: $scope->{path}" },
        on_disconnect => sub ($scope, $code, $reason) {
            say "closed: $code", defined $reason ? " ($reason)" : '';
        },
    );

=head1 SEE ALSO

L<PAGI::App>, L<PAGI::Spec::Www>

=cut
