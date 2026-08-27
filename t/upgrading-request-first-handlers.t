use strict;
use warnings;
use Test2::V0;
use Future;

use PAGI::Compose qw(compose);
use PAGI::CSRF qw(csrf);
use PAGI::Endpoint::Router;
use PAGI::Middleware::ErrorHandler;
use PAGI::Pages;
use PAGI::Request;
use PAGI::Response;
use PAGI::Routing qw(route);
use PAGI::Routing::URL qw(path_for url_for);
use PAGI::Session qw(session);
use PAGI::Stash qw(stash);
use PAGI::State qw(app_state);
use PAGI::Test::Client;
use PAGI::Transport qw(transport);

{
    package Local::UpgradeConnection;
    sub new { return bless { connected => $_[1] }, $_[0] }
    sub is_connected { return $_[0]{connected} }
}

sub receive_empty {
    return Future->done({
        type => 'http.request',
        body => '',
        more => 0,
    });
}

sub request_scope {
    return {
        type         => 'http',
        method       => 'GET',
        path         => '/',
        raw_path     => '/',
        query_string => '',
        scheme       => 'http',
        headers      => [],
        server       => ['testserver', 80],
    };
}

subtest 'normal HTTP handlers receive Request and return Response values' => sub {
    my $seen_request;
    my $app = compose(routes => [
        route('/things/{id}' => sub {
            my ($request) = @_;
            $seen_request = $request;
            return PAGI::Response->json({
                id   => $request->path_param('id'),
                path => path_for($request, 'show', { id => 42 }),
                url  => url_for($request, 'show', { id => 42 }),
            });
        }, name => 'show'),
        route('/missing' => PAGI::Pages->not_found),
    ])->to_app;

    my $client = PAGI::Test::Client->new(app => $app);
    my $response = $client->get('/things/7');

    isa_ok($seen_request, 'PAGI::Request');
    is($response->status, 200, 'returned Response is sent by the compiler');
    is($response->json, {
        id   => '7',
        path => '/things/42',
        url  => 'http://testserver/things/42',
    }, 'URL exports use the selected request-local routing frame');
    is($client->get('/missing')->status, 404,
        'a Pages endpoint also accepts the normal Request position');

    ok(!PAGI::Request->can('url_for'),
        'reverse routing is not intrinsic Request input');
    ok(!PAGI::Request->can('session'),
        'session access is not intrinsic Request input');
};

subtest 'Request construction is strict and state has an explicit HashRef escape hatch' => sub {
    my $scope = request_scope();
    $scope->{state} = { db => 'fixture-db' };
    my $request = PAGI::Request->new($scope, \&receive_empty);

    like(dies { PAGI::Request->new($scope) }, qr/receive coderef/,
        'Request requires the receive channel');
    like(
        dies { PAGI::Request->new({ %$scope, type => 'websocket' }, \&receive_empty) },
        qr/requires HTTP scope/,
        'Request rejects a non-HTTP scope',
    );

    my $compiled = eval q{
        package Local::UpgradeAppState;
        use v5.40;
        use PAGI::State qw(app_state);
        sub read_db($source) { return app_state($source)->get('db') }
        1;
    };
    ok($compiled, 'app_state compiles as a function under use v5.40')
        or diag($@);
    is(Local::UpgradeAppState::read_db($request), 'fixture-db',
        'app_state is invoked rather than parsed as the state declarator');

    my $state = app_state($request);
    isa_ok($state, 'PAGI::State');
    is(ref($state), 'PAGI::State', 'State remains a blessed facade');
    is($state->data, { db => 'fixture-db' },
        'data returns the real hashref for HashRef consumers');

    is($request->is_disconnected, undef,
        'disconnect state is unknown without a connection capability');
    $scope->{'pagi.connection'} = Local::UpgradeConnection->new(1);
    is($request->is_disconnected, 0,
        'a supplied connected capability reports false');
    $scope->{'pagi.connection'}{connected} = 0;
    is($request->is_disconnected, 1,
        'a supplied disconnected capability reports true');
};

subtest 'optional capabilities come from their owning helpers' => sub {
    my $scope = request_scope();
    $scope->{state} = {};
    $scope->{'pagi.session'} = { _id => 'sid-1', user => 'alice' };
    $scope->{csrf_token} = 'issued-token';
    my $request = PAGI::Request->new($scope, \&receive_empty);

    stash($request)->set(result => 42);
    is(stash($request)->get('result'), 42,
        'separate Stash facades share scope-backed request data');
    is(session($request)->get('user'), 'alice',
        'Session reads middleware-owned scope data');
    ok(csrf($request)->verify('issued-token'),
        'CSRF verifies against middleware-owned scope data');
    is(transport($request), undef,
        'Transport is optional when the server supplies no handle');
};

subtest 'ErrorHandler adapts its callback before invoking Pages' => sub {
    my $app = PAGI::Middleware::ErrorHandler->new(
        handler => sub {
            my ($context, $error) = @_;
            return PAGI::Pages->internal_server_error(
                $context,
                as => 'json',
            );
        },
    )->wrap(sub { die "database failed\n" });
    my $client = PAGI::Test::Client->new(app => $app);
    my $response = eval { $client->get('/') };

    ok($response, 'the documented ErrorHandler and Pages integration completes')
        or diag($@);
    is($response && $response->status, 500,
        'the adapted Pages response keeps the error status');
    is($response && $response->header('content-type'),
        'application/problem+json',
        'the adapted Pages response uses the configured representation');
};

subtest 'Endpoint exposes explicit Request construction only' => sub {
    my $endpoint = PAGI::Endpoint::Router->new;
    my $request = $endpoint->new_request(request_scope(), \&receive_empty);

    isa_ok($request, 'PAGI::Request');
    ok(!$endpoint->can('new_context'),
        'removed new_context has no compatibility alias');
};

subtest 'raw middleware keeps the native three-channel PAGI contract' => sub {
    my (@seen, @events);
    my $terminal = sub {
        @seen = @_;
        my (undef, undef, $send) = @_;
        return $send->({
            type    => 'http.response.start',
            status  => 204,
            headers => [],
        })->then(sub {
            return $send->({
                type => 'http.response.body',
                body => '',
                more => 0,
            });
        });
    };
    my $middleware = sub {
        my ($inner) = @_;
        return sub {
            my ($scope, $receive, $send) = @_;
            return $inner->($scope, $receive, $send);
        };
    };

    my $scope = request_scope();
    my $receive = \&receive_empty;
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    $middleware->($terminal)->($scope, $receive, $send)->get;

    is($seen[0], $scope, 'raw middleware preserves the exact scope');
    is($seen[1], $receive, 'raw middleware preserves the receive channel');
    is($seen[2], $send, 'raw middleware preserves the send channel');
    is($events[0]{status}, 204, 'native send reaches the caller');
    is($events[1], {
        type => 'http.response.body',
        body => '',
        more => 0,
    }, 'native example completes the response body');
};

done_testing;
