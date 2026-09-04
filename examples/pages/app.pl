#!/usr/bin/env perl
use strict;
use warnings;

use PAGI::Compose qw(compose);
use PAGI::Pages qw(welcome redirect not_found gone);
use PAGI::Routing qw(route mount);

my $configured_pages = PAGI::Pages->new(
    as      => 'auto',
    default => 'text',
);

compose(
    routes => [
        route('/' => welcome(), name => 'welcome'),
        route('/old' => redirect('/new', status => 308)),
        route('/missing' => PAGI::Pages->not_found),
        route('/configured' => $configured_pages->not_found(
            detail => 'Missing under configured Pages policy',
        )),
        mount('/terminal', app => gone(
            detail => 'This mounted subtree is gone',
        )),
        route('/request' => sub {
            my ($request) = @_;
            return not_found(
                as      => 'text',
                detail  => 'No page at ' . $request->path,
                headers => ['X-Demo' => 'Request application value'],
            );
        }),
    ],
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
