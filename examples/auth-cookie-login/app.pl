#!/usr/bin/env perl
use v5.40;

use Future::AsyncAwait;

use PAGI::Compose qw(compose);
use PAGI::Pages qw(redirect not_found);
use PAGI::Response qw(html_response);
use PAGI::Routing qw(route middleware);
use PAGI::Session qw(session);

sub login_page($error = undef) {
    my $message = defined $error
        ? qq{<p role="alert">$error</p>}
        : '';

    return html_response(<<"HTML");
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Demo login</title></head>
<body>
<h1>Demo login</h1>
$message
<form method="post" action="/login">
<label>Username <input name="username" autocomplete="username"></label>
<label>Password <input type="password" name="password" autocomplete="current-password"></label>
<button type="submit">Log in</button>
</form>
</body>
</html>
HTML
}

async sub home($request) {
    my $username = session($request)->get('user', undef);
    return redirect('/login', status => 303) unless defined $username;

    return html_response(<<'HTML');
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Demo home</title></head>
<body>
<h1>Hello, demo</h1>
<form method="post" action="/logout">
<button type="submit">Log out</button>
</form>
</body>
</html>
HTML
}

async sub login_form($request) {
    return login_page();
}

async sub login_submit($request) {
    my $form = await $request->form_params(strict => 1);
    my $username = $form->get('username') // '';
    my $password = $form->get('password') // '';

    return login_page('Invalid username or password.')
        unless $username eq 'demo' && $password eq 'secret';

    my $session = session($request);
    $session->regenerate;
    $session->set(user => $username);
    return redirect('/', status => 303);
}

async sub logout($request) {
    session($request)->destroy;
    return redirect('/login', status => 303);
}

compose(
    routes => [
        route('/' => \&home, methods => ['GET']),
        route('/login' => \&login_form, methods => ['GET']),
        route('/login' => \&login_submit, methods => ['POST']),
        route('/logout' => \&logout, methods => ['POST']),
    ],
    http_default => not_found(),
    middleware => [middleware(
        'Session',
        secret      => 'demo-only-secret-change-me',
        cookie_name => 'hello_session',
        expire      => 3600,
    )],
);
