package ChatApp::WebSocket;

# The chat's WebSocket route. The Router hands chat() one PAGI::WebSocket, so
# there is no protocol plumbing here: accept, send_json, each_json and
# on_close do it.

use strict;
use warnings;

use Future::AsyncAwait;
use PAGI::Utils::Random ();

use ChatApp::State qw(
    get_session create_session update_session
    get_session_by_name set_session_connected set_session_disconnected
    cancel_disconnect_timer is_session_connected
    get_room add_room get_all_rooms
    add_user_to_room remove_user_from_room get_room_users get_room_sessions
    add_message get_room_messages get_messages_since
    sanitize_username sanitize_room_name
);

async sub chat {
    my ($ws) = @_;

    # A reconnecting browser sends its session id and the last message it
    # saw, so it can be caught up.
    my $session_id  = $ws->query('session') // '';
    my $raw_name    = $ws->query('name')    // '';
    my $last_msg_id = int($ws->query('lastMsgId') // 0);

    my $session;
    # This connection's delivery callback; it also identifies the connection
    # that owns the session.
    my $send_cb = sub { $ws->try_send_json($_[0]) };

    # Runs on any disconnect. Other users hear "user left" only if this one
    # does not reconnect within the grace period (see ChatApp::State). When
    # the server is shutting down nobody remains to hear it, so the grace
    # period is not started; the connection object reports that as the
    # standard disconnect reason, which a client's own Close cannot fake.
    $ws->on_close(sub {
        if (($ws->disconnect_reason // '') eq 'server_shutdown') {
            print STDERR "[ws] $session->{name}: ended by server shutdown\n" if $session;
            return;
        }
        my $broadcast_leave = sub {
            my ($room_name, $username) = @_;
            for my $other_session (@{ get_room_sessions($room_name) }) {
                next unless $other_session->{send_cb};
                # Best-effort: runs when the grace period ends, outside any
                # await, and a recipient that has gone is simply skipped.
                $other_session->{send_cb}->({
                    type  => 'user_left',
                    room  => $room_name,
                    user  => $username,
                    users => get_room_users($room_name),
                });
            }
        };
        set_session_disconnected($session_id, $broadcast_leave, $send_cb) if $session;
    });

    await $ws->accept;
    return if $ws->is_closed;

    $session = $session_id ? get_session($session_id) : undef;

    if ($session) {
        # Resume an existing session and send what it missed.
        set_session_connected($session_id, $send_cb);

        my %missed_messages;
        for my $room_name (keys %{$session->{rooms}}) {
            $missed_messages{$room_name} = get_messages_since($room_name, $last_msg_id);
        }

        await $ws->send_json({
            type           => 'resumed',
            session_id     => $session_id,
            user_id        => $session->{user_id},
            name           => $session->{name},
            rooms          => [keys %{$session->{rooms}}],
            missedMessages => \%missed_messages,
        });
    }
    else {
        my $username = sanitize_username($raw_name || 'Anonymous');
        # A new session always gets an id from the server: one the client
        # sent but the server does not know is never adopted.
        $session_id = _generate_session_id();

        $session = create_session($session_id, $username, $send_cb);

        await $ws->send_json({
            type       => 'connected',
            session_id => $session_id,
            user_id    => $session->{user_id},
            name       => $username,
            rooms      => [sort keys %{get_all_rooms()}],
        });
        return if $ws->is_closed;

        await _join_room($ws, $session_id, 'general');
    }
    return if $ws->is_closed;

    # Every room with its member count, whether this connection is new or a
    # resumed session (the resume message lists only the session's own rooms).
    await _send_room_list($ws, $session_id);
    return if $ws->is_closed;

    # Protocol-level pings keep proxies from closing an idle connection. The
    # server runs the timer; the browser also sends its own application
    # 'ping' messages, answered below with 'pong'.
    await $ws->keepalive(25);

    await $ws->each_json(async sub {
        my ($msg) = @_;
        await _handle_message($ws, $session_id, $msg);
    });
}

sub _generate_session_id {
    # Clients resume a session with its id, so it must not be guessable.
    return unpack('H*', PAGI::Utils::Random::secure_random_bytes(32));
}

async sub _handle_message {
    my ($ws, $session_id, $msg) = @_;

    my $session = get_session($session_id);
    return unless $session;

    my $type = $msg->{type} // 'message';

    if ($type eq 'message') {
        await _handle_chat_message($ws, $session_id, $msg);
    }
    elsif ($type eq 'join') {
        await _join_room($ws, $session_id, $msg->{room});
    }
    elsif ($type eq 'leave') {
        await _leave_room($ws, $session_id, $msg->{room});
    }
    elsif ($type eq 'typing') {
        await _handle_typing($session_id, $msg);
    }
    elsif ($type eq 'pm') {
        await _handle_private_message($ws, $session_id, $msg);
    }
    elsif ($type eq 'set_nick') {
        await _handle_nick_change($ws, $session_id, $msg);
    }
    elsif ($type eq 'get_rooms') {
        await _send_room_list($ws, $session_id);
    }
    elsif ($type eq 'get_users') {
        await _send_user_list($ws, $session_id, $msg->{room});
    }
    elsif ($type eq 'get_history') {
        await _send_history($ws, $session_id, $msg->{room});
    }
    elsif ($type eq 'ping') {
        update_session($session_id, { last_seen => time() });
        await $ws->send_json({ type => 'pong', ts => $msg->{ts} });
    }
    elsif ($type eq 'pong') {
        update_session($session_id, { last_seen => time() });
    }
}

async sub _handle_chat_message {
    my ($ws, $session_id, $msg) = @_;

    my $session = get_session($session_id) or return;
    my $room_name = $msg->{room} // 'general';
    my $text = $msg->{text} // '';

    unless ($session->{rooms}{$room_name}) {
        return await $ws->send_json({
            type    => 'error',
            message => "You are not in room: $room_name",
        });
    }

    # Handle slash commands
    if ($text =~ m{^/(\w+)(?:\s+(.*))?$}) {
        return await _handle_command($ws, $session_id, $1, $2, $room_name);
    }

    return unless length $text;

    my $stored = add_message($room_name, $session->{name}, $text, 'message');
    update_session($session_id, { last_message_id => $stored->{id} });

    # Clear typing indicator
    if ($session->{typing_in}) {
        update_session($session_id, { typing_in => undef });
        await _broadcast_to_room($room_name, {
            type   => 'typing',
            room   => $room_name,
            user   => $session->{name},
            typing => 0,
        }, $session_id);
    }

    await _broadcast_to_room($room_name, {
        type => 'message',
        room => $room_name,
        from => $session->{name},
        text => $text,
        ts   => $stored->{ts},
        id   => $stored->{id},
    });
}

async sub _handle_command {
    my ($ws, $session_id, $cmd, $args, $room_name) = @_;

    my $session = get_session($session_id) or return;
    $args //= '';

    if ($cmd eq 'help') {
        await $ws->send_json({
            type    => 'system',
            room    => $room_name,
            text    => "Available commands:\n" .
                       "/help - Show this help\n" .
                       "/rooms - List all rooms\n" .
                       "/users - List users in current room\n" .
                       "/join <room> - Join or create a room\n" .
                       "/leave - Leave current room\n" .
                       "/pm <user> <message> - Send private message\n" .
                       "/nick <name> - Change your nickname\n" .
                       "/me <action> - Send action message",
        });
    }
    elsif ($cmd eq 'rooms') {
        await _send_room_list($ws, $session_id);
    }
    elsif ($cmd eq 'users') {
        await _send_user_list($ws, $session_id, $room_name);
    }
    elsif ($cmd eq 'join' && $args) {
        my $new_room = sanitize_room_name($args);
        await _join_room($ws, $session_id, $new_room);
    }
    elsif ($cmd eq 'leave') {
        await _leave_room($ws, $session_id, $room_name);
    }
    elsif ($cmd eq 'pm' && $args =~ /^(\S+)\s+(.+)$/) {
        await _handle_private_message($ws, $session_id, { to => $1, text => $2 });
    }
    elsif ($cmd eq 'nick' && $args) {
        await _handle_nick_change($ws, $session_id, { name => $args });
    }
    elsif ($cmd eq 'me' && $args) {
        my $action_text = "* $session->{name} $args";
        my $stored = add_message($room_name, $session->{name}, $action_text, 'action');
        await _broadcast_to_room($room_name, {
            type => 'action',
            room => $room_name,
            from => $session->{name},
            text => $action_text,
            ts   => $stored->{ts},
            id   => $stored->{id},
        });
    }
    else {
        await $ws->send_json({
            type    => 'error',
            message => "Unknown command: /$cmd. Type /help for available commands.",
        });
    }
}

async sub _join_room {
    my ($ws, $session_id, $room_name) = @_;

    my $session = get_session($session_id) or return;
    $room_name = sanitize_room_name($room_name);

    if ($session->{rooms}{$room_name}) {
        return await $ws->send_json({
            type    => 'error',
            message => "You are already in room: $room_name",
        });
    }

    add_user_to_room($session_id, $room_name);

    await $ws->send_json({
        type    => 'joined',
        room    => $room_name,
        history => get_room_messages($room_name, 50),
        users   => get_room_users($room_name),
    });

    await _broadcast_to_room($room_name, {
        type  => 'user_joined',
        room  => $room_name,
        user  => $session->{name},
        users => get_room_users($room_name),
    }, $session_id);
}

async sub _leave_room {
    my ($ws, $session_id, $room_name) = @_;

    my $session = get_session($session_id) or return;

    if ($room_name eq 'general') {
        return await $ws->send_json({
            type    => 'error',
            message => "You cannot leave the general room",
        });
    }

    unless ($session->{rooms}{$room_name}) {
        return await $ws->send_json({
            type    => 'error',
            message => "You are not in room: $room_name",
        });
    }

    remove_user_from_room($session_id, $room_name);

    await $ws->send_json({
        type => 'left',
        room => $room_name,
    });

    await _broadcast_to_room($room_name, {
        type  => 'user_left',
        room  => $room_name,
        user  => $session->{name},
        users => get_room_users($room_name),
    });
}

async sub _handle_typing {
    my ($session_id, $msg) = @_;

    my $session = get_session($session_id) or return;
    my $room_name = $msg->{room} // 'general';
    my $typing = $msg->{typing} ? 1 : 0;

    update_session($session_id, { typing_in => $typing ? $room_name : undef });

    await _broadcast_to_room($room_name, {
        type   => 'typing',
        room   => $room_name,
        user   => $session->{name},
        typing => $typing,
    }, $session_id);
}

async sub _handle_private_message {
    my ($ws, $session_id, $msg) = @_;

    my $session = get_session($session_id) or return;
    my $to_name = $msg->{to} // '';
    my $text = $msg->{text} // '';

    return unless length $to_name && length $text;

    my $target = get_session_by_name($to_name);

    unless ($target) {
        return await $ws->send_json({
            type    => 'error',
            message => "User not found: $to_name",
        });
    }

    if ($target->{send_cb}) {
        await $target->{send_cb}->({
            type => 'pm',
            from => $session->{name},
            text => $text,
            ts   => time(),
        });
    }

    await $ws->send_json({
        type => 'pm_sent',
        to   => $to_name,
        text => $text,
        ts   => time(),
    });
}

async sub _handle_nick_change {
    my ($ws, $session_id, $msg) = @_;

    my $session = get_session($session_id) or return;
    my $new_name = sanitize_username($msg->{name} // '');
    my $old_name = $session->{name};

    return if $new_name eq $old_name;

    update_session($session_id, { name => $new_name });

    await $ws->send_json({
        type     => 'nick_changed',
        old_name => $old_name,
        new_name => $new_name,
    });

    for my $room_name (keys %{$session->{rooms}}) {
        add_message($room_name, 'system', "$old_name is now known as $new_name", 'system');
        await _broadcast_to_room($room_name, {
            type     => 'nick_changed',
            room     => $room_name,
            old_name => $old_name,
            new_name => $new_name,
            users    => get_room_users($room_name),
        }, $session_id);
    }
}

async sub _send_room_list {
    my ($ws, $session_id) = @_;

    my $rooms = get_all_rooms();
    await $ws->send_json({
        type  => 'room_list',
        rooms => [
            map {
                { name => $_->{name}, users => scalar(keys %{$_->{users}}) }
            }
            sort { $a->{name} cmp $b->{name} }
            values %$rooms
        ],
    });
}

async sub _send_user_list {
    my ($ws, $session_id, $room_name) = @_;

    my $users = get_room_users($room_name);
    await $ws->send_json({
        type  => 'user_list',
        room  => $room_name,
        users => $users,
    });
}

async sub _send_history {
    my ($ws, $session_id, $room_name) = @_;

    my $messages = get_room_messages($room_name, 100);
    await $ws->send_json({
        type     => 'history',
        room     => $room_name,
        messages => $messages,
    });
}

async sub _broadcast_to_room {
    my ($room_name, $data, $exclude_id) = @_;

    for my $session (@{ get_room_sessions($room_name) }) {
        next if defined $exclude_id && $session->{id} eq $exclude_id;
        next unless $session->{send_cb};

        # Best-effort and not awaited, so one slow client does not hold
        # up the rest of the room.
        $session->{send_cb}->($data);
    }
}

1;

__END__

# NAME

ChatApp::WebSocket - the chat's WebSocket handler

# SYNOPSIS

    use PAGI::Routing qw(websocket);
    websocket('/ws/chat' => \&ChatApp::WebSocket::chat);

# DESCRIPTION

`chat($ws)` receives one PAGI::WebSocket from the Router:

- `$ws->query` reads the session id, name and last message id from the URL.
- `$ws->on_close` runs cleanup on any disconnect, before or after accept.
- `$ws->send_json` and `$ws->each_json` handle JSON both ways.
- `$ws->keepalive` asks the server for protocol pings; no timer in app code.

# SEE ALSO

PAGI::WebSocket, PAGI::Routing
