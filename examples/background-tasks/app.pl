#!/usr/bin/env perl
#
# Background Tasks Example
#
# Demonstrates different patterns for running work after sending a response.
#
# IMPORTANT: Understand the difference between:
#   1. Async I/O (non-blocking) - hand the Future to a PAGI::FutureOwner
#   2. Blocking/CPU work - Use IO::Async::Function (runs in subprocess)
#
# Every route is an ordinary handler: it starts its background work, then
# returns its Response.
#
# Run: pagi-server --app examples/background-tasks/app.pl --port 5000
#
# Test:
#   curl http://localhost:5000/async      # Fire-and-forget async I/O
#   curl http://localhost:5000/blocking   # CPU work in subprocess
#
#   curl -X POST http://localhost:5000/signup -d '{"email":"test@example.com"}'
#

use strict;
use warnings;
use Future::AsyncAwait;
use Future::IO;    # pagi-server binds the implementation

use PAGI::Compose qw(compose);
use PAGI::FutureOwner;
use PAGI::Routing qw(route websocket);
use PAGI::Response qw(response);

# Work the client does not wait for belongs to $background, which reports
# failures and lets shutdown wait for it.
my $background = PAGI::FutureOwner->new(
    on_failure => sub { warn "Background task failed: $_[0]" },
);

#---------------------------------------------------------
# PATTERN 1: Async I/O (Non-Blocking)
#
# For network calls, database queries, file I/O that use
# async libraries. These yield control back to the event
# loop while waiting, so they don't block other requests.
#
# Hand each one to $background rather than dropping it.
#---------------------------------------------------------

# Simulated async email API (would use async HTTP client in practice)
async sub send_welcome_email {
    my ($email) = @_;
    warn "[async] Sending welcome email to $email...\n";

    # This is NON-BLOCKING - yields to event loop while "waiting"
    # In real code: await $http_client->post_async($email_api, ...)
    await Future::IO->sleep(2);

    warn "[async] Email sent to $email!\n";
}

# Simulated async analytics API
async sub log_to_analytics {
    my ($event, $data) = @_;
    warn "[async] Logging '$event' to analytics...\n";
    await Future::IO->sleep(1);
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
            warn "[subprocess $$] Starting CPU task: $task_name\n";

            # This sleep (or any blocking work) runs in a CHILD PROCESS
            # so it doesn't block the main event loop
            sleep $duration;

            warn "[subprocess $$] Completed: $task_name\n";
            return "Result of $task_name";
        },
    );

    IO::Async::Loop->new->add($cpu_worker);
    return $cpu_worker;
}

# Run blocking work in subprocess (fire-and-forget)
sub run_blocking_task {
    my ($task_name, $duration) = @_;
    my $f = get_cpu_worker()->call(args => [$task_name, $duration]);
    $f->on_done(sub {
        my ($result) = @_;
        warn "[main] Subprocess returned: $result\n";
    });
    $background->adopt($f);
}

#---------------------------------------------------------
# PATTERN 3: Quick Sync Work
#
# For very fast synchronous bookkeeping. It runs in the
# handler, just before the Response is returned, so it
# delays that response by however long it takes.
#
# Must be FAST (<10ms) - blocking calls block ALL requests!
#---------------------------------------------------------

sub quick_sync_task {
    my ($message) = @_;
    warn "[sync] Quick task: $message\n";
    # Only do FAST things here - no sleep, no blocking I/O!
}

#---------------------------------------------------------
# Handlers
#
# Each starts its background work and returns its Response. Background work is
# asynchronous or runs in a subprocess, so the response is not held up by it.
#---------------------------------------------------------

# GOOD: Fire-and-forget async I/O
sub async_tasks {
    my ($request) = @_;

    # Not awaited: $background owns it.
    $background->adopt(send_welcome_email('user@example.com'));
    $background->adopt(log_to_analytics('page_view', { path => '/' }));

    quick_sync_task("Logging request");

    return response('JSON', {
        status  => 'ok',
        message => 'Response sent! Async tasks running in background.',
    });
}

# GOOD: CPU-bound work in subprocess
sub blocking_tasks {
    my ($request) = @_;

    # Fire-and-forget: runs in child processes, doesn't block the event loop
    run_blocking_task("heavy_computation", 3);
    run_blocking_task("image_processing", 2);

    return response('JSON', {
        status  => 'ok',
        message => 'Response sent! Heavy computation running in subprocess.',
    });
}

# Real-world example: user signup with background tasks
async sub signup {
    my ($request) = @_;

    my $data = await $request->json;
    my $email = $data->{email} // 'unknown@example.com';

    # The user does not wait for the email: it is sent in the background.
    $background->adopt(send_welcome_email($email));
    $background->adopt(log_to_analytics('signup', { email => $email }));

    quick_sync_task("New signup: $email");

    # For CPU-intensive work (e.g., generating PDF):
    # run_blocking_task("generate_welcome_pdf", 5);

    return response('JSON', {
        status  => 'created',
        message => "Account created! Check $email for welcome email.",
    }, status => 201);
}

# WebSocket with background processing
async sub messages {
    my ($ws) = @_;

    await $ws->accept;
    await $ws->send_text('Connected! Send a message.');

    await $ws->each_text(async sub {
        my ($text) = @_;

        # The reply is part of the conversation, so it is awaited.
        await $ws->try_send_text("Got: $text");

        # Background work is not awaited: $background owns it.
        $background->adopt(log_to_analytics('ws_message', { text => $text }));

        # For CPU-intensive processing (e.g., NLP, image analysis):
        # run_blocking_task("analyze_message", 1);
    });
}

compose(routes => [

# Index page
route('/' => sub {
    return response('HTML', <<'HTML');
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
}),

route('/async'    => \&async_tasks),
route('/blocking' => \&blocking_tasks),
route('/signup'   => \&signup, methods => ['POST']),
websocket('/ws'   => \&messages),
], lifespan => {
    # Work still running finishes before the process exits.
    shutdown => async sub { await $background->settled },
});
