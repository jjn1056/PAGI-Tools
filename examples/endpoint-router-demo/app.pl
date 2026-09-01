#!/usr/bin/env perl
use strict;
use warnings;
use lib 'lib';

use MyApp::Main;
use MyApp::API;
use MyApp::API::Events;
use PAGI::Compose qw(compose);
use PAGI::Routing qw(mount);

my $events = MyApp::API::Events->new;
my $api    = MyApp::API->new(events => $events);
my $main   = MyApp::Main->new(api => $api);

compose(
    routes => [
        mount('/' => app => $main->to_router),
    ],
    lifespan => {
        startup => sub {
            my ($state) = @_;
            $state->{resource} = { name => 'demo-resource', open => 1 };
            $state->{metrics} = { requests => 0, websocket_messages => 0 };
        },
        shutdown => sub {
            my ($state) = @_;
            $state->{resource}{open} = 0;
            $state->{resource}{closed} = 1;
        },
    },
);
