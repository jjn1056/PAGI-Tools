package MyApp::Routes::Home;

use strict;
use warnings;
use Future::AsyncAwait;
use PAGI::Pages;
use PAGI::Response;
use PAGI::Routing::URL qw(path_for url_for);

async sub home {
    my ($request) = @_;
    return PAGI::Response->html('<h1>Declarative PAGI</h1>');
}

async sub show_item {
    my ($request) = @_;
    my $id = $request->path_param('id');

    return PAGI::Response->json({
        id   => $id,
        path => path_for($request, '/api/item', { id => $id }),
        url  => url_for($request, '/api/item', { id => $id }),
    });
}

async sub not_found {
    my ($request) = @_;
    return PAGI::Pages->not_found($request,
        detail => 'No route matched');
}

1;
