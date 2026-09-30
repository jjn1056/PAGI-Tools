#!/usr/bin/env perl
#
# Live dashboard over Server-Sent Events.
#
# - One broadcaster pushes the same metrics, with the same event id, to every
#   connected client every two seconds.
# - The SSE route's handler receives one PAGI::SSE: it welcomes the client,
#   tells a reconnecting one which id it last saw (Last-Event-ID), subscribes
#   it, and unsubscribes it on close.
# - Protocol keepalive keeps proxies from closing an idle stream.
#
# The broadcaster sleeps with Future::IO; pagi-server binds the
# implementation, so no event loop is named here.
#
# Run: pagi-server --app examples/sse-dashboard/app.pl --port 5000
# Open: http://localhost:5000/
#

use strict;
use warnings;
use Future::AsyncAwait;
use Future::IO;

use PAGI::App::File;
use PAGI::Compose qw(compose);
use PAGI::Routing qw(route sse);

my %subscribers;    # subscriber id => PAGI::SSE
my $next_id  = 1;
my $event_id = 0;
my $broadcaster;

# Runs while anyone is subscribed, and starts again with the next subscriber.
sub start_broadcaster {
    return if $broadcaster;
    $broadcaster = (async sub {
        while (%subscribers) {
            await Future::IO->sleep(2);
            my $id = ++$event_id;
            my $metrics = {
                cpu       => 20 + int(rand(60)),
                memory    => 40 + int(rand(40)),
                requests  => int(rand(1000)),
                timestamp => time(),
            };
            for my $sub_id (keys %subscribers) {
                # A broadcast cannot await each client. try_send_event never
                # dies and needs no await; a send that fails means the client
                # has gone, so it is unsubscribed here.
                $subscribers{$sub_id}->try_send_event(
                    event => 'metrics',
                    data  => $metrics,
                    id    => $id,
                )->on_done(sub {
                    my ($ok) = @_;
                    delete $subscribers{$sub_id} unless $ok;
                });
            }
        }
        undef $broadcaster;
    })->();
}

async sub events {
    my ($sse) = @_;
    my $sub_id = $next_id++;

    # Registered before the first send, so a client that leaves at once is
    # still cleaned up.
    $sse->on_close(sub {
        delete $subscribers{$sub_id};
        print STDERR "SSE client $sub_id disconnected\n";
    });

    await $sse->start;
    return if $sse->is_closed;    # the client may leave at any await
    await $sse->keepalive(25);
    await $sse->send_event(
        event => 'connected',
        data  => { subscriber_id => $sub_id, server_time => time() },
    );
    return if $sse->is_closed;

    if (my $last_id = $sse->last_event_id) {
        await $sse->send_event(event => 'reconnected', data => { last_id => $last_id });
        return if $sse->is_closed;
    }

    $subscribers{$sub_id} = $sse;
    start_broadcaster();
    print STDERR "SSE client $sub_id connected\n";

    await $sse->run;    # until the client goes
}

compose(routes => [
    sse('/events' => \&events),
    route('/*path' => PAGI::App::File->from_app_path('public')),
]);
