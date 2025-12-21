#!/usr/bin/env perl
#
# Multi-room WebSocket Chat using PAGI::WebSocket
#
# This example shows a complete chat application with:
# - Room join/leave
# - Nicknames
# - Broadcast messaging
# - Proper cleanup on disconnect
#
# Compare with lib/PAGI/App/WebSocket/Chat.pm for the raw protocol version.
#
# Run: pagi-server --app examples/websocket-chat-v2/app.pl --port 5000
#
use strict;
use warnings;
use Future::AsyncAwait;
use JSON::PP qw(encode_json decode_json);
use lib 'lib';
use PAGI::WebSocket;

# Shared state
my %rooms;      # room => { users => { id => { ws => $ws, name => $name } } }
my $next_id = 1;

my $app = async sub {
    my ($scope, $receive, $send) = @_;

    # Handle lifespan
    if ($scope->{type} eq 'lifespan') {
        while (1) {
            my $event = await $receive->();
            if ($event->{type} eq 'lifespan.startup') {
                print "Chat server starting...\n";
                await $send->({ type => 'lifespan.startup.complete' });
            }
            elsif ($event->{type} eq 'lifespan.shutdown') {
                print "Chat server shutting down...\n";
                await $send->({ type => 'lifespan.shutdown.complete' });
                last;
            }
        }
        return;
    }

    die "Expected websocket" if $scope->{type} ne 'websocket';

    # Create WebSocket wrapper
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);
    await $ws->accept;

    # User setup
    my $user_id = $next_id++;
    my $username = "user_$user_id";
    my @my_rooms;

    # Register cleanup - runs on ANY disconnect
    $ws->on_close(async sub {
        my ($code, $reason) = @_;
        print "User $username disconnected ($code)\n";

        for my $room (@my_rooms) {
            leave_room($user_id, $room);
            await broadcast_to_room($room, {
                type     => 'user_left',
                room     => $room,
                user_id  => $user_id,
                username => $username,
            });
        }
    });

    # Join default room
    join_room($user_id, $ws, $username, 'lobby');
    push @my_rooms, 'lobby';

    # Send welcome
    await $ws->send_json({
        type     => 'welcome',
        user_id  => $user_id,
        username => $username,
        room     => 'lobby',
    });

    print "User $username joined lobby\n";

    # Message loop
    await $ws->each_json(async sub {
        my ($data) = @_;
        my $cmd = $data->{type} // 'message';

        if ($cmd eq 'message') {
            my $msg = $data->{message} // '';
            my $target = $data->{room};
            my @targets = $target ? ($target) : @my_rooms;

            for my $room (@targets) {
                next unless grep { $_ eq $room } @my_rooms;
                await broadcast_to_room($room, {
                    type      => 'message',
                    room      => $room,
                    user_id   => $user_id,
                    username  => $username,
                    message   => $msg,
                    timestamp => time(),
                }, $user_id);
            }
        }
        elsif ($cmd eq 'join') {
            my $room = $data->{room} // 'lobby';

            join_room($user_id, $ws, $username, $room);
            push @my_rooms, $room unless grep { $_ eq $room } @my_rooms;

            await $ws->send_json({ type => 'joined', room => $room });

            await broadcast_to_room($room, {
                type     => 'user_joined',
                room     => $room,
                user_id  => $user_id,
                username => $username,
            }, $user_id);
        }
        elsif ($cmd eq 'leave') {
            my $room = $data->{room};
            return unless $room && grep { $_ eq $room } @my_rooms;

            leave_room($user_id, $room);
            @my_rooms = grep { $_ ne $room } @my_rooms;

            await $ws->send_json({ type => 'left', room => $room });

            await broadcast_to_room($room, {
                type     => 'user_left',
                room     => $room,
                user_id  => $user_id,
                username => $username,
            });
        }
        elsif ($cmd eq 'nick') {
            my $new_name = $data->{username} // $username;
            $new_name =~ s/[^\w\-]//g;
            $new_name = substr($new_name, 0, 20);

            for my $room (@my_rooms) {
                $rooms{$room}{users}{$user_id}{name} = $new_name
                    if $rooms{$room}{users}{$user_id};
            }
            $username = $new_name;

            await $ws->send_json({ type => 'nick', username => $username });
        }
        elsif ($cmd eq 'list') {
            my $room = $data->{room};
            return unless $room && $rooms{$room};

            my @users = map { $_->{name} } values %{$rooms{$room}{users}};
            await $ws->send_json({ type => 'users', room => $room, users => \@users });
        }
        elsif ($cmd eq 'rooms') {
            my @room_list = map {
                { name => $_, count => scalar keys %{$rooms{$_}{users}} }
            } keys %rooms;
            await $ws->send_json({ type => 'rooms', rooms => \@room_list });
        }
    });
};

#
# Helper functions
#

sub join_room {
    my ($user_id, $ws, $username, $room) = @_;

    $rooms{$room} //= { users => {} };
    $rooms{$room}{users}{$user_id} = {
        ws   => $ws,
        name => $username,
    };
}

sub leave_room {
    my ($user_id, $room) = @_;

    return unless $rooms{$room};
    delete $rooms{$room}{users}{$user_id};
    delete $rooms{$room} if !keys %{$rooms{$room}{users}};
}

async sub broadcast_to_room {
    my ($room, $data, $exclude_id) = @_;

    return unless $rooms{$room};
    my $users = $rooms{$room}{users};

    for my $id (keys %$users) {
        next if defined $exclude_id && $id eq $exclude_id;

        my $ws = $users->{$id}{ws};

        # Safe send - returns false if client disconnected
        my $sent = await $ws->try_send_json($data);

        if (!$sent) {
            # Client gone, clean up
            delete $users->{$id};
        }
    }

    # Clean empty room
    delete $rooms{$room} if !keys %{$rooms{$room}{users}};
}

$app;
