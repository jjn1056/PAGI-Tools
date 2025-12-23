#!/usr/bin/env perl
#
# Background Tasks Example
#
# Demonstrates running tasks after the response is sent,
# without blocking the client.
#
# Run: pagi-server examples/background-tasks/app.pl --port 5000
#
# Test:
#   curl http://localhost:5000/           # Instant response, task runs after
#   curl -X POST http://localhost:5000/signup -d '{"email":"test@example.com"}'
#

use strict;
use warnings;
use Future::AsyncAwait;

use PAGI::App::Router;
use PAGI::Response;
use PAGI::Request;

#---------------------------------------------------------
# Simulated slow operations (would be real I/O in practice)
#---------------------------------------------------------

async sub send_welcome_email {
    my ($email) = @_;
    warn "[background] Sending welcome email to $email...\n";
    # Simulate slow email API
    await IO::Async::Loop->new->delay_future(after => 2);
    warn "[background] Email sent to $email!\n";
}

async sub log_to_analytics {
    my ($event, $data) = @_;
    warn "[background] Logging '$event' to analytics...\n";
    await IO::Async::Loop->new->delay_future(after => 1);
    warn "[background] Analytics logged!\n";
}

sub notify_slack {
    my ($message) = @_;
    warn "[background] Posting to Slack: $message\n";
    # Sync task - just runs
}

#---------------------------------------------------------
# HTTP Endpoints
#---------------------------------------------------------

my $router = PAGI::App::Router->new;

# Simple example - fire and forget
$router->get('/' => async sub {
    my ($scope, $receive, $send) = @_;
    my $res = PAGI::Response->new($send);

    # Response goes out immediately
    await $res->json({ status => 'ok', message => 'Response sent!' });

    # These run AFTER the response, client doesn't wait
    $res->loop->later(sub {
        warn "[background] Task 1 starting...\n";
        sleep 1;  # Simulated work
        warn "[background] Task 1 done!\n";
    });

    $res->loop->later(sub {
        warn "[background] Task 2 starting...\n";
        sleep 1;
        warn "[background] Task 2 done!\n";
    });
});

# Signup with async background tasks
$router->post('/signup' => async sub {
    my ($scope, $receive, $send) = @_;
    my $req = PAGI::Request->new($scope, $receive);
    my $res = PAGI::Response->new($send);

    my $data = await $req->json;
    my $email = $data->{email} // 'unknown@example.com';

    # Respond immediately - user doesn't wait for email
    await $res->status(201)->json({
        status => 'created',
        message => "Account created! Check $email for welcome email.",
    });

    # Fire-and-forget async tasks
    my $loop = $res->loop;

    # Async task - returns a Future, we don't await it
    send_welcome_email($email);  # Runs in background

    # Another async task
    log_to_analytics('signup', { email => $email });

    # Sync task via loop->later
    $loop->later(sub {
        notify_slack("New signup: $email");
    });
});

# Show how it works with WebSocket too
$router->mount('/ws' => async sub {
    my ($scope, $receive, $send) = @_;
    return unless $scope->{type} eq 'websocket';

    require PAGI::WebSocket;
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    await $ws->accept;
    await $ws->send_text('Connected! Send a message.');

    await $ws->each_text(sub {
        my ($text) = @_;

        # Respond immediately
        $ws->try_send_text("Got: $text");

        # Process in background without blocking next message
        $ws->loop->later(sub {
            warn "[background] Processing WebSocket message: $text\n";
            # Heavy processing here...
        });
    });
});

$router->to_app;
