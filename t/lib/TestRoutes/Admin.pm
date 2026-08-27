package TestRoutes::Admin;

use strict;
use warnings;
use PAGI::Response ();
use PAGI::App::Router;

sub to_app {
    my $r = PAGI::App::Router->new;

    $r->get('/' => sub {
        my ($request) = @_;
        return PAGI::Response->text('admin_dashboard');
    });

    $r->get('/settings' => sub {
        my ($request) = @_;
        return PAGI::Response->text('admin_settings');
    });

    return $r->to_app;
}

1;
