package TestRoutes::Users;

use strict;
use warnings;
use PAGI::Response ();
use PAGI::App::Router;

sub router {
    my $r = PAGI::App::Router->new;

    $r->get('/' => sub {
        my ($request) = @_;
        return PAGI::Response->text('users_list');
    })->name('list');

    $r->get('/{id}' => sub {
        my ($request) = @_;
        return PAGI::Response->text('user_detail');
    })->name('show');

    return $r;
}

1;
