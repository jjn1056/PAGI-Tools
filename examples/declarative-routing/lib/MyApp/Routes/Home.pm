package MyApp::Routes::Home;

use strict;
use warnings;
use Future::AsyncAwait;
use PAGI::Pages ();
use PAGI::Response qw(html_response json_response);
use PAGI::Routing::URL qw(path_for url_for);

async sub home {
    my ($request) = @_;
    return html_response('<h1>Declarative PAGI</h1>');
}

async sub show_item {
    my ($request) = @_;
    my $id = $request->path_param('id');

    return json_response({
        id   => $id,
        path => path_for($request, '/api/item', { id => $id }),
        url  => url_for($request, '/api/item', { id => $id }),
    });
}

async sub not_found {
    my ($request) = @_;
    return PAGI::Pages->not_found(
        detail => 'No route matched');
}

1;
