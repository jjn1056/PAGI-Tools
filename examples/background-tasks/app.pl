#!/usr/bin/env perl
#
# Background Tasks Example
#
# Demonstrates different patterns for running work after sending a response.
#
# IMPORTANT: Understand the difference between:
#   1. Async I/O (non-blocking) - Use fire-and-forget Futures
#   2. Blocking/CPU work - Use IO::Async::Function (runs in subprocess)
#
# Run: pagi-server examples/background-tasks/app.pl --port 5000
#
# Test:
#   curl http://localhost:5000/async      # Fire-and-forget async I/O
#   curl http://localhost:5000/blocking   # CPU-bound work in subprocess
#   curl http://localhost:5000/bad        # DON'T DO THIS - blocks event loop
#
#   curl -X POST http://localhost:5000/signup -d '{"email":"test@example.com"}'
#

use strict;
use warnings;
use Future::AsyncAwait;

use PAGI::App::Router;
use PAGI::Response;
use PAGI::Request;

#---------------------------------------------------------
# PATTERN 1: Async I/O (Non-Blocking)
#
# For network calls, database queries, file I/O that use
# async libraries. These yield control back to the event
# loop while waiting, so they don't block other requests.
#---------------------------------------------------------

# Simulated async email API (would use async HTTP client in practice)
async sub send_welcome_email {
    my ($email) = @_;
    warn "[async] Sending welcome email to $email...\n";

    # This is NON-BLOCKING - yields to event loop while "waiting"
    # In real code: await $http_client->post_async($email_api, ...)
    await IO::Async::Loop->new->delay_future(after => 2);

    warn "[async] Email sent to $email!\n";
}

# Simulated async analytics API
async sub log_to_analytics {
    my ($event, $data) = @_;
    warn "[async] Logging '$event' to analytics...\n";
    await IO::Async::Loop->new->delay_future(after => 1);
    warn "[async] Analytics logged!\n";
}

#---------------------------------------------------------
# PATTERN 2: Blocking/CPU-Bound Work
#
# For CPU-intensive computation, synchronous libraries,
# or any code that would block. Run in a subprocess via
# IO::Async::Function to avoid blocking the event loop.
#---------------------------------------------------------

my $cpu_worker;

sub get_cpu_worker {
    return $cpu_worker if $cpu_worker;

    require IO::Async::Function;
    $cpu_worker = IO::Async::Function->new(
        code => sub {
            my ($task_name, $duration) = @_;
            warn "[subprocess] Starting CPU task: $task_name\n";

            # This sleep (or any blocking work) runs in a CHILD PROCESS
            # so it doesn't block the main event loop
            sleep $duration;

            warn "[subprocess] Completed: $task_name\n";
            return "Result of $task_name";
        },
    );

    IO::Async::Loop->new->add($cpu_worker);
    return $cpu_worker;
}

# Run blocking work in subprocess (fire-and-forget)
sub run_blocking_task {
    my ($task_name, $duration) = @_;
    get_cpu_worker()->call(
        args => [$task_name, $duration],
        on_result => sub {
            my ($result) = @_;
            warn "[main] Subprocess returned: $result\n";
        },
        on_error => sub {
            my ($error) = @_;
            warn "[main] Subprocess error: $error\n";
        },
    );
}

#---------------------------------------------------------
# PATTERN 3: Quick Sync Work (loop->later)
#
# For very fast synchronous operations that just need to
# run after the response is sent. Must be FAST (<10ms).
#
# WARNING: Any blocking calls here will block ALL requests!
#---------------------------------------------------------

sub quick_sync_task {
    my ($message) = @_;
    warn "[sync] Quick task: $message\n";
    # Only do FAST things here - no sleep, no blocking I/O!
}

#---------------------------------------------------------
# HTTP Endpoints
#---------------------------------------------------------

my $router = PAGI::App::Router->new;

# Index page
$router->get('/' => async sub {
    my ($scope, $receive, $send) = @_;
    my $res = PAGI::Response->new($send);

    await $res->html(<<'HTML');
<!DOCTYPE html>
<html>
<head><title>Background Tasks Demo</title></head>
<body>
<h1>Background Tasks Demo</h1>
<p>Watch the server console for background task output.</p>

<h2>Endpoints</h2>
<ul>
  <li><a href="/async">/async</a> - Fire-and-forget async I/O (non-blocking)</li>
  <li><a href="/blocking">/blocking</a> - CPU work in subprocess (IO::Async::Function)</li>
  <li><a href="/bad">/bad</a> - Example of what NOT to do</li>
</ul>

<h2>POST /signup</h2>
<form id="signup">
  <input type="email" name="email" placeholder="email@example.com" required>
  <button type="submit">Sign Up</button>
</form>
<pre id="result"></pre>

<script>
document.getElementById('signup').onsubmit = async (e) => {
  e.preventDefault();
  const email = e.target.email.value;
  const res = await fetch('/signup', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({email})
  });
  document.getElementById('result').textContent = await res.text();
};
</script>
</body>
</html>
HTML
});

# GOOD: Fire-and-forget async I/O
$router->get('/async' => async sub {
    my ($scope, $receive, $send) = @_;
    my $res = PAGI::Response->new($send);

    # Response goes out immediately
    await $res->json({
        status => 'ok',
        message => 'Response sent! Async tasks running in background.',
    });

    # These return Futures - we just don't await them
    # They run concurrently, yielding to the event loop as needed
    send_welcome_email('user@example.com');
    log_to_analytics('page_view', { path => '/' });

    # Quick sync work - runs after this handler yields
    $res->loop->later(sub {
        quick_sync_task("Logging request");
    });
});

# GOOD: CPU-bound work in subprocess
$router->get('/blocking' => async sub {
    my ($scope, $receive, $send) = @_;
    my $res = PAGI::Response->new($send);

    # Response goes out immediately
    await $res->json({
        status => 'ok',
        message => 'Response sent! Heavy computation running in subprocess.',
    });

    # Fire-and-forget: runs in child process, doesn't block event loop
    run_blocking_task("heavy_computation", 3);
    run_blocking_task("image_processing", 2);
});

# BAD: Don't do this! Demonstrates what NOT to do.
$router->get('/bad' => async sub {
    my ($scope, $receive, $send) = @_;
    my $res = PAGI::Response->new($send);

    await $res->json({
        status => 'ok',
        message => 'Response sent, but server is now blocked for 2 seconds!',
    });

    # !!! BAD !!! - This blocks the ENTIRE event loop!
    # No other requests can be processed during this sleep.
    #
    # $res->loop->later(sub {
    #     sleep 2;  # BLOCKS EVERYTHING
    # });
    #
    # Instead, use IO::Async::Function (see /blocking endpoint)

    warn "[WARNING] The /bad endpoint exists to show what NOT to do.\n";
    warn "[WARNING] See the source code for explanation.\n";
});

# Real-world example: User signup with background tasks
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

    # Fire-and-forget async tasks (non-blocking)
    send_welcome_email($email);
    log_to_analytics('signup', { email => $email });

    # Quick sync logging
    $res->loop->later(sub {
        quick_sync_task("New signup: $email");
    });

    # If you had CPU-intensive work (password hashing already done,
    # but maybe generating a PDF welcome packet):
    # run_blocking_task("generate_welcome_pdf", 5);
});

# WebSocket with background processing
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

        # For async I/O processing:
        log_to_analytics('ws_message', { text => $text });

        # For CPU-intensive processing (e.g., NLP, image analysis):
        # run_blocking_task("analyze_message", 1);
    });
});

$router->to_app;
