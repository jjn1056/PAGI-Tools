use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use PAGI::Auth qw(auth auth_result unauth_result);
use PAGI::Auth::SimpleUser;
use PAGI::Compose qw(compose);
use PAGI::Middleware::Requires;
use PAGI::Pages;
use PAGI::Response qw(response);
use PAGI::Routing qw(middleware mount route sse websocket);
use PAGI::Test::Client;

# middleware('Requires', scopes => SCOPES, %options) runs what it wraps only
# for an authenticated user holding every scope -- Starlette's @requires, as
# middleware. Otherwise it refuses with a plain 403, or with the `refuse`
# application, or redirects: to a string exactly as written, or to
# path_for(@arrayref) with ?next= added.

# Tokens: 'reader' has notes:read; 'editor' has notes:read and notes:write.
my %grants = (reader => ['notes:read'], editor => ['notes:read', 'notes:write']);
my $authentication = middleware('Authentication', backend => sub {
    my ($request) = @_;
    my $token = $request->bearer_token;
    return unauth_result() unless defined $token && $grants{$token};
    return auth_result(
        user   => PAGI::Auth::SimpleUser->new(identity => $token),
        scopes => $grants{$token},
    );
});

sub ok_response { response('JSON', { ok => 1, who => auth($_[0])->user->identity }) }

# A route's or mount's middleware option holding one Requires.
sub protected { return (middleware => [middleware('Requires', @_)]) }

my $app = compose(
    middleware => [$authentication],
    routes => [
        route('/me'      => \&ok_response, middleware => [middleware('Requires')]),
        route('/read'    => \&ok_response, protected(scopes => 'notes:read')),
        route('/write'   => \&ok_response, protected(scopes => ['notes:read', 'notes:write'])),
        route('/hidden'  => \&ok_response, protected(scopes => ['notes:write'],
            refuse => response('Text', 'Not Found', status => 404))),
        route('/branded' => \&ok_response, protected(scopes => ['notes:write'], refuse => PAGI::Pages->forbidden)),
        route('/page'    => \&ok_response, protected(redirect => ['login'])),
        route('/elsewhere' => \&ok_response, protected(redirect => 'https://login.example.com/?app=notes')),
        route('/own-next'  => \&ok_response, protected(redirect => ['login', {}, { next => '/dashboard' }])),
        route('/named-args' => \&ok_response, protected(redirect => ['login', query => { lang => 'en' }])),
        route('/login'   => sub { response('JSON', { login => 1 }) }, name => 'login'),
        # Nested: the target's {org} is filled from the current route's {org}.
        route('/orgs/{org}/settings' => \&ok_response, protected(redirect => ['org_login'])),
        route('/orgs/{org}/billing' => \&ok_response,
            protected(redirect => ['org_login', {}, { reason => 'billing' }])),
        route('/orgs/{org}/login' => sub { response('JSON', { login => 1 }) }, name => 'org_login'),
        mount('/admin', routes => [
            route('/reports' => \&ok_response, protected(redirect => ['admin_login'])),
            route('/login' => sub { response('JSON', { login => 1 }) }, name => 'admin_login'),
        ]),
        # One Requires on a mount protects every route under it. The mount is
        # unnamed, so its routes and the root's share one namespace and
        # 'login' finds the root's route.
        mount('/staff', protected(scopes => ['notes:write'], redirect => ['login']), routes => [
            route('/a' => \&ok_response),
            route('/b' => \&ok_response, methods => ['POST']),
        ]),
        route('/async'   => async sub { my ($r) = @_; return ok_response($r) }, protected()),
        websocket('/ws-hidden' => sub { die 'not reached' }, protected(scopes => ['notes:write'],
            refuse => response('Text', 'Not Found', status => 404))),
        websocket('/ws'  => async sub {
            my ($ws) = @_; await $ws->accept; await $ws->send_text('in'); await $ws->close;
        }, protected(scopes => ['notes:read'])),
        sse('/events'    => async sub {
            my ($sse) = @_; await $sse->send_event(data => 'in'); await $sse->close;
        }, protected(scopes => ['notes:read'])),
    ],
);
my $client = PAGI::Test::Client->new(app => $app);
my %as = map { $_ => { Authorization => "Bearer $_", Accept => 'application/json' } } keys %grants;
my $guest = { Accept => 'application/json' };

subtest 'the route runs only for an authenticated user with every scope' => sub {
    is($client->get('/me', headers => $as{reader})->json, { ok => 1, who => 'reader' },
        'no scopes lets in any authenticated user');
    is($client->get('/read', headers => $as{reader})->status, 200, 'one scope, as a string');
    is($client->get('/write', headers => $as{editor})->status, 200, 'all scopes held');
    is($client->get('/async', headers => $as{editor})->status, 200, 'an async handler');
};

