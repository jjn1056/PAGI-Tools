package TestRoutes::Admin;

use strict;
use warnings;
use PAGI::App::Router;

sub to_app {
    my $r = PAGI::App::Router->new;

    $r->get('/' => sub {
        my ($c) = @_;
        return $c->text('admin_dashboard');
    });

    $r->get('/settings' => sub {
        my ($c) = @_;
        return $c->text('admin_settings');
    });

    return $r->to_app;
}

1;
