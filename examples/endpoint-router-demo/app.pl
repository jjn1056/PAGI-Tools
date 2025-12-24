#!/usr/bin/env perl
use strict;
use warnings;
use lib 'lib';
use Future::AsyncAwait;

use MyApp::Main;
use PAGI::Lifespan;

my $router = MyApp::Main->new;

# Wrap with lifecycle management
PAGI::Lifespan->wrap(
    $router->to_app,
    startup => async sub {
        warn "MyApp starting up...\n";

        # Populate router state directly (like Starlette's app.state)
        $router->state->{config} = {
            app_name => 'Endpoint Router Demo',
            version  => '1.0.0',
        };
        $router->state->{metrics} = {
            requests  => 0,
            ws_active => 0,
        };

        warn "MyApp ready!\n";
    },
    shutdown => async sub {
        warn "MyApp shutting down...\n";
    },
);
