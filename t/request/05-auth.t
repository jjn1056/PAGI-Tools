#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Request;
use MIME::Base64 qw(encode_base64);

my $no_body = sub { die 'body unavailable' };

subtest 'bearer_token' => sub {
    my $scope = {
        type    => 'http',
        method  => 'GET',
        headers => [['authorization', 'Bearer abc123xyz']],
    };

    my $req = PAGI::Request->new($scope, $no_body);
    is($req->bearer_token, 'abc123xyz', 'extracts bearer token');
};

subtest 'bearer_token missing' => sub {
    my $scope1 = { type => 'http', method => 'GET', headers => [] };
    my $scope2 = {
        type    => 'http',
        method  => 'GET',
        headers => [['authorization', 'Basic dXNlcjpwYXNz']],
    };

    is(PAGI::Request->new($scope1, $no_body)->bearer_token, undef, 'no auth header');
    is(PAGI::Request->new($scope2, $no_body)->bearer_token, undef, 'basic auth not bearer');
};

subtest 'basic_auth' => sub {
    my $encoded = encode_base64('john:secret123', '');
    my $scope = {
        type    => 'http',
        method  => 'GET',
        headers => [['authorization', "Basic $encoded"]],
    };

    my $req = PAGI::Request->new($scope, $no_body);
    my ($user, $pass) = $req->basic_auth;

    is($user, 'john', 'username extracted');
    is($pass, 'secret123', 'password extracted');
};

subtest 'basic_auth with colon in password' => sub {
    my $encoded = encode_base64('user:pass:with:colons', '');
    my $scope = {
        type    => 'http',
        method  => 'GET',
        headers => [['authorization', "Basic $encoded"]],
    };

    my ($user, $pass) = PAGI::Request->new($scope, $no_body)->basic_auth;

    is($user, 'user', 'username correct');
    is($pass, 'pass:with:colons', 'password with colons preserved');
};

subtest 'basic_auth missing' => sub {
    my $scope = { type => 'http', method => 'GET', headers => [] };
    my ($user, $pass) = PAGI::Request->new($scope, $no_body)->basic_auth;

    is($user, undef, 'no user');
    is($pass, undef, 'no pass');
};

done_testing;
