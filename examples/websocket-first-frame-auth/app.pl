#!/usr/bin/env perl
#
# WebSocket first-frame authentication as a middleware.
#
# A browser's WebSocket cannot send an Authorization header, so the client
# sends its token as its first message: the middleware lets the handler's
# accept through, reads that message, and closes with 4401 if the token is
# wrong. The route's handler uses its own PAGI::WebSocket as usual and never
# sees the token.
#
# A connection has one helper, and the route builds it, so the middleware
# builds none: it wraps the raw send and receive. Four rules make that work;
# the README explains each.
#
#   1. Every send and receive of the handler's waits for the token check.
#   2. Read the token from the raw receive, skipping websocket.connect.
#   3. After the 4401 close, drop the handler's sends.
#   4. After the 4401 close, the handler's receive skips the client's
#      remaining frames and gets the server's disconnect.
#
# Run:  pagi-server --app examples/websocket-first-frame-auth/app.pl --port 5000
# Try:  websocat ws://localhost:5000/    then type let-me-in, then anything
#
use strict;
use warnings;
use Future::AsyncAwait;
use PAGI::Tools qw(compose middleware websocket);

# The tokens this demo accepts. A real application looks the token up in its
# own store, or verifies a signed one.
my %VALID_TOKEN = ('let-me-in' => 1);

sub first_frame_auth {
    my ($app) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        return await $app->($scope, $receive, $send)
            unless $scope->{type} eq 'websocket';

        # $checked: the token check, started by the handler's accept.
        # $closed: this middleware closed with 4401.
        # $ended: the server's disconnect, once it has been read.
        my ($checked, $closed, $ended);

        my $check = async sub {
            my ($accept) = @_;
            await $send->($accept);
            # Rule 2: PAGI::WebSocket does not read the handshake event, so
            # it is still first.
            my $first = await $receive->();
            $first = await $receive->() while $first->{type} eq 'websocket.connect';

            # The client left before it sent a token.
            if ($first->{type} eq 'websocket.disconnect') {
                $ended = $first;
                return;
            }
            return if defined $first->{text} && $VALID_TOKEN{ $first->{text} };

            await $send->({ type => 'websocket.close', code => 4401, reason => 'unauthorized' });
            $closed = 1;
            return;
        };

        my $checked_send = async sub {
            my ($event) = @_;
            if ($event->{type} eq 'websocket.accept') {
                $checked = $check->($event);
                return await $checked;
            }
            # Rule 1: a helper may send while its accept is pending; the
            # send waits for the check.
            await $checked if $checked;
            # Rule 3: a send after this middleware's close would fail.
            return if $closed || $ended;
            await $send->($event);
        };

        my $checked_receive = async sub {
            # Rule 1: so does a receive, which would otherwise take the token.
            await $checked if $checked;
            # Rule 4: after the close, the client's remaining frames are
            # skipped until the server reports the connection's end.
            while ($closed && !$ended) {
                my $event = await $receive->();
                $ended = $event if $event->{type} eq 'websocket.disconnect';
            }
            return {%$ended} if $ended;
            return await $receive->();
        };

        await $app->($scope, $checked_receive, $checked_send);
    };
}

async sub echo {
    my ($ws) = @_;
    await $ws->accept;
    await $ws->each_text(async sub {
        my ($text) = @_;
        await $ws->send_text("echo: $text");
    });
}

compose(
    routes => [websocket('/' => \&echo)],
    middleware => [middleware(\&first_frame_auth)],
);
