#!/usr/bin/env perl

# Multi-user chat: HTTP, WebSocket and SSE in one application.
#
# - HTTP: a JSON API (a Router mounted at /api) and the static frontend
# - WebSocket: real-time chat, one PAGI::WebSocket per connection
# - SSE: system notifications, one PAGI::SSE per client
# - Lifespan: startup and shutdown hooks
#
# Run with:
#   pagi-server -I lib --app examples/chat/app.pl --port 5000
# Then open http://localhost:5000

use strict;
use warnings;

use Future::AsyncAwait;
use File::Basename qw(dirname);
use lib dirname(__FILE__) . '/lib';

use PAGI::App::File;
use PAGI::Compose qw(compose);
use PAGI::Routing qw(middleware mount route sse websocket);

use ChatApp::State qw(get_stats);
use ChatApp::HTTP;
use ChatApp::WebSocket;
use ChatApp::SSE;

# Logs every HTTP request, WebSocket and SSE connection, and the lifespan
# loop. PAGI::Middleware::AccessLog covers HTTP only, so this one is written
# out; it is also a compact example of wrapping send to watch responses.
sub with_logging {
    my ($app) = @_;

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $start = time();
        my $type = $scope->{type};
        my $path = $scope->{path} // '-';
        my $method = $scope->{method} // '-';

        my $status = '-';
        my $wrapped_send = async sub {
            my ($event) = @_;
            if ($event->{type} =~ /\.start$/ && defined $event->{status}) {
                $status = $event->{status};
            }
            await $send->($event);
        };

        eval {
            await $app->($scope, $receive, $wrapped_send);
        };
        my $error = $@;

        my $duration = sprintf("%.3f", time() - $start);

        # Format: [TYPE] METHOD PATH STATUS DURATION
        my $client = $scope->{client} ? "$scope->{client}[0]" : '-';
        say STDERR "[$type] $method $path $status ${duration}s ($client)";

        die $error if $error;
    };
}

compose(
    routes => [
        websocket('/ws/chat' => \&ChatApp::WebSocket::chat),
        sse('/events' => \&ChatApp::SSE::events),
        mount('/api', app => ChatApp::HTTP::routing()),
        # A Route is HTTP-only, so WebSocket and SSE misses still get the
        # Router's refusals rather than reaching the file application.
        route('/*path' => PAGI::App::File->from_app_path('public')),
    ],
    middleware => [middleware(\&with_logging)],
    lifespan => {
        startup => async sub {
            say STDERR "[lifespan] Application starting up...";

            # Default rooms are created on module load
            my $stats = get_stats();
            say STDERR "[lifespan] Initialized with $stats->{rooms_count} default rooms";
        },
        shutdown => async sub {
            say STDERR "[lifespan] Application shutting down...";

            my $stats = get_stats();
            say STDERR "[lifespan] Final stats: $stats->{users_online} users, $stats->{messages_total} messages";
        },
    },
);

__END__

=head1 NAME

Multi-User Chat - HTTP, WebSocket and SSE in one PAGI-Tools application

=head1 SYNOPSIS

    pagi-server -I lib --app examples/chat/app.pl --port 5000

Then open http://localhost:5000 in a browser (two tabs to chat with yourself).

=head1 DESCRIPTION

A comprehensive demonstration of PAGI's capabilities through a multi-user
chat application featuring:

=over

=item * B<WebSocket> - Real-time bidirectional chat messaging

=item * B<HTTP> - Static file serving and REST API endpoints

=item * B<SSE> - Server-Sent Events for system notifications

=item * B<Lifespan> - Application lifecycle management

=back

=head1 ENDPOINTS

=head2 HTTP

=over

=item GET /

Serves the chat frontend (index.html)

=item GET /api/rooms

Lists all chat rooms with user counts

=item GET /api/room/{name}/history

Gets message history for a room

=item GET /api/room/{name}/users

Lists the users in a room

=item GET /api/stats

Server statistics (uptime, users, messages)

=back

=head2 WebSocket

=over

=item /ws/chat

WebSocket endpoint for chat. Connect with C<?name=Username> query parameter.

=back

=head2 SSE

=over

=item /events

Server-Sent Events stream: system notifications as they happen, recent ones
replayed on reconnect (C<Last-Event-ID>), and statistics every 10 seconds

=back

=head1 FEATURES

=head2 Chat Features

=over

=item * Multiple chat rooms (create, join, leave)

=item * Real-time message broadcasting

=item * Typing indicators

=item * Private messaging (/pm user message)

=item * User presence tracking

=item * Message history (last 100 per room)

=back

=head2 Commands

Type these in chat:

    /help           - Show available commands
    /rooms          - List all rooms
    /users          - List users in current room
    /join <room>    - Join or create a room
    /leave          - Leave current room
    /pm <user> <msg> - Send private message
    /nick <name>    - Change your nickname
    /me <action>    - Send action message

=head1 AUTHOR

PAGI Demo Application

=cut
