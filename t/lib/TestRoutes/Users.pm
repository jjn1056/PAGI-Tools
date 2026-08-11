package TestRoutes::Users;

use strict;
use warnings;
use PAGI::App::Router;

sub router {
    my $r = PAGI::App::Router->new;

    $r->get('/' => sub {
        my ($c) = @_;
        return $c->text('users_list');
    })->name('list');

    $r->get('/{id}' => sub {
        my ($c) = @_;
        return $c->text('user_detail');
    })->name('show');

    return $r;
}

1;
