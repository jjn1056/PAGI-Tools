#!/usr/bin/env perl
use v5.40;

use Future::AsyncAwait;

use PAGI::Auth qw(auth_result unauth_result requires);
use PAGI::Auth::SimpleUser;
use PAGI::Compose qw(compose);
use PAGI::Middleware::Session qw(session_state);
use PAGI::Pages qw(redirect not_found);
use PAGI::Response qw(html_response);
use PAGI::Routing qw(route mount middleware);
use PAGI::Routing::URL qw(path_for);
use PAGI::Session qw(session);

# The session's logged-in user is the authentication context: requires()
# reads it to decide who may see a page.
sub session_user ($request) {
    my $username = session($request)->get('user', undef);
    return unauth_result() unless defined $username;
    return auth_result(user => PAGI::Auth::SimpleUser->new(identity => $username));
}

sub html_escape ($text) {
    my %entity = ('&' => '&amp;', '<' => '&lt;', '>' => '&gt;', '"' => '&quot;', "'" => '&#39;');
    return $text =~ s/([&<>"'])/$entity{$1}/gr;
}

# Every URL comes from path_for, so the pages stay correct wherever the
# account area is mounted or the whole app is served under a prefix.
sub login_page ($request, $next, $error = undef) {
    my $action = html_escape(path_for($request, 'login'));
    my $message = defined $error
        ? qq{<p role="alert">$error</p>}
        : '';
    my $next_field = defined $next
        ? sprintf(qq{<input type="hidden" name="next" value="%s">}, html_escape($next))
        : '';

    return html_response(<<"HTML");
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Demo login</title></head>
<body>
<h1>Demo login</h1>
$message
<form method="post" action="$action">
$next_field
<label>Username <input name="username" autocomplete="username"></label>
<label>Password <input type="password" name="password" autocomplete="current-password"></label>
<button type="submit">Log in</button>
</form>
</body>
</html>
HTML
}

async sub home($request) {
    my $logout = html_escape(path_for($request, 'logout'));
    return html_response(<<"HTML");
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Demo home</title></head>
<body>
<h1>Hello, demo</h1>
<form method="post" action="$logout">
<button type="submit">Log out</button>
</form>
</body>
</html>
HTML
}

async sub login_form($request) {
    return login_page($request, $request->query_param('next'));
}

async sub login_submit($request) {
    my $form = await $request->form_params(strict => 1);
    my $username = $form->get('username') // '';
    my $password = $form->get('password') // '';
    my $next = $form->get('next');

    return login_page($request, $next, 'Invalid username or password.')
        unless $username eq 'demo' && $password eq 'secret';

    my $session = session($request);
    $session->regenerate;
    $session->set(user => $username);

    # Only a local path: anything else would make the login page an open
    # redirect to another site.
    $next = path_for($request, 'home') unless defined $next && $next =~ m{\A/(?![/\\])};
    return redirect($next, status => 303);
}

async sub logout($request) {
    session($request)->destroy;
    return redirect(path_for($request, 'login'), status => 303);
}

compose(
    routes => [
        mount('/account', routes => [
            # Not logged in: redirect to the route named 'login', with ?next=
            route('/' => requires([], \&home, redirect => ['login']),
                methods => ['GET'], name => 'home'),
            route('/login' => \&login_form, methods => ['GET'], name => 'login'),
            route('/login' => \&login_submit, methods => ['POST']),
            route('/logout' => \&logout, methods => ['POST'], name => 'logout'),
        ]),
    ],
    http_default => not_found(),
    middleware => [
        middleware('Session',
            state  => session_state('Cookie', cookie_name => 'hello_session', expire => 3600),
            expire => 3600,
        ),
        middleware('Authentication', backend => \&session_user),
    ],
);
