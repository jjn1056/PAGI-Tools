#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::Request;

my $no_body = sub { die 'body unavailable' };

subtest 'cookies parsing' => sub {
    my $scope = {
        type    => 'http',
        method  => 'GET',
        headers => [
            ['cookie', 'session=abc123; user=john; theme=dark'],
        ],
    };

    my $req = PAGI::Request->new($scope, $no_body);
    my $cookies = $req->cookies;

    is(ref($cookies), 'HASH', 'cookies returns hashref');
    is($cookies->{session}, 'abc123', 'session cookie');
    is($cookies->{user}, 'john', 'user cookie');
    is($cookies->{theme}, 'dark', 'theme cookie');
};

subtest 'cookie() shortcut' => sub {
    my $scope = {
        type    => 'http',
        method  => 'GET',
        headers => [
            ['cookie', 'token=xyz789'],
        ],
    };

    my $req = PAGI::Request->new($scope, $no_body);

    is($req->cookie('token'), 'xyz789', 'cookie() returns value');
    is($req->cookie('missing'), undef, 'missing cookie returns undef');
};

subtest 'no cookies' => sub {
    my $scope = { type => 'http', method => 'GET', headers => [] };
    my $req = PAGI::Request->new($scope, $no_body);

    is($req->cookies, {}, 'empty cookies returns empty hash');
    is($req->cookie('anything'), undef, 'missing returns undef');
};

subtest 'cookies with special characters' => sub {
    my $scope = {
        type    => 'http',
        method  => 'GET',
        headers => [
            ['cookie', 'data=hello%20world; encoded=%3D%26'],
        ],
    };

    my $req = PAGI::Request->new($scope, $no_body);

    # D5 (Ruled by John 2026-10-30): cookie values are read as sent, never
    # percent-decoded (Mojolicious's and Starlette's reading).
    is($req->cookie('data'), 'hello%20world', 'percent-encoding is kept');
    is($req->cookie('encoded'), '%3D%26', 'encoded special characters are kept');
};

done_testing;
