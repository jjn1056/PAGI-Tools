#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test2::V0;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Routing qw(router route websocket sse mount);

{
    package Local::ReverseType;

    sub new {
        my ($class, $expected) = @_;
        return bless { expected => $expected }, $class;
    }

    sub check {
        my ($self, $value) = @_;
        return $value eq $self->{expected};
    }

    sub get_message {
        my ($self, $value) = @_;
        return "expected $self->{expected}, got $value";
    }
}

{
    package Local::CyclicRouter;
    use parent 'PAGI::Routing::Router';

    sub routes {
        my ($self) = @_;
        return [PAGI::Routing::Mount->new(
            '/again', router => $self, namespace => 'loop',
        )];
    }
}

subtest 'direct slash addresses render application paths and route kinds' => sub {
    my $routing = router(routes => [
        route('/health' => sub { }, name => 'health'),
        websocket('/socket/{room}' => sub { }, name => 'socket'),
        sse('/events/{channel}' => sub { }, name => 'events'),
        route('/version' => sub { }, name => 'v1.1'),
    ]);

    is($routing->path_for('/health'), '/health', 'direct address renders without parameter hashes');
    is($routing->path_for('health'), '/health', 'a bare reference resolves from the Router root');
    is($routing->path_for('/socket', { room => 'general' }), '/socket/general', 'WebSocket address renders a path');
    is($routing->path_for('/events', { channel => 'news' }), '/events/news', 'SSE address renders a path');
    is($routing->_resolver->route_kind('/health'), 'route', 'resolver retains the HTTP route kind');
    is($routing->_resolver->route_kind('/socket'), 'websocket', 'resolver retains the WebSocket route kind');
    is($routing->_resolver->route_kind('/events'), 'sse', 'resolver retains the SSE route kind');
    is($routing->_resolver->route_kind('/unknown'), undef, 'unknown route kind is undefined');
    is($routing->path_for('v1.1'), '/version', 'a dot remains literal in a root-relative segment');
    is(
        [sort keys %{$routing->named_routes}],
        [qw(/events /health /socket /v1.1)],
        'a dotted local name remains one literal address segment',
    );
};

subtest 'inline paths and slash namespaces remain independent' => sub {
    my $unnamed_mount = mount('/public', routes => [
        route('/users/{id}' => sub { }, name => 'show'),
    ]);
    my $nested_mount = mount('/tenants/{tenant_id}', routes => [
        mount('/admin', routes => [
            route('/users/{user_id}' => sub { }, name => 'show'),
        ], namespace => 'api'),
    ], namespace => 'tenant');
    my $root_mount = mount('/', routes => [
        route('/status/' => sub { }, name => 'status'),
    ], namespace => 'rooted');
    my $exact_mount = mount('/prefix', routes => [
        route('//double/' => sub { }, name => 'slashes'),
    ], namespace => 'exact');
    my $routing = router(routes => [
        $unnamed_mount, $nested_mount, $root_mount, $exact_mount,
    ]);

    is(
        $routing->path_for('/show', { id => 7 }),
        '/public/users/7',
        'an unnamed mount leaves the child address at root but contributes its path',
    );
    is(
        $routing->path_for('/tenant/api/show', {
            tenant_id => 'acme', user_id => 42,
        }),
        '/tenants/acme/admin/users/42',
        'nested namespaces affect only the address and all mount paths affect the path',
    );
    is(
        $routing->path_for('tenant/api/show', {
            tenant_id => 'acme', user_id => 42,
        }),
        '/tenants/acme/admin/users/42',
        'a child slash reference resolves from the Router root',
    );
    like(
        dies { $routing->path_for('tenant.api.show') },
        qr/unknown route name 'tenant\.api\.show'/,
        'dots do not act as logical hierarchy separators',
    );
    is(
        $routing->path_for('/rooted/status'),
        '/status/',
        'a root mount contributes no extra slash and a leaf trailing slash remains exact',
    );
    is(
        $routing->path_for('/exact/slashes'),
        '/prefix//double/',
        'concatenation does not normalize repeated or trailing route slashes',
    );
};

