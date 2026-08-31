package MyApp::API::Events;
use parent 'PAGI::Endpoint::Router';
use strict;
use warnings;
use Future::AsyncAwait;
use PAGI::State qw(app_state);

sub routes {
    my ($self, $r) = @_;
    $r->sse('/stream' => 'stream')->name('stream');
}

async sub stream {
    my ($self, $sse) = @_;
    my $state = app_state($sse)
        or die 'endpoint-router-demo requires Compose lifespan state';
    await $sse->send_event(
        event => 'ready',
        data  => { resource => $state->get('resource')->{name} },
    );
    await $sse->run;
}

1;
