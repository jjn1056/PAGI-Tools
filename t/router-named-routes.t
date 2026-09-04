#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Response::Text ();
use PAGI::Routing qw(mount route router sse websocket);
use PAGI::Routing::URL qw(path_for);
use PAGI::Test::Client ();

sub handler { return sub { return PAGI::Response::Text->new('ok') } }

{
    package Local::NamedController;
    use PAGI::Response::Text ();
    use PAGI::Routing qw(route router);
    use PAGI::Routing::URL qw(path_for);
    use Scalar::Util qw(refaddr);

    sub new { return bless { seen => [] }, $_[0] }

    sub routing {
        my ($self) = @_;
        return router(routes => [
            route('/item/{id}' => sub { return $self->show(@_) },
                name => 'show'),
        ]);
    }

    sub show {
        my ($self, $request) = @_;
        my $path = path_for($request, 'show');
        push @{$self->{seen}}, {
            receiver => refaddr($self),
            tenant => $request->path_param('tenant'),
            path => $path,
        };
        return PAGI::Response::Text->new($path);
    }
}

subtest 'ordinary routing objects retain named sibling placements' => sub {
    my $controller = Local::NamedController->new;
    my $identity = refaddr($controller);
    my $child = $controller->routing;
    my $routing = router(routes => [
        mount('/left/{tenant}', app => $child, name => 'left'),
        mount('/right/{tenant}', app => $child, name => 'right'),
    ]);

    is([sort keys %{$routing->named_routes}], ['/left/show', '/right/show'],
        'one immutable child publishes names under both Mount placements');
    is($routing->path_for('/left/show', { tenant => 'acme', id => 1 }),
        '/left/acme/item/1', 'left absolute name renders its placement');
    is($routing->path_for('/right/show', { tenant => 'beta', id => 2 }),
        '/right/beta/item/2', 'right absolute name renders its placement');
    is([map { refaddr($_->app) } @{$routing->routes}],
        [refaddr($child), refaddr($child)],
        'both Mounts retain the exact caller-owned child Router');

    my $client = PAGI::Test::Client->new(app => $routing->to_app);
    is($client->get('/left/acme/item/1')->text, '/left/acme/item/1',
        'relative lookup follows the active left placement');
    is($client->get('/right/beta/item/2')->text, '/right/beta/item/2',
        'relative lookup follows the active right placement');
    is($controller->{seen}, [
        { receiver => $identity, tenant => 'acme', path => '/left/acme/item/1' },
        { receiver => $identity, tenant => 'beta', path => '/right/beta/item/2' },
    ], 'ordinary bound closures keep object identity across both placements');
};

subtest 'declarative names are local segments and inspection uses slash addresses' => sub {
    my $routing = router(routes => [
        route('/users' => handler(), name => 'list'),
        route('/users/{id}' => handler(), name => 'show'),
        route('/users' => handler(), methods => 'POST', name => 'create'),
    ]);

    is([sort keys %{$routing->named_routes}], ['/create', '/list', '/show'],
        'root names are canonical absolute slash addresses');
    is($routing->path_for('/list'), '/users', 'a static name renders its path');
    is($routing->path_for('/show', { id => 42 }), '/users/42',
        'a parameterized name renders its capture');
    is($routing->path_for('/create'), '/users',
        'method siblings may render the same path under distinct names');
};

subtest 'path_for renders sorted query and one escaped fragment' => sub {
    my $routing = router(routes => [
        route('/search/{term}' => handler(), name => 'search'),
    ]);

    is(
        $routing->path_for(
            '/search',
            { term => 'two words' },
            { page => 2, 'a key' => 'A&B' },
            'result details',
        ),
        '/search/two%20words?a%20key=A%26B&page=2#result%20details',
        'path, query, and fragment use shared component encoding',
    );
    is(
        $routing->path_for('/search',
            params => { term => 'perl' },
            fragment => ''),
        '/search/perl#',
        'named reverse arguments and an empty fragment are supported',
    );
};

