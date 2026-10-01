use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use PAGI::Auth qw(auth auth_result unauth_result requires);
use PAGI::Auth::SimpleUser;
use PAGI::Compose qw(compose);
use PAGI::Response qw(json_response);
use PAGI::Routing qw(middleware route sse websocket);
use PAGI::Test::Client;

# requires(SCOPES, HANDLER, %options) returns a handler that calls HANDLER
# only for an authenticated user holding every scope -- Starlette's @requires.
# Otherwise it refuses with `status` (default 403), or redirects: to a string
# exactly as written, or to path_for(@arrayref) with ?next= added.

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

sub ok_response { json_response({ ok => 1, who => auth($_[0])->user->identity }) }

my $app = compose(
    middleware => [$authentication],
    routes => [
        route('/me'      => requires([], \&ok_response)),
        route('/read'    => requires('notes:read', \&ok_response)),
        route('/write'   => requires(['notes:read', 'notes:write'], \&ok_response)),
        route('/hidden'  => requires(['notes:write'], \&ok_response, status => 404)),
        route('/page'    => requires([], \&ok_response, redirect => ['login'])),
        route('/elsewhere' => requires([], \&ok_response,
            redirect => 'https://login.example.com/?app=notes')),
        route('/own-next'  => requires([], \&ok_response,
            redirect => ['login', {}, { next => '/dashboard' }])),
        route('/named-args' => requires([], \&ok_response,
            redirect => ['login', query => { lang => 'en' }])),
        route('/login'   => sub { json_response({ login => 1 }) }, name => 'login'),
        # Nested: the target's {org} is filled from the current route's {org}.
        route('/orgs/{org}/settings' => requires([], \&ok_response, redirect => ['org_login'])),
        route('/orgs/{org}/billing' => requires([], \&ok_response,
            redirect => ['org_login', {}, { reason => 'billing' }])),
        route('/orgs/{org}/login' => sub { json_response({ login => 1 }) }, name => 'org_login'),
        route('/async'   => requires([], async sub { my ($r) = @_; return ok_response($r) })),
        websocket('/ws'  => requires(['notes:read'], async sub {
            my ($ws) = @_; await $ws->accept; await $ws->send_text('in'); await $ws->close;
        })),
        sse('/events'    => requires(['notes:read'], async sub {
            my ($sse) = @_; await $sse->send_event(data => 'in'); await $sse->close;
        })),
    ],
);
my $client = PAGI::Test::Client->new(app => $app);
my %as = map { $_ => { Authorization => "Bearer $_", Accept => 'application/json' } } keys %grants;
my $guest = { Accept => 'application/json' };

subtest 'the handler runs only for an authenticated user with every scope' => sub {
    is($client->get('/me', headers => $as{reader})->json, { ok => 1, who => 'reader' },
        'requires([]) lets in any authenticated user');
    is($client->get('/read', headers => $as{reader})->status, 200, 'one scope, as a string');
    is($client->get('/write', headers => $as{editor})->status, 200, 'all scopes held');
    is($client->get('/async', headers => $as{editor})->status, 200, 'an async handler');
};

subtest 'otherwise a 403, as a negotiated Pages response' => sub {
    for my $case (['/me', $guest, 'not authenticated'], ['/write', $as{reader}, 'a scope missing']) {
        my ($path, $headers, $label) = @$case;
        my $res = $client->get($path, headers => $headers);
        is([$res->status, $res->header('content-type')], [403, 'application/problem+json'], $label);
    }
};

subtest 'status changes the refusal; redirect sends the user elsewhere' => sub {
    is($client->get('/hidden', headers => $as{reader})->status, 404, 'status => 404 hides the route');
    is($client->get('/hidden', headers => $as{editor})->status, 200, 'but not from those allowed');

    my $location = sub { $client->get($_[0], headers => $guest)->header('location') };

    my $res = $client->get('/page?tab=2', headers => $guest);
    is([$res->status, $res->header('location')], [303, '/login?next=%2Fpage%3Ftab%3D2'],
        'an arrayref is path_for arguments, with the original path and query added as next');
    is($client->get('/page', headers => $as{reader})->status, 200, 'an authenticated user is not redirected');

    is($location->('/orgs/acme/settings'), '/orgs/acme/login?next=%2Forgs%2Facme%2Fsettings',
        "the target's parameters are filled from the current route's, as path_for does");
    is($location->('/orgs/acme/billing'), '/orgs/acme/login?next=%2Forgs%2Facme%2Fbilling&reason=billing',
        'a query of its own is kept, next alongside it');
    is($location->('/own-next'), '/login?next=%2Fdashboard', 'a next of its own wins');
    is($location->('/named-args'), '/login?lang=en&next=%2Fnamed-args', "path_for's named argument form works too");

    is($location->('/elsewhere'), 'https://login.example.com/?app=notes', 'a string is the location, exactly as written');
};

subtest 'WebSocket and SSE routes are refused with the same response' => sub {
    my $denied = $client->websocket('/ws');
    ok($denied->refused, 'a WebSocket without the scope is refused before accept');
    is($denied->response->{status}, 403, 'with a 403');
    $client->websocket('/ws', headers => { Authorization => 'Bearer reader' }, sub {
        is($_[0]->receive_text, 'in', 'and accepted with it');
    });

    is($client->sse('/events')->status, 403, 'an SSE request without the scope is declined with 403');
    $client->sse('/events', headers => { Authorization => 'Bearer reader' }, sub {
        is($_[0]->receive_event->{data}, 'in', 'and streams with it');
    });
};

subtest 'mistakes are caught when the route is declared' => sub {
    like(dies { requires(['x'], 'not code') }, qr/requires handler must be a coderef/, 'a non-code handler');
    like(dies { requires(['x'], sub {}, status => 200) }, qr/status/, 'a status that is not a refusal');
    like(dies { requires(['x'], sub {}, colour => 'red') }, qr/unknown option.*colour/i, 'an unknown option');
    like(dies { requires(['x'], sub {}, redirect => sub { '/x' }) },
        qr/redirect must be a location string or an arrayref of path_for arguments/, 'a coderef redirect');
    like(dies { requires(['x'], sub {}, redirect => []) },
        qr/redirect must be a location string or an arrayref of path_for arguments/, 'an empty arrayref');
    ok(PAGI::Auth->requires([], sub {}), 'it is also a class method, like the other PAGI::Auth functions');
};

done_testing;
