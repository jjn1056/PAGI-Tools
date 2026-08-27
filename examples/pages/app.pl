#!/usr/bin/env perl
use strict;
use warnings;

use Future;
use Future::AsyncAwait;
use PAGI::Compose qw(compose);
use PAGI::Pages;
use PAGI::Routing qw(router route mount);

my $routing = router(routes => [
    route('/' => PAGI::Pages->welcome, name => 'welcome'),
    route('/old' => PAGI::Pages->permanent_redirect('/new')),
    route('/missing' => PAGI::Pages->not_found),
    mount('/terminal', app => PAGI::Pages->gone),
    route('/request' => sub {
        my ($request) = @_;
        my $response = PAGI::Pages->not_found($request, as => 'text');
        $response->header('X-Demo' => 'Request response value');
        return $response;
    }),
    route('/raw', raw => async sub {
        my ($scope, $receive, $send) = @_;
        my $response = PAGI::Pages->not_found($scope, as => 'text');
        $response->header('X-Demo' => 'raw response value');
        await Future->wrap($response->respond($send));
    }),
]);

compose(
    app => $routing,
    lifespan => {
        startup => sub {
            my ($state, $scope) = @_;
            $state->{pages_example} = 'started';
            return;
        },
        shutdown => sub {
            my ($state, $scope) = @_;
            $state->{pages_example} = 'stopped';
            return;
        },
    },
);