subtest 'reverse errors use the immutable Resolver contract' => sub {
    my $routing = router(routes => [
        route('/users/{id}' => handler(), name => 'show'),
    ]);

    like(dies { $routing->path_for('/missing') },
        qr/unknown route name '\/missing'/, 'unknown exact address fails');
    like(dies { $routing->path_for('/show') },
        qr/missing path parameter 'id'/, 'missing path parameter fails');
    like(dies { $routing->path_for('/show', { id => 1, extra => 2 }) },
        qr/unexpected path parameter 'extra'/, 'extra path parameter fails');
    is($routing->route_named('/missing'), undef,
        'route_named returns undef for an unknown exact address');
};

subtest 'declarative names validate one local segment' => sub {
    like(dies { route('/test' => handler(), name => '') },
        qr/name must be one logical address segment/, 'empty name fails');

    my $dotted = router(routes => [
        route('/test' => handler(), name => 'users.show'),
    ]);
    is($dotted->path_for('/users.show'), '/test',
        'a dotted local name remains one literal address component');
    like(dies { $dotted->path_for('/users/show') }, qr/unknown route name/,
        'a dot never acts as a hierarchy separator');
    like(dies { route('/test' => handler(), name => 'users/show') },
        qr/name must be one logical address segment/,
        'composed slash addresses are derived rather than declared locally');
};

subtest 'WebSocket, SSE, wildcard, and generic routes reverse uniformly' => sub {
    my $routing = router(routes => [
        websocket('/ws/{room}' => sub { }, name => 'socket'),
        sse('/events/{channel}' => sub { }, name => 'events'),
        route('/files/*path' => handler(), name => 'files'),
        route('/health' => handler(), methods => '*', name => 'health'),
        route('/items/{id:\d+}' => handler(),
            methods => ['GET', 'PUT'], name => 'item'),
    ]);

    is($routing->path_for('/socket', { room => 'general' }), '/ws/general',
        'WebSocket route reverses');
    is($routing->path_for('/events', { channel => 'news' }), '/events/news',
        'SSE route reverses');
    is($routing->path_for('/files', { path => 'docs/read me.txt' }),
        '/files/docs/read%20me.txt', 'wildcard components reverse independently');
    is($routing->path_for('/health'), '/health', 'wildcard-method route reverses');
    is($routing->path_for('/item', { id => 5 }), '/items/5',
        'generic route applies an inline constraint');
    like(dies { $routing->path_for('/item', { id => 'five' }) },
        qr/failed constraint/, 'reverse constraint failure is reported');
};

subtest 'known mounts compose nested names without copying them' => sub {
    my $users = router(routes => [
        route('/' => handler(), name => 'list'),
        route('/{id}' => handler(), name => 'show'),
    ]);
    my $api = router(routes => [
        mount('/users', app => $users, name => 'users'),
    ]);
    my $main = router(routes => [
        route('/' => handler(), name => 'home'),
        mount('/api', app => $api, name => 'api'),
    ]);

    is([sort keys %{$main->named_routes}], [
        '/api/users/list', '/api/users/show', '/home',
    ], 'known mount placement names compose recursively');
    is($main->path_for('/home'), '/', 'root route remains available');
    is($main->path_for('/api/users/list'), '/api/users/',
        'nested root leaf keeps its trailing slash');
    is($main->path_for('/api/users/show', { id => 7 }), '/api/users/7',
        'nested parameter path includes every mount prefix');

    my $first = $main->route_named('/api/users/show');
    is(refaddr($first), refaddr($main->route_named('/api/users/show')),
        'a retained Router preserves leaf identity');
    is(refaddr($main->route_named('/api/users/show')),
        refaddr($users->route_named('/show')),
        'immutable child Routers retain caller-owned leaf identity');
};

subtest 'opaque mounts accept placement metadata but publish no leaf names' => sub {
    my $opaque = sub { return Future->done };
    my $routing = router(routes => [
        mount('/legacy', app => $opaque, name => 'legacy'),
    ]);
    is($routing->routes->[0]->name, 'legacy',
        'an opaque Mount retains its local placement name');
    is($routing->named_routes, {}, 'opaque target contributes no names');
};

done_testing;
