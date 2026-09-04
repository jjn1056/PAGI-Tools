package TestRoutes::Users;

use strict;
use warnings;
use PAGI::Response::Text ();
use PAGI::Routing qw(route);

sub router {
    return PAGI::Routing::router(routes => [
        route('/' => sub {
            return PAGI::Response::Text->new('users_list');
        }, name => 'list'),
        route('/{id}' => sub {
            return PAGI::Response::Text->new('user_detail');
        }, name => 'show'),
    ]);
}

1;
