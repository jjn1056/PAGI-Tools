package MyApp::Routes::Home;

use strict;
use warnings;
use Future::AsyncAwait;

async sub home {
    my ($c) = @_;
    return $c->html('<h1>Declarative PAGI</h1>');
}

async sub show_item {
    my ($c) = @_;
    my $id = $c->path_param('id');

    return $c->json({
        id   => $id,
        path => $c->path_for('api.item', { id => $id }),
        url  => $c->url_for('api.item', { id => $id }),
    });
}

async sub not_found {
    my ($c) = @_;
    return $c->json({ error => 'No route matched' });
}

async sub method_not_allowed {
    my ($c) = @_;
    return $c->json({
        error => 'Method not allowed',
        allow => $c->response->header('Allow'),
    });
}

1;
