#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Request;

subtest 'params from scope' => sub {
    my $scope = {
        type    => 'http',
        method  => 'GET',
        path    => '/users/42/posts/100',
        headers => [],
        # Router would set this
        path_params => { user_id => '42', post_id => '100' },
    };

    my $req = PAGI::Request->new($scope);

    is($req->params, { user_id => '42', post_id => '100' }, 'params returns hashref');
    is($req->param('user_id'), '42', 'param() gets single value');
    is($req->param('post_id'), '100', 'param() another value');
    is($req->param('missing'), undef, 'missing param is undef');
};

subtest 'set_params for router integration' => sub {
    my $scope = { type => 'http', method => 'GET', headers => [] };
    my $req = PAGI::Request->new($scope);

    # Router calls this after matching
    $req->set_params({ id => '123', slug => 'hello-world' });

    is($req->param('id'), '123', 'param after set_params');
    is($req->param('slug'), 'hello-world', 'another param');
};

subtest 'no params' => sub {
    my $scope = { type => 'http', method => 'GET', headers => [] };
    my $req = PAGI::Request->new($scope);

    is($req->params, {}, 'empty params by default');
    is($req->param('anything'), undef, 'missing returns undef');
};

done_testing;
