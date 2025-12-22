#!/usr/bin/env perl
#
# Endpoint Demo - Showcasing all three endpoint types
#
# Run: pagi-server --app examples/endpoint-demo/app.pl --port 5000
# Open: http://localhost:5000/
#

use strict;
use warnings;
use Future::AsyncAwait;
use File::Basename qw(dirname);
use File::Spec;

use lib 'lib';
use PAGI::App::File;
use PAGI::App::Router;

#---------------------------------------------------------
# HTTP Endpoint - REST API for messages
#---------------------------------------------------------
package MessageAPI {
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;

    my @messages = (
        { id => 1, text => 'Hello, World!' },
        { id => 2, text => 'Welcome to PAGI Endpoints' },
    );
    my $next_id = 3;

    async sub get {
        my ($self, $req, $res) = @_;
        await $res->json(\@messages);
    }

    async sub post {
        my ($self, $req, $res) = @_;
        my $data = await $req->json;
        my $message = { id => $next_id++, text => $data->{text} };
        push @messages, $message;

        # Notify SSE subscribers
        MessageEvents::broadcast($message);

        await $res->status(201)->json($message);
    }
}

#---------------------------------------------------------
# WebSocket Endpoint - Echo chat
#---------------------------------------------------------
package EchoWS {
    use parent 'PAGI::Endpoint::WebSocket';
    use Future::AsyncAwait;

    sub encoding { 'json' }

    async sub on_connect {
        my ($self, $ws) = @_;
        await $ws->accept;
        await $ws->send_json({ type => 'connected', message => 'Welcome!' });
    }

    async sub on_receive {
        my ($self, $ws, $data) = @_;
        await $ws->send_json({
            type => 'echo',
            original => $data,
            timestamp => time(),
        });
    }

    sub on_disconnect {
        my ($self, $ws, $code) = @_;
        print STDERR "WebSocket client disconnected: $code\n";
    }
}

#---------------------------------------------------------
# SSE Endpoint - Message notifications
#---------------------------------------------------------
package MessageEvents {
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;

    sub keepalive_interval { 25 }

    my %subscribers;
    my $sub_id = 0;

    sub broadcast {
        my ($message) = @_;
        for my $sse (values %subscribers) {
            $sse->try_send_json($message);
        }
    }

    async sub on_connect {
        my ($self, $sse) = @_;
        my $id = ++$sub_id;
        $subscribers{$id} = $sse;
        $sse->stash->{sub_id} = $id;

        await $sse->send_event(
            event => 'connected',
            data  => { subscriber_id => $id },
        );
    }

    sub on_disconnect {
        my ($self, $sse) = @_;
        delete $subscribers{$sse->stash->{sub_id}};
        print STDERR "SSE client disconnected\n";
    }
}

#---------------------------------------------------------
# Main Router
#---------------------------------------------------------
my $static = PAGI::App::File->new(
    root => File::Spec->catdir(dirname(__FILE__), 'public')
)->to_app;

my $message_api = MessageAPI->to_app;
my $echo_ws = EchoWS->to_app;
my $events_sse = MessageEvents->to_app;

# HTTP router with API route and static file fallback
my $http_router = PAGI::App::Router->new(not_found => $static);
$http_router->get('/api/messages' => $message_api);
$http_router->post('/api/messages' => $message_api);

my $http_app = $http_router->to_app;

# Main app dispatches by scope type
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    my $type = $scope->{type} // 'http';

    if ($type eq 'http') {
        return await $http_app->($scope, $receive, $send);
    }

    if ($type eq 'websocket' && $scope->{path} eq '/ws/echo') {
        return await $echo_ws->($scope, $receive, $send);
    }

    if ($type eq 'sse' && $scope->{path} eq '/events') {
        return await $events_sse->($scope, $receive, $send);
    }

    die "Unknown route: $type $scope->{path}";
};

$app;
