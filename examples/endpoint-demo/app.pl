#!/usr/bin/env perl
#
# Endpoint Demo - Showcasing all three endpoint types with middleware
#
# Run: pagi-server -I lib examples/endpoint-demo/app.pl --port 5000
# Open: http://localhost:5000/
#

use strict;
use warnings;
use Future::AsyncAwait;
use Time::HiRes qw(time);

use PAGI::App::File;
use PAGI::App::Router;
use PAGI::Compose qw(compose);
use PAGI::Middleware::AccessLog;
use PAGI::Pages;


#---------------------------------------------------------
# HTTP Endpoint - REST API for messages
#---------------------------------------------------------
package MessageAPI {
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;
    use PAGI::Response::JSON;

    my @messages = (
        { id => 1, text => 'Hello, World!' },
        { id => 2, text => 'Welcome to PAGI Endpoints' },
    );
    my $next_id = 3;

    async sub get {
        my ($self, $request) = @_;
        return PAGI::Response::JSON->new(\@messages);
    }

    async sub post {
        my ($self, $request) = @_;
        my $data = await $request->json;
        my $message = { id => $next_id++, text => $data->{text} };
        push @messages, $message;

        # Notify SSE subscribers -- awaited, not fired and forgotten.
        await MessageEvents::broadcast($message);

        return PAGI::Response::JSON->new($message, status => 201);
    }
}

#---------------------------------------------------------
# WebSocket Endpoint - Echo chat
#---------------------------------------------------------
package EchoWS {
    use parent 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;

    sub encoding { 'json' }
    sub ping_interval { 25 }  # Keep connection alive

    async sub on_connect {
        my ($self, $websocket) = @_;
        await $websocket->accept;
        await $websocket->send_json({ type => 'connected', message => 'Welcome!' });
    }

    async sub on_receive {
        my ($self, $websocket, $data) = @_;
        await $websocket->send_json({
            type => 'echo',
            original => $data,
            timestamp => time(),
        });
    }

    sub on_disconnect {
        my ($self, $websocket, $code) = @_;
        print STDERR "WebSocket client disconnected: $code\n";
    }
}

#---------------------------------------------------------
# SSE Endpoint - Message notifications
#---------------------------------------------------------
package MessageEvents {
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;
    use PAGI::Stash qw(stash);

    sub keepalive_interval { 25 } # seconds

    my %subscribers; # In memory so has to be single process, no workers
    my $sub_id = 0;

    # Awaited, not fired and forgotten -- the caller (MessageAPI::post) awaits
    # this before responding, so a POST doesn't return before its own
    # notification has gone out. try_send_json never dies (it always
    # resolves 0 or 1), but a failed send does NOT run on_disconnect, so
    # reaping a dead subscriber has to be Future-aware too: check the result
    # per subscriber and drop it here rather than relying on a close
    # callback that a send failure alone won't trigger.
    async sub broadcast {
        my ($message) = @_;
        my @sends;
        for my $id (keys %subscribers) {
            my $sse = $subscribers{$id};
            push @sends, $sse->try_send_json($message)->on_done(sub {
                my ($ok) = @_;
                delete $subscribers{$id} unless $ok;
            });
        }
        await Future->wait_all(@sends) if @sends;
    }

    async sub on_connect {
        my ($self, $sse) = @_;
        my $id = ++$sub_id;
        $subscribers{$id} = $sse;
        stash($sse)->set(sub_id => $id);

        await $sse->send_event(
            event => 'connected',
            data  => { subscriber_id => $id },
        );
    }

    sub on_disconnect {
        my ($self, $sse) = @_;
        my $id = stash($sse)->get('sub_id', 'unknown');
        delete $subscribers{$id};
    }
}

#---------------------------------------------------------
# Middleware Examples
#---------------------------------------------------------

# 1. PAGI::Middleware instance - request logging
my $access_log = PAGI::Middleware::AccessLog->new(
    format => 'tiny',
    logger => sub { print STDERR @_ },
);

# 2. Coderef middleware - request timing
my $timing = sub {
    my ($app) = @_;
    async sub {
        my ($scope, $receive, $send) = @_;
        my $start = time();
        await $app->($scope, $receive, $send);
        my $duration = (time() - $start) * 1000;
        warn sprintf "[timing] %s %s %.2fms\n",
            $scope->{method} // 'WS/SSE', $scope->{path}, $duration;
    };
};

# 3. Coderef middleware - JSON content-type validation for POST
my $require_json = sub {
    my ($app) = @_;
    async sub {
        my ($scope, $receive, $send) = @_;

        # Only check POST requests
        if (($scope->{method} // '') eq 'POST') {
            my $content_type = '';
            for my $h (@{$scope->{headers} // []}) {
                if (lc($h->[0]) eq 'content-type') {
                    $content_type = $h->[1];
                    last;
                }
            }

            unless ($content_type =~ m{application/json}i) {
                my $response = PAGI::Pages->unsupported_media_type($scope,
                    as     => 'json',
                    detail => 'Content-Type must be application/json');
                return await $response->respond($scope, $receive, $send);
            }
        }

        await $app->($scope, $receive, $send);
    };
};

#---------------------------------------------------------
# Main Router - Unified routing for all protocols
#---------------------------------------------------------
my $router = PAGI::App::Router->new;

# Mount API endpoint with middleware:
# - $access_log: logs each request (PAGI::Middleware instance)
# - $require_json: validates Content-Type for POST (coderef middleware)
$router->mount('/api/messages',
    app        => MessageAPI->to_app,
    middleware => [$access_log, $require_json],
);

# WebSocket with timing middleware
$router->mount('/ws/echo',
    app        => EchoWS->to_app,
    middleware => [$access_log, $timing],
);

# SSE with timing middleware
$router->mount('/events',
    app        => MessageEvents->to_app,
    middleware => [$timing],
);

# Static files as fallback for everything else (no middleware)
$router->mount('/', app => PAGI::App::File->from_app_path('public'));

compose(app => $router);