subtest 'reverse rendering validates complete ancestry and escapes values' => sub {
    my $type = Local::ReverseType->new('right');
    my $routing = router(routes => [
        mount('/accounts/{account}', routes => [
            route(
                '/items/{item}' => sub { },
                name => 'show',
                constraints => { item => $type },
            ),
            route('/files/*path' => sub { }, name => 'files'),
        ], namespace => 'account'),
    ]);

    is(
        $routing->path_for(
            '/account/show',
            { account => "caf\x{e9} space", item => 'right' },
            { z => 'last', 'a key' => 'A&B', empty => undef },
        ),
        '/accounts/caf%C3%A9%20space/items/right?a%20key=A%26B&empty=&z=last',
        'outer and leaf values render before a sorted escaped query',
    );
    is(
        $routing->path_for('/account/files', {
            account => 'main', path => '../private//read me/',
        }),
        '/accounts/main/files/../private//read%20me/',
        'wildcard rendering preserves separators while escaping components',
    );

    like(
        dies { $routing->path_for('/account/show', { item => 'right' }) },
        qr/missing path parameter 'account'.*route '\/account\/show'/,
        'missing outer parameter names the canonical address',
    );
    like(
        dies {
            $routing->path_for('/account/show', {
                account => 'main', item => 'right', extra => 1,
            });
        },
        qr/unexpected path parameter 'extra'.*route '\/account\/show'/,
        'extra parameters name the canonical address',
    );
    like(
        dies {
            $routing->path_for('/account/show', {
                account => 'main', item => 'wrong',
            });
        },
        qr/path parameter 'item' failed constraint for route '\/account\/show': expected right, got wrong/,
        'constraint failures name the canonical address',
    );
    like(
        dies { $routing->path_for('/account/files', [], {}) },
        qr/path parameters for route '\/account\/files' must be a hashref/,
        'path parameters must be a hashref',
    );
    like(
        dies {
            $routing->path_for(
                '/account/files', { account => 'main', path => 'file' }, [],
            );
        },
        qr/query parameters for route '\/account\/files' must be a hashref/,
        'query parameters must be a hashref',
    );
    like(
        dies {
            $routing->path_for(
                '/account/files',
                { account => 'main', path => 'file' },
                { bad => [] },
            );
        },
        qr/query parameter 'bad' must be a scalar/,
        'query values reject references',
    );
    like(
        dies { $routing->path_for('/missing') },
        qr/unknown route name '\/missing'/,
        'reverse generation croaks for an unknown address',
    );
};

subtest 'composed Router graph exposes placements and respects opacity' => sub {
    my $hidden = route('/secret' => sub { }, name => 'hidden');
    my $hidden_router = router(routes => [$hidden]);

    my $blog_index = route('/' => sub { }, name => 'index');
    my $blog_show = route('/{post_id}' => sub { }, name => 'show');
    my $blog_archive = route('/archive' => sub { }, name => 'archive');
    my $blogs = router(routes => [
        $blog_index,
        $blog_show,
        mount('/legacy' => $hidden_router),
        $blog_archive,
    ]);

    my $person_show = route('/profile' => sub { }, name => 'show');
    my $notifications = route('/notifications' => sub { }, name => 'notifications');
    my $person = router(routes => [
        $person_show,
        mount('/blogs', router => $blogs, namespace => 'blog'),
        mount('/settings', routes => [$notifications], namespace => 'settings'),
    ]);

    my $health = route('/health' => sub { }, name => 'health');
    my $root = router(routes => [
        $health,
        mount('/people/{person_id}', router => $person, namespace => 'person'),
        mount('/opaque' => $hidden_router),
    ]);

    is(
        [sort keys %{$root->named_routes}],
        [qw(
            /health
            /person/blog/archive
            /person/blog/index
            /person/blog/show
            /person/settings/notifications
            /person/show
        )],
        'inspection exposes canonical absolute addresses across all known placements',
    );
    is(
        {
            '/health' => $root->path_for('/health'),
            '/person/blog/archive' => $root->path_for(
                '/person/blog/archive', { person_id => 7 },
            ),
            '/person/blog/index' => $root->path_for(
                '/person/blog/index', { person_id => 7 },
            ),
            '/person/blog/show' => $root->path_for(
                '/person/blog/show', { person_id => 7, post_id => 9 },
            ),
            '/person/settings/notifications' => $root->path_for(
                '/person/settings/notifications', { person_id => 7 },
            ),
            '/person/show' => $root->path_for(
                '/person/show', { person_id => 7 },
            ),
        },
        {
            '/health' => '/health',
            '/person/blog/archive' => '/people/7/blogs/archive',
            '/person/blog/index' => '/people/7/blogs/',
            '/person/blog/show' => '/people/7/blogs/9',
            '/person/settings/notifications' => '/people/7/settings/notifications',
            '/person/show' => '/people/7/profile',
        },
        'each logical address resolves to its complete placement-specific effective path',
    );
    is(
        refaddr($root->route_named('/person/blog/show')),
        refaddr($blog_show),
        'route_named preserves source leaf identity',
    );
    is($root->route_named('/person/blog/hidden'), undef,
        'an opaque Router application inside a known Router is terminal only at that mount');
    is($root->route_named('/hidden'), undef,
        'a positional Router application mount remains entirely undiscoverable');
    is(refaddr($root->route_named('/person/blog/archive')), refaddr($blog_archive),
        'discovery resumes with siblings after an opaque terminal');

    my $copy = $root->named_routes;
    delete $copy->{'/health'};
    $copy->{'/invented'} = $hidden;
    is(refaddr($root->route_named('/health')), refaddr($health),
        'mutating named_routes cannot remove an internal entry');
    is($root->route_named('/invented'), undef,
        'mutating named_routes cannot add an internal entry');
};

