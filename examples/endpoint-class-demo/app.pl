#!/usr/bin/env perl
use strict;
use warnings;
use lib 'lib';

use MyApp::Main;
use MyApp::API;
use MyApp::API::Events;
use PAGI::Compose qw(compose);

my @users = (
    { id => 1, name => 'Alice' },
    { id => 2, name => 'Bob' },
);
my $events = MyApp::API::Events->new;
my $api    = MyApp::API->new(events => $events, users => \@users);
my $main   = MyApp::Main->new(api => $api);

compose(
    routes => $main->routes,
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
