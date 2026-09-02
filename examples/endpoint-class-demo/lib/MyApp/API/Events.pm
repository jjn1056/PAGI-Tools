package MyApp::API::Events;
use parent 'PAGI::Endpoint::SSE';
use strict;
use warnings;
use Future::AsyncAwait;
use PAGI::State qw(app_state);

async sub on_connect {
    my ($self, $sse) = @_;
    my $state = app_state($sse)
        or die 'endpoint-class-demo requires Compose lifespan state';
    await $sse->send_event(
        event => 'ready',
        data  => { resource => $state->get('resource')->{name} },
    );
}

1;