subtest 'otherwise a plain 403, whatever the Accept' => sub {
    for my $case (['/me', $guest, 'not authenticated'], ['/write', $as{reader}, 'a scope missing']) {
        my ($path, $headers, $label) = @$case;
        my $res = $client->get($path, headers => $headers);
        is([$res->status, $res->header('content-type'), $res->text],
            [403, 'text/plain; charset=utf-8', 'Forbidden'], $label);
    }
};

subtest 'refuse replaces the refusal; redirect sends the user elsewhere' => sub {
    my $hidden = $client->get('/hidden', headers => $as{reader});
    is([$hidden->status, $hidden->text], [404, 'Not Found'], 'a refuse response hides the route');
    is($client->get('/hidden', headers => $as{editor})->status, 200, 'but not from those allowed');
    is($client->get('/branded', headers => $as{reader})->header('content-type'), 'application/problem+json',
        'a PAGI::Pages refusal negotiates, by choice');

    is($client->get('/page', headers => $guest)->header('content-type'), 'text/html; charset=utf-8',
        "the redirect is PAGI::Response::Redirect's, not negotiated");

    my $location = sub { $client->get($_[0], headers => $guest)->header('location') };

    my $res = $client->get('/page?tab=2', headers => $guest);
    is([$res->status, $res->header('location')], [303, '/login?next=%2Fpage%3Ftab%3D2'],
        'an arrayref is path_for arguments, with the original path and query added as next');
    is($client->get('/page', headers => $as{reader})->status, 200, 'an authenticated user is not redirected');
    my $head = $client->head('/page', headers => $guest);
    is([$head->status, $head->header('location'), $head->content], [303, '/login?next=%2Fpage', ''],
        'HEAD is redirected the same way, with no body');

    is($location->('/orgs/acme/settings'), '/orgs/acme/login?next=%2Forgs%2Facme%2Fsettings',
        "the target's parameters are filled from the current route's, as path_for does");
    is($location->('/orgs/acme/billing'), '/orgs/acme/login?next=%2Forgs%2Facme%2Fbilling&reason=billing',
        'a query of its own is kept, next alongside it');
    is($location->('/own-next'), '/login?next=%2Fdashboard', 'a next of its own wins');
    is($location->('/named-args'), '/login?lang=en&next=%2Fnamed-args', "path_for's named argument form works too");

    is($location->('/admin/reports?x=1'), '/admin/login?next=%2Fadmin%2Freports%3Fx%3D1',
        "inside a mount, next is the whole path the client asked for, prefix included");

    is($location->('/elsewhere'), 'https://login.example.com/?app=notes', 'a string is the location, exactly as written');
};

subtest 'WebSocket and SSE routes are refused with the same response' => sub {
    my $denied = $client->websocket('/ws');
    ok($denied->refused, 'a WebSocket without the scope is refused before accept');
    is($denied->response->{status}, 403, 'with a 403');
    is($client->websocket('/ws-hidden', headers => { Authorization => 'Bearer reader' })->response->{status},
        404, 'or with the refuse application');
    $client->websocket('/ws', headers => { Authorization => 'Bearer reader' }, sub {
        is($_[0]->receive_text, 'in', 'and accepted with it');
    });

    is($client->sse('/events')->status, 403, 'an SSE request without the scope is declined with 403');
    $client->sse('/events', headers => { Authorization => 'Bearer reader' }, sub {
        is($_[0]->receive_event->{data}, 'in', 'and streams with it');
    });
};

subtest 'a Requires on a mount protects every route under it' => sub {
    my $res = $client->get('/staff/a', headers => $as{reader});
    is([$res->status, $res->header('location')], [303, '/login?next=%2Fstaff%2Fa'],
        'a scope missing: redirected to the sibling route named login');
    is($client->post('/staff/b', headers => $guest)->status, 303, 'every route under the mount, every method');
    is($client->get('/staff/a', headers => $as{editor})->status, 200, 'the scope held: in');
    is($client->post('/staff/b', headers => $as{editor})->status, 200, 'on every route');
};

