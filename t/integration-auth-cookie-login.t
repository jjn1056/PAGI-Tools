#!/usr/bin/env perl
use strict;
use warnings;

use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use PAGI::Test::Client;

my $app_file = "$Bin/../examples/auth-cookie-login/app.pl";
my $app = do $app_file;
my $load_error = $@ || $!;
ok(!$load_error, 'cookie login example loads cleanly')
    or diag($load_error);

SKIP: {
    skip 'example did not load', 20 unless $app;

    my $client = PAGI::Test::Client->new(app => $app);

    my $protected = $client->get('/');
    is($protected->status, 303, 'anonymous home request redirects');
    is($protected->header('Location'), '/login',
        'anonymous user is sent to the login form');
    my $anonymous_id = $client->cookie('hello_session');
    like($anonymous_id, qr/\A[a-f0-9]{64}\z/,
        'anonymous request receives the configured session cookie');

    my $invalid = $client->post('/login', form => {
        username => 'demo', password => 'wrong',
    });
    is($invalid->status, 200, 'invalid credentials redisplay the form');
    like($invalid->text, qr/Invalid username or password/,
        'invalid credentials receive a fixed error');
    is($client->cookie('hello_session'), $anonymous_id,
        'invalid credentials do not regenerate the session');
    is($client->get('/')->header('Location'), '/login',
        'invalid credentials do not create authenticated state');

    my $login = $client->post('/login', form => {
        username => 'demo', password => 'secret',
    });
    is($login->status, 303, 'valid credentials redirect after login');
    is($login->header('Location'), '/',
        'successful login redirects to the protected home');
    my $authenticated_id = $client->cookie('hello_session');
    like($authenticated_id, qr/\A[a-f0-9]{64}\z/,
        'successful login retains a session cookie');
    isnt($authenticated_id, $anonymous_id,
        'successful login regenerates the session identifier');

    my $home = $client->get('/');
    is($home->status, 200, 'authenticated home request succeeds');
    like($home->text, qr/Hello, demo/,
        'authenticated home identifies the fixed demo user');

    my $get_login_submit = $client->get('/login');
    is($get_login_submit->status, 200, 'GET /login only displays the form');
    unlike($get_login_submit->text, qr/Invalid username or password/,
        'plain login form has no failed-submission message');

    my $get_logout = $client->get('/logout');
    is($get_logout->status, 405, 'GET cannot submit logout');
    is($get_logout->header('Allow'), 'POST',
        'logout publishes its only allowed method');

    my $logout = $client->post('/logout');
    is($logout->status, 303, 'logout redirects');
    is($logout->header('Location'), '/login',
        'logout redirects to the login form');
    is($client->get('/')->header('Location'), '/login',
        'destroyed session no longer authenticates the client');

    my $unknown = $client->get('/missing');
    is($unknown->status, 404, 'unknown path receives the configured default');
}

done_testing;
