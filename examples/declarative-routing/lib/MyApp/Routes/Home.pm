package MyApp::Routes::Home;

use strict;
use warnings;
use Future::AsyncAwait;
use PAGI::Pages;

async sub home {
    my ($c) = @_;
    return $c->html('<h1>Declarative PAGI</h1>');
}

async sub show_item {
    my ($c) = @_;
    my $id = $c->path_param('id');

    return $c->json({
        id   => $id,
        path => $c->path_for('/api/item', { id => $id }),
        url  => $c->url_for('/api/item', { id => $id }),
    });
}

async sub not_found {
    my ($c) = @_;
    return PAGI::Pages->not_found($c,
        detail => 'No route matched');
}

async sub method_not_allowed {
    my ($c, $trace) = @_;
    return PAGI::Pages->method_not_allowed($c,
        allow  => $trace->allowed_methods,
        detail => 'Method not allowed');
}

1;
