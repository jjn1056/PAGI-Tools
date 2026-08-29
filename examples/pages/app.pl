#!/usr/bin/env perl
use strict;
use warnings;

use Future;
use Future::AsyncAwait;
use PAGI::Compose qw(compose);
use PAGI::Pages qw(
    welcome_page redirect_page not_found_page gone_page
);
use PAGI::Routing qw(router route mount request_app);

my $routing = router(routes => [
    route('/' => \&welcome_page, name => 'welcome'),
    route('/old' => sub {
        my ($request) = @_;
        return redirect_page($request, '/new', status => 308);
    }),
    route('/missing' => \&not_found_page),
    mount('/terminal', app => request_app(\&gone_page)),
    route('/request' => sub {
        my ($request) = @_;
        my $response = not_found_page($request, as => 'text');
        $response->header('X-Demo' => 'Request response value');
        return $response;
    }),
    route('/raw', raw => async sub {
        my ($scope, $receive, $send) = @_;
        my $response = not_found_page($scope, as => 'text');
        $response->header('X-Demo' => 'raw response value');
        await Future->wrap($response->respond($scope, $receive, $send));
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