subtest 'on a named mount, a redirect name resolves as from inside it' => sub {
    my $page = sub { response('JSON', { page => 1 }) };
    my $members = sub {
        my ($redirect) = @_;
        return mount('/members', name => 'members',
            middleware => [middleware('Requires', redirect => $redirect)], routes => [
                route('/' => \&ok_response),
                route('/about' => $page, name => 'about'),
            ]);
    };
    my $location = sub {
        my ($redirect) = @_;
        my $app = compose(middleware => [$authentication],
            routes => [$members->($redirect), route('/login' => $page, name => 'login')]);
        return PAGI::Test::Client->new(app => $app)->get('/members/', headers => $guest)->header('location');
    };
    is($location->(['about']), '/members/about?next=%2Fmembers%2F', 'a plain name is a route inside the mount');
    is($location->(['../login']), '/login?next=%2Fmembers%2F', '../ reaches the enclosing Router');
    is($location->(['/login']), '/login?next=%2Fmembers%2F', 'an absolute address is the logical one');
    is($location->('/login'), '/login', 'a string is the location as written, without next');
};

subtest "in Compose's application middleware, a route name says where Requires must go" => sub {
    my $login = route('/login' => sub { response('JSON', { login => 1 }) }, name => 'login');
    my $outside = sub {
        my ($redirect) = @_;
        return compose(routes => [$login],
            middleware => [$authentication, middleware('Requires', redirect => $redirect)]);
    };
    my $client = PAGI::Test::Client->new(app => $outside->(['login']), raise_app_exceptions => 1);
    like(dies { $client->get('/x', headers => $guest) },
        qr/\QRequires redirect names a route, which needs a Router's routing frame: put Requires on a route, mount or Router, or give a location string\E/,
        'a route name before routing has matched');
    is(PAGI::Test::Client->new(app => $outside->('/login'))->get('/x', headers => $guest)->header('location'),
        '/login', 'a location string works there');
};

subtest 'route_table shows what each route requires' => sub {
    my %entry = map { ($_->template => $_) } $app->route_table;
    my $requires = sub {
        my @found = grep { $_->factory eq 'Requires' } @{ $entry{$_[0]}->middleware };
        return @found == 1 ? $found[0]->config : undef;
    };
    is($requires->('/write'), { scopes => ['notes:read', 'notes:write'] }, "a route's own Requires");
    is($requires->('/staff/b'), { scopes => ['notes:write'], redirect => ['login'] },
        "a route under a protected mount carries the mount's");
    is($requires->('/login'), undef, 'an open route has none');
};

subtest 'other scope types pass through; HTTP without Authentication dies' => sub {
    my $seen;
    my $wrapped = PAGI::Middleware::Requires->new->wrap(async sub { $seen = $_[0]{type} });
    my $noop = sub { Future->done };
    $wrapped->({ type => 'lifespan' }, $noop, $noop)->get;
    is($seen, 'lifespan', 'a lifespan scope reaches the application without pagi.auth');
    like(dies { $wrapped->({ type => 'http' }, $noop, $noop)->get }, qr/pagi\.auth/,
        'an HTTP request with no Authentication in front is a configuration error');
};

subtest 'mistakes die when the application is compiled' => sub {
    my $new = sub { PAGI::Middleware::Requires->new(@_) };
    like(dies { $new->(status => 404) }, qr/Requires has unknown option 'status'/,
        'status is not an option: refuse is');
    for my $value (undef, '', 0, 'yes') {
        my $label = defined $value ? "'$value'" : 'undef';
        like(dies { $new->(refuse => $value) },
            qr/\QRequires 'refuse' must be an application\E/, "refuse $label");
    }
    like(dies { $new->(colour => 'red') }, qr/Requires has unknown option 'colour'/, 'an unknown option');
    for my $case ([sub { '/x' }, 'a coderef'], [[], 'an empty arrayref'], [undef, 'undef'], ['', 'an empty string'],
                  [[{}], 'an arrayref without a name']) {
        like(dies { $new->(redirect => $case->[0]) },
            qr/Requires redirect must be a location string or an arrayref of path_for arguments/,
            "redirect: $case->[1]");
    }
    like(dies { $new->(refuse => response('Text', 'no'), redirect => ['login']) },
        qr/Requires takes refuse or redirect, not both/, 'refuse and redirect together');
    for my $case ([{ a => 1 }, 'a hashref'], [[undef], 'an undefined scope'], [[[]], 'a reference as a scope']) {
        like(dies { $new->(scopes => $case->[0]) },
            qr/Requires scopes must be a scope string or an arrayref of them/, "scopes: $case->[1]");
    }
    my $declared = compose(routes => [route('/' => sub { response('Text', 'x') },
        middleware => [middleware('Requires', colour => 'red')])]);
    like(dies { $declared->to_app }, qr/Requires has unknown option 'colour'/,
        'through compose, the mistake surfaces at to_app');
};

subtest 'PAGI::Auth no longer offers requires' => sub {
    ok(!PAGI::Auth->can('requires'), 'no requires function');
    ok(!PAGI::Auth->_exports->{requires}, 'nor an export of one');
};

done_testing;
