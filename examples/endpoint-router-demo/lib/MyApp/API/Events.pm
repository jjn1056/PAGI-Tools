package MyApp::API::Events;
use parent 'PAGI::Endpoint::Router';
use strict;
use warnings;
use Future::AsyncAwait;

sub routes {
    my ($self, $r) = @_;
    $r->sse('/stream' => 'stream')->name('stream');
}

async sub stream {
    my ($self, $c) = @_;
    await $c->send_event(
        event => 'ready',
        data  => { resource => $c->state->{resource}{name} },
    );
    await $c->sse->run;
}

1;
