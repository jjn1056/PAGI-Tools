package PAGITest::Connected;

# Scopes for PAGI::WebSocket and PAGI::SSE unit tests. Every scope carries
# pagi.connection, as PAGI::Spec::Www requires of a server. A receive built by
# receive_from records a terminal event on that connection before handing it
# out, in the order a server does, so helpers read the same terminal facts
# they would under PAGI::Server. The mapping follows PAGI::Test::WebSocket and
# PAGI::Test::SSE.

use strict;
use warnings;
use Exporter 'import';
use Future;
use PAGI::Test::ConnectionState;

our @EXPORT_OK = qw(ws_scope sse_scope receive_from);

sub ws_scope {
    my (%extra) = @_;
    return {
        type    => 'websocket',
        headers => [],
        %extra,
        'pagi.connection' => PAGI::Test::ConnectionState->new(websocket => 1),
    };
}

sub sse_scope {
    my (%extra) = @_;
    return {
        type    => 'sse',
        headers => [],
        %extra,
        'pagi.connection' => PAGI::Test::ConnectionState->new,
    };
}

# Returns a receive coderef yielding @events in order, then undef.
sub receive_from {
    my ($scope, @events) = @_;
    my $connection = $scope->{'pagi.connection'};
    return sub {
        my $event = shift @events;
        _record_terminal($connection, $event) if $event;
        return Future->done($event);
    };
}

sub _record_terminal {
    my ($connection, $event) = @_;
    return unless $connection->is_connected;
    my $type = $event->{type} // '';

    if ($type eq 'websocket.disconnect') {
        my $code = $event->{code};
        if (defined $code && $code == 1006) {
            # No peer Close frame: an abnormal end.
            $connection->_set_peer_close(1006, undef);
            $connection->_mark_disconnected($event->{reason} // 'client_closed');
        }
        else {
            # A peer Close, answered: clean completion carrying the peer's
            # code, or 1005 when its Close carried none.
            $connection->_set_peer_close(
                $code // 1005, defined $code ? ($event->{reason} // '') : undef,
            );
            $connection->_mark_complete;
        }
    }
    elsif ($type eq 'sse.disconnect') {
        $connection->_mark_disconnected($event->{reason} // 'client_closed');
    }
    return;
}

1;
