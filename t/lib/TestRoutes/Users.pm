package TestRoutes::Users;

use strict;
use warnings;
use PAGI::Response::Text ();
use PAGI::App::Router;

sub router {
    my $r = PAGI::App::Router->new;

    $r->get('/' => sub {
        my ($request) = @_;
        return PAGI::Response::Text->new('users_list');
    })->name('list');

    $r->get('/{id}' => sub {
        my ($request) = @_;
        return PAGI::Response::Text->new('user_detail');
    })->name('show');

    return $r;
}

1;
