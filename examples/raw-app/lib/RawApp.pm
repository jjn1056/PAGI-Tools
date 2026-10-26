package RawApp;

# A classic PAGI application in a module: a PAGI::App whose call is the
# application itself, called with ($scope, $receive, $send), and no Compose
# -- the shape for an application that speaks the protocol directly. It
# handles three scope types: lifespan (a counter put in the shared state at
# startup), http (two pages) and websocket (an echo). RawApp::Send holds the
# events it sends more than once.
#
# Run:  pagi-server -I examples/raw-app/lib --app examples/raw-app/lib/RawApp.pm --port 5000
# Try:  curl -i localhost:5000/
#       curl -i localhost:5000/hits        # counts up: the lifespan state
#       curl -i localhost:5000/nowhere     # 404
#       websocat ws://localhost:5000/echo
# Or one request, without a server:
#       perl -I examples/raw-app/lib examples/raw-app/lib/RawApp.pm GET /hits

use v5.40;
use parent 'PAGI::App';
use Future::AsyncAwait;
use RawApp::Send qw(drain_body send_text);

async sub call ($self, $scope, $receive, $send) {
    my $type = $scope->{type};
    return await $self->lifespan($scope, $receive, $send)  if $type eq 'lifespan';
    return await $self->http($scope, $receive, $send)      if $type eq 'http';
    return await $self->websocket($scope, $receive, $send) if $type eq 'websocket';
    # Refused with a plain response before sse.start: there is no stream here.
    return await send_text($send, 404, "No event stream here.\n") if $type eq 'sse';
    die "RawApp does not handle a $type scope\n";
}

# Startup puts a container in the shared state: each request's state is a
# shallow copy, so a count lives inside it rather than as a top-level value.
async sub lifespan ($self, $scope, $receive, $send) {
    while (1) {
        my $event = await $receive->();
        if ($event->{type} eq 'lifespan.startup') {
            $scope->{state}{hits} = { count => 0 };
            await $send->({ type => 'lifespan.startup.complete' });
        }
        elsif ($event->{type} eq 'lifespan.shutdown') {
            await $send->({ type => 'lifespan.shutdown.complete' });
            return;
        }
    }
}

async sub http ($self, $scope, $receive, $send) {
    await drain_body($receive);
    return await send_text($send, 405, "Method not allowed.\n", ['allow', 'GET, HEAD'])
        unless $scope->{method} eq 'GET' || $scope->{method} eq 'HEAD';

    my $path = $scope->{path};
    return await send_text($send, 200, "Hello from a classic PAGI application.\n") if $path eq '/';
    if ($path eq '/hits') {
        my $hits = ++$scope->{state}{hits}{count};
        return await send_text($send, 200, "Hits: $hits\n");
    }
    return await send_text($send, 404, "No such page: $path\n");
}

# Accepted only at /echo; elsewhere the handshake is refused with a plain
# response, before accept.
async sub websocket ($self, $scope, $receive, $send) {
    my $connect = await $receive->();
    return unless $connect->{type} eq 'websocket.connect';
    return await send_text($send, 404, "No socket here.\n") unless $scope->{path} eq '/echo';

    await $send->({ type => 'websocket.accept' });
    while (1) {
        my $frame = await $receive->();
        return if $frame->{type} eq 'websocket.disconnect';
        next unless $frame->{type} eq 'websocket.receive';
        await $send->({ type => 'websocket.send',
            defined $frame->{text} ? (text => "echo: $frame->{text}") : (bytes => $frame->{bytes} // '') });
    }
}

__PACKAGE__->run_if_script;
