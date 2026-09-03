package MyApp::StatusSocket;
use parent 'PAGI::Endpoint::WebSocket';
use strict;
use warnings;
use Future::AsyncAwait;

sub encoding { return 'json' }

async sub on_connect {
    my ($self, $websocket) = @_;
    await $websocket->accept;

    my $state = $websocket->state
        or die 'endpoint-class-demo requires Compose lifespan state';
    await $websocket->send_json({
        type     => 'ready',
        resource => $state->get('resource')->{name},
    });
}

async sub on_receive {
    my ($self, $websocket, $message) = @_;
    my $state = $websocket->state
        or die 'endpoint-class-demo requires Compose lifespan state';
    $state->get('metrics')->{websocket_messages}++;
    await $websocket->send_json({ type => 'echo', data => $message });
}

1;
