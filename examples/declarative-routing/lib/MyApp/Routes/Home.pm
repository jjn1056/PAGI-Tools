package MyApp::Routes::Home;

use strict;
use warnings;
use Future::AsyncAwait;
use PAGI::Response qw(response);
use PAGI::Routing::URL qw(path_for url_for);

async sub home {
    my ($request) = @_;
    return response('HTML', '<h1>Declarative PAGI</h1>');
}

async sub show_item {
    my ($request) = @_;
    my $id = $request->path_param('id');

    return response('JSON', {
        id   => $id,
        path => path_for($request, '/api/item', { id => $id }),
        url  => url_for($request, '/api/item', { id => $id }),
    });
}

1;
