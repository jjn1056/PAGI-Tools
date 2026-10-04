#!/usr/bin/env perl
use strict;
use warnings;

use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use PAGI::Compose qw(compose);
use PAGI::Routing qw(mount);
use PAGI::Test::Client;

if ($] < 5.040) {
    plan skip_all => 'examples/auth-cookie-login requires Perl 5.40';
    exit 0;
}

my $app = do "$Bin/../examples/auth-cookie-login/app.pl";
my $load_error = $@ || $!;
ok($app && !$load_error, 'cookie login example loads cleanly') or diag($load_error);
plan skip_all => 'example did not load' unless $app;

# The forms carry the CSRF token as a hidden field; post it back like a browser.
sub form_token {
    my ($html) = @_;
    my ($token) = $html =~ /<input type="hidden" name="csrf_token" value="([^"]+)">/;
    return $token;
}

# The same flow at the root and served under /app (as behind a proxy, or a
# server root path): every URL the app emits must follow.
for my $case (['at the root', '', $app], ['under /app', '/app', compose(routes => [mount('/app', app => $app)])]) {
    my ($label, $p, $served) = @$case;
    subtest $label => sub {
        (my $here = "$p/account/") =~ s{/}{%2F}g;
        my $client = PAGI::Test::Client->new(app => $served);

        my $protected = $client->get("$p/account/");
        is($protected->status, 303, 'anonymous home request redirects');
        is($protected->header('Location'), "$p/account/login?next=$here",
            'to the login route, remembering where it was going');
        my $form = $client->get("$p/account/login?next=$here")->text;
        like($form, qr{<form method="post" action="\Q$p\E/account/login">}, 'the form posts to the mounted login route');
        like($form, qr{<input type="hidden" name="next" value="\Q$p\E/account/">}, 'the form carries next');
        my $anonymous_id = $client->cookie('hello_session');
        like($anonymous_id, qr/\A[a-f0-9]{64}\z/, 'anonymous request gets the session cookie');
        my $token = form_token($form);
        ok($token, 'the form carries the CSRF token');
        ok(!defined $client->cookie('csrf_token'), 'the token lives in the session, not a cookie');
        my $cross = $client->post("$p/account/login",
            headers => { 'Sec-Fetch-Site' => 'cross-site' },
            form => { username => 'demo', password => 'secret', csrf_token => $token });
        is($cross->status, 403, 'a cross-site login post is refused, token or not');

        my $forged = $client->post("$p/account/login",
            form => { username => 'demo', password => 'secret' });
        is($forged->status, 403, 'a login POST without the token is refused');
        is($client->get("$p/account/")->status, 303, 'and does not log in');

        my $invalid = $client->post("$p/account/login",
            form => { username => 'demo', password => 'wrong', csrf_token => $token });
        is($invalid->status, 200, 'invalid credentials redisplay the form');
        like($invalid->text, qr/Invalid username or password/, 'with a fixed error');
        is($client->cookie('hello_session'), $anonymous_id, 'and do not regenerate the session');
        is($client->get("$p/account/")->header('Location'), "$p/account/login?next=$here", 'nor authenticate');

        my $offsite_client = PAGI::Test::Client->new(app => $served);
        my $offsite_token = form_token($offsite_client->get("$p/account/login")->text);
        my $offsite = $offsite_client->post("$p/account/login", form => {
            username => 'demo', password => 'secret', next => 'https://evil.example/',
            csrf_token => $offsite_token,
        });
        is($offsite->header('Location'), "$p/account/", 'a next that is not a local path falls back to home');

        my $login = $client->post("$p/account/login",
            form => { username => 'demo', password => 'secret', next => "$p/account/", csrf_token => $token });
        is([$login->status, $login->header('Location')], [303, "$p/account/"], 'login returns to next');
        isnt($client->cookie('hello_session'), $anonymous_id, 'and regenerates the session');

        my $home = $client->get("$p/account/");
        is($home->status, 200, 'authenticated home succeeds');
        like($home->text, qr/Hello, demo/, 'and greets the user');
        like($home->text, qr{<form method="post" action="\Q$p\E/account/logout">}, 'logout posts to the mounted route');

        my $forged_logout = $client->post("$p/account/logout", form => {});
        is($forged_logout->status, 403, 'a logout POST without the token is refused');
        is($client->get("$p/account/")->status, 200, 'and keeps the session');

        my $plain = $client->get("$p/account/login");
        is($plain->status, 200, 'GET login only shows the form');
        unlike($plain->text, qr/Invalid username or password/, 'without an error');

        my $get_logout = $client->get("$p/account/logout");
        is([$get_logout->status, $get_logout->header('Allow')], [405, 'POST'], 'GET cannot log out');

        my $logout = $client->post("$p/account/logout", form => { csrf_token => form_token($home->text) });
        is([$logout->status, $logout->header('Location')], [303, "$p/account/login"], 'logout goes to the login route');
        is($client->get("$p/account/")->header('Location'), "$p/account/login?next=$here",
            'and the session no longer authenticates');

        is($client->get("$p/missing")->status, 404, 'unknown paths get 404');
    };
}

done_testing;
