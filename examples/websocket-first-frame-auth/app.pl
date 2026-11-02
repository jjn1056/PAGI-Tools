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
#   1. Hold the handler's accept until the token is checked.
#   2. Read the token from the raw receive, skipping websocket.connect.
#   3. After the 4401 close, drop the handler's sends.
#   4. After the 4401 close, hand the handler's receive the disconnect.
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

        # Set once the connection is over for the handler: the disconnect
        # its receive gets from then on.
        my $ended;

        my $checked_send = async sub {
            my ($event) = @_;
            # Rule 3: once the connection is over for the handler, its sends
            # go nowhere; a send after this middleware's close would fail.
            return if $ended;
            await $send->($event);
            return unless $event->{type} eq 'websocket.accept';

            # Rule 1: the handler's accept returns only once the token is
            # checked, so nothing it sends after accept reaches a client
            # that has not shown one.
            my $first = await $receive->();
            # Rule 2: PAGI::WebSocket does not read the handshake event, so
            # it is still first.
            $first = await $receive->() while $first->{type} eq 'websocket.connect';

            # The client left before it sent a token.
            if ($first->{type} eq 'websocket.disconnect') {
                $ended = $first;
                return;
            }
            return if defined $first->{text} && $VALID_TOKEN{ $first->{text} };

            await $send->({ type => 'websocket.close', code => 4401, reason => 'unauthorized' });
            $ended = { type => 'websocket.disconnect', code => 4401, reason => 'unauthorized' };
            return;
        };

        # Rule 4: after the close, a frame the client sent before it saw
        # the close must not reach the handler.
        my $checked_receive = async sub {
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
