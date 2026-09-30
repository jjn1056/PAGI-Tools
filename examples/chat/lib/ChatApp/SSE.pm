package ChatApp::SSE;

# The chat's system-notification stream. The Router hands events() one
# PAGI::SSE. New system events are pushed to it by ChatApp::State as they
# happen; this handler replays what a reconnecting client missed and sends
# server statistics every ten seconds.

use strict;
use warnings;

use Future::AsyncAwait;

use ChatApp::State qw(
    add_sse_subscriber remove_sse_subscriber
    get_recent_system_events get_stats generate_id
);

use constant STATS_INTERVAL => 10;    # seconds

async sub events {
    my ($sse) = @_;

    # A reconnecting EventSource sends the id of the last event it saw.
    my $last_event_id = int($sse->last_event_id // 0);

    my $subscriber_id = generate_id();
    $sse->on_close(sub { remove_sse_subscriber($subscriber_id) });

    await $sse->start(headers => [
        ['cache-control', 'no-cache'],
        ['x-accel-buffering', 'no'],    # disable nginx buffering
    ]);

    # Take the catch-up list, then subscribe, then replay: an event that
    # happens during the replay is pushed live instead of being missed.
    my $missed = get_recent_system_events($last_event_id);
    add_sse_subscriber($subscriber_id, $sse, $last_event_id);
    for my $event (@$missed) {
        await $sse->send_event(
            event => $event->{type},
            data  => $event->{data},
            id    => $event->{id},
        );
    }

    # Statistics now and every STATS_INTERVAL seconds until the client goes
    # (every() runs its callback first, then waits).
    await $sse->every(STATS_INTERVAL, async sub {
        await $sse->send_event(event => 'stats', data => get_stats());
    });
}

1;

__END__

# NAME

ChatApp::SSE - Server-Sent Events handler for system notifications

# SYNOPSIS

    use PAGI::Routing qw(sse);
    sse('/events' => \&ChatApp::SSE::events);

# DESCRIPTION

`events($sse)` receives one PAGI::SSE from the Router.

## Event Types

- **user_connected** - A user has connected to the chat.
- **user_disconnected** - A user has disconnected from the chat.
- **room_created** - A new room has been created.
- **room_deleted** - An empty room has been deleted.
- **stats** - Server statistics, sent on connect and every 10 seconds.

System events are pushed to every connected client as they happen (see
`add_system_event` in ChatApp::State).

## Catch-Up Support

A reconnecting client sends the `Last-Event-ID` header; `$sse->last_event_id`
reads it, and events after that id are replayed before live delivery starts.

`$sse->every` needs a Future::IO implementation, which `pagi-server` binds at
startup; application code never names an event loop.

# SEE ALSO

PAGI::SSE, PAGI::Routing