subtest 'canonical collisions report both placement paths' => sub {
    my $child = router(routes => [
        route('/two' => sub { }, name => 'show'),
    ]);

    like(
        dies {
            router(routes => [
                mount('/inline', routes => [
                    route('/one' => sub { }, name => 'show'),
                ], namespace => 'person'),
                mount('/router', router => $child, namespace => 'person'),
            ]);
        },
        qr/duplicate canonical route address '\/person\/show'.*'\/inline\/one'.*'\/router\/two'/,
        'inline and Router placements with one address report both effective paths',
    );
};

subtest 'parameter validation follows one ancestry and precedes opacity' => sub {
    my $repeated_child = router(routes => [
        route('/articles/{id}' => sub { }, name => 'show'),
    ]);
    like(
        dies {
            router(routes => [
                mount('/people/{id}',
                    router => $repeated_child,
                    namespace => 'person',
                ),
            ]);
        },
        qr/duplicate path parameter 'id'.*effective path '\/people\/\{id\}\/articles\/\{id\}'/,
        'a Router-mounted leaf cannot reuse a prefix parameter',
    );

    like(
        dies {
            router(routes => [
                mount('/people/{id}', routes => [
                    mount('/opaque/{id}' => sub { }),
                ]),
            ]);
        },
        qr/duplicate path parameter 'id'.*effective path '\/people\/\{id\}\/opaque\/\{id\}'/,
        'an opaque mount validates its known prefix before traversal stops',
    );

    my $shared = router(routes => [
        route('/people/{id}' => sub { }, name => 'show'),
    ]);
    my $reused = lives {
        router(routes => [
            mount('/authors', router => $shared, namespace => 'authors'),
            mount('/editors', router => $shared, namespace => 'editors'),
            mount('/groups/{id}', routes => [
                route('/first' => sub { }, name => 'first'),
            ], namespace => 'groups'),
            mount('/teams/{id}', routes => [
                route('/second' => sub { }, name => 'second'),
            ], namespace => 'teams'),
        ]);
    };
    is($reused, T(), 'sibling branches may reuse parameter names and Router identity');
};

subtest 'Router cycles identify URL and logical namespace ancestry' => sub {
    like(
        dies { Local::CyclicRouter->new(routes => []) },
        qr/Router cycle.*URL mount ancestry '\/again'.*logical namespace ancestry '\/loop'/,
        'a Router identity already active in its ancestry is rejected defensively',
    );
};

subtest 'unnamed leaves publish no address while named source identity is defensive' => sub {
    my $unnamed = route('/health' => sub { });
    my $named_leaf = route('/users' => sub { }, name => 'users');
    my $routing = router(routes => [
        mount('/api', routes => [$unnamed, $named_leaf], namespace => 'api'),
    ]);

    is(
        [sort keys %{$routing->named_routes}],
        ['/api/users'],
        'only a declared local name publishes a canonical address',
    );
    is($routing->route_named('/api'), undef, 'a namespace alone is not a route address');
    is(
        refaddr($routing->route_named('/api/users')),
        refaddr($named_leaf),
        'the indexed route retains the source leaf identity',
    );

    my $children = $routing->routes;
    pop @$children;
    is(scalar @{$routing->routes}, 1, 'router route collections remain defensive copies');
};

done_testing;
