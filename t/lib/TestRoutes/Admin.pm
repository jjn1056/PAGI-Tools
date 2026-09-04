package TestRoutes::Admin;

use strict;
use warnings;
use PAGI::Response::Text ();
use PAGI::Routing qw(route router);

sub to_app {
    return router(routes => [
        route('/' => sub {
            return PAGI::Response::Text->new('admin_dashboard');
        }),
        route('/settings' => sub {
            return PAGI::Response::Text->new('admin_settings');
        }),
    ])->to_app;
}

1;
