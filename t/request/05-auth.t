#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(blessed);

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

subtest 'auth shortcuts delegate singleton and error handling to Headers' => sub {
    my $scope = {
        type    => 'http',
        method  => 'GET',
        headers => [
            ['Authorization', 'Bearer first'],
            ['authorization', 'Bearer second'],
        ],
    };
    my $req = PAGI::Request->new($scope, $no_body);

    is $req->bearer_token, undef, 'duplicate Authorization fields are not selected';
    my $error = dies { $req->bearer_token(raise_on_error => 1) };
    isa_ok $error, 'PAGI::Exception::HTTP';
    is [$error->status_code, $error->client_message], [400, 'The Authorization header could not be parsed.'],
        'raise_on_error: a duplicate is the client\'s error, a 400';
    my $option = dies { $req->basic_auth(unknown => 1) };
    like $option, qr/unknown option/i, 'argument validation reaches the Headers helper';
    ok !(blessed($option) && $option->isa('PAGI::Exception::HTTP')), 'and an option error stays a programming error';
};

# The client sent the header: a value raise_on_error refuses is the client's
# error, an HTTP 400, as a body the client got wrong is.
subtest 'raise_on_error on a client header is a 400' => sub {
    my $request = sub { PAGI::Request->new({ type => 'http', method => 'GET', headers => [@_] }, $no_body) };
    for my $case (
        ['malformed Basic',  sub { $request->(['Authorization', 'Basic !!!'])->basic_auth(raise_on_error => 1) }, 'Authorization'],
        ['Basic, no colon',  sub { $request->(['Authorization', 'Basic c2VjcmV0'])->basic_auth(raise_on_error => 1) }, 'Authorization'],
        ['malformed Bearer', sub { $request->(['Authorization', 'Bearer a b'])->bearer_token(raise_on_error => 1) }, 'Authorization'],
        ['two Content-Types', sub { $request->(['Content-Type', 'text/plain'], ['Content-Type', 'text/html'])->content_type(raise_on_error => 1) }, 'Content-Type'],
        ['malformed Content-Type', sub { $request->(['Content-Type', 'text/'])->content_type(raise_on_error => 1) }, 'Content-Type'],
    ) {
        my ($name, $read, $field) = @$case;
        my $error = dies { $read->() };
        ok blessed($error) && $error->isa('PAGI::Exception::HTTP'), "$name: an HTTP error";
        is [$error->status_code, $error->client_message], [400, "The $field header could not be parsed."], "$name: 400";
        unlike "$error", qr/secret/, "$name: no credential in the message";
    }
    is [$request->()->basic_auth(raise_on_error => 1)], [undef, undef], 'absence is not an error';
    is $request->()->content_type(raise_on_error => 1), '', 'nor is a missing Content-Type';
    is [$request->(['Authorization', 'Basic ' . encode_base64('ada:test', '')])->basic_auth(raise_on_error => 1)],
        ['ada', 'test'], 'a valid credential still reads';
};

done_testing;
