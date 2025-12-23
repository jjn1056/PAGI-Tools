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
        my ($state) = @_;
        warn "MyApp starting up...\n";

        $state->{config} = {
            app_name => 'Endpoint Router Demo',
            version  => '1.0.0',
        };

        $state->{metrics} = {
            requests  => 0,
            ws_active => 0,
        };

        # Sync with router instance for $self->state access
        %{$router->state} = %$state;

        warn "MyApp ready!\n";
    },
    shutdown => async sub {
        my ($state) = @_;
        warn "MyApp shutting down...\n";
    },
);
