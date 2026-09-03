package MyApp::API::Events;
use parent 'PAGI::Endpoint::SSE';
use strict;
use warnings;
use Future::AsyncAwait;
async sub on_connect {
    my ($self, $sse) = @_;
    my $state = $sse->state
        or die 'endpoint-class-demo requires Compose lifespan state';
    await $sse->send_event(
        event => 'ready',
        data  => { resource => $state->get('resource')->{name} },
    );
}

1;
