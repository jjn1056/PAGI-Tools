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

subtest 'Router path_for accepts equivalent compact and named reverse arguments' => sub {
    my $routing = router(routes => [
        route('/items/{id}' => sub { }, name => 'show'),
        route('/items' => sub { }, name => 'index'),
    ]);

    my @cases = (
        ['defaults', ['/index'], '/items'],
        ['compact params', ['/show', { id => 7 }], '/items/7'],
        ['compact query', ['/show', { id => 7 }, { q => 'two words' }],
            '/items/7?q=two%20words'],
        ['compact fragment', ['/show', { id => 7 }, { q => 'two words' }, 'details'],
            '/items/7?q=two%20words#details'],
        ['named full', ['/show', params => { id => 7 },
            query => { q => 'two words' }, fragment => 'details'],
            '/items/7?q=two%20words#details'],
        ['compact query only', ['/index', {}, { q => 'two words' }],
            '/items?q=two%20words'],
        ['compact fragment only', ['/index', {}, {}, 'two words'],
            '/items#two%20words'],
        ['named reordered', ['/show', fragment => 'details',
            params => { id => 7 }, query => { q => 'two words' }],
            '/items/7?q=two%20words#details'],
        ['named query first', ['/show', query => { q => 'two words' },
            params => { id => 7 }], '/items/7?q=two%20words'],
        ['compact undef fragment', ['/show', { id => 7 }, {}, undef], '/items/7'],
        ['named undef fragment', ['/show', params => { id => 7 }, fragment => undef],
            '/items/7'],
        ['compact empty fragment', ['/show', { id => 7 }, {}, ''], '/items/7#'],
        ['named empty fragment', ['/show', fragment => '', params => { id => 7 }],
            '/items/7#'],
        ['UTF-8 suffix ordering', ['/show', { id => 7 },
            { z => 'last', a => "caf\x{e9}" }, "part / caf\x{e9}"],
            '/items/7?a=caf%C3%A9&z=last#part%20%2F%20caf%C3%A9'],
    );

    for my $case (@cases) {
        my ($label, $args, $expected) = @$case;
        is($routing->path_for(@$args), $expected, $label);
    }
};

subtest 'Router path_for rejects malformed and mixed reverse arguments' => sub {
    my $routing = router(routes => [
        route('/items/{id}' => sub { }, name => 'show'),
    ]);
    my $object = bless {}, 'Local::ReverseArgumentsObject';
    my $scalar = 'value';

    my @cases = (
        ['too many compact values', ['/show', {}, {}, 'section', 'extra'],
            qr/\Apath_for reverse-routing compact form accepts at most params, query, and fragment/],
        ['compact params array', ['/show', []],
            qr/\Apath_for reverse-routing form selector must be a hashref or named option key/],
        ['compact query array', ['/show', {}, []],
            qr/\Apath_for reverse-routing compact query must be a hashref/],
        ['compact fragment array', ['/show', {}, {}, []],
            qr/\Apath_for reverse-routing compact fragment must be a plain scalar or undef/],
        ['compact fragment object', ['/show', {}, {}, $object],
            qr/\Apath_for reverse-routing compact fragment must be a plain scalar or undef/],
        ['compact fragment scalar ref', ['/show', {}, {}, \$scalar],
            qr/\Apath_for reverse-routing compact fragment must be a plain scalar or undef/],
        ['undef selector', ['/show', undef],
            qr/\Apath_for reverse-routing form selector must be a hashref or named option key/],
        ['array selector', ['/show', []],
            qr/\Apath_for reverse-routing form selector must be a hashref or named option key/],
        ['object selector', ['/show', $object],
            qr/\Apath_for reverse-routing form selector must be a hashref or named option key/],
        ['scalar-ref selector', ['/show', \$scalar],
            qr/\Apath_for reverse-routing form selector must be a hashref or named option key/],
        ['odd named list', ['/show', params => { id => 7 }, 'query'],
            qr/\Apath_for reverse-routing named option list must contain key\/value pairs/],
        ['unknown named key', ['/show', parameters => { id => 7 }],
            qr/\Apath_for reverse-routing unknown named option 'parameters'/],
        ['named params array', ['/show', params => []],
            qr/\Apath_for reverse-routing named params must be a hashref/],
        ['named query scalar', ['/show', query => 'bad'],
            qr/\Apath_for reverse-routing named query must be a hashref/],
        ['named fragment array', ['/show', fragment => []],
            qr/\Apath_for reverse-routing named fragment must be a plain scalar or undef/],
        ['named fragment object', ['/show', fragment => $object],
            qr/\Apath_for reverse-routing named fragment must be a plain scalar or undef/],
        ['named fragment scalar ref', ['/show', fragment => \$scalar],
            qr/\Apath_for reverse-routing named fragment must be a plain scalar or undef/],
        ['compact then named', ['/show', { id => 8 }, query => { view => 'full' }],
            qr/compact and named reverse-routing forms cannot be mixed/],
        ['compact placeholders then named', ['/show', {}, {}, fragment => 'details'],
            qr/compact and named reverse-routing forms cannot be mixed/],
    );

    for my $case (@cases) {
        my ($label, $args, $error) = @$case;
        like(dies { $routing->path_for(@$args) }, $error, $label);
    }
};

subtest 'Router path_for normalizes exact logical references without decoding' => sub {
    my $routing = router(routes => [
        route('/show' => sub { }, name => 'show'),
        route('/encoded' => sub { }, name => '%2F'),
        mount('/group', routes => [
            route('/child' => sub { }, name => 'child'),
        ], namespace => 'group'),
    ]);

    for my $reference (qw(/show show ./show group/../show)) {
        is($routing->path_for($reference), '/show', "$reference resolves exactly to /show");
    }
    is($routing->path_for('group/child'), '/group/child',
        'a child slash reference resolves from the Router root');
    is($routing->path_for('%2F'), '/encoded',
        'percent-encoded input remains one literal logical segment');

    my @cases = (
        ['repeated slash', 'group//child', qr/contains an empty logical segment/],
        ['absolute repeated slash', '//show', qr/contains an empty logical segment/],
        ['trailing slash', 'group/child/', qr/contains an empty logical segment/],
        ['above-root traversal', '../show', qr/traverses above the Router root/],
        ['absolute above-root traversal', '/../show', qr/traverses above the Router root/],
        ['root only', '/', qr/resolves to a logical namespace, not a route/],
        ['bare dot', '.', qr/resolves to a logical namespace, not a route/],
        ['bare dot-dot', '..', qr/traverses above the Router root/],
        ['normalized namespace', 'group/..', qr/resolves to a logical namespace, not a route/],
        ['namespace only', 'group', qr/resolves to a logical namespace, not a route/],
        ['terminal dot on a leaf', 'show/.',
            qr/\Apath_for route reference 'show\/\.' resolves to a logical namespace, not a route/],
        ['terminal dot-dot on a leaf', 'show/child/..',
            qr/\Apath_for route reference 'show\/child\/\.\.' resolves to a logical namespace, not a route/],
        ['unknown exact target', 'missing/show', qr/unknown route name 'missing\/show'/],
    );

    for my $case (@cases) {
        my ($label, $reference, $error) = @$case;
        like(dies { $routing->path_for($reference) }, $error, $label);
    }
};

subtest 'route_named inspects normalized root references without throwing' => sub {
    my $show = route('/show' => sub { }, name => 'show');
    my $routing = router(routes => [
        $show,
        mount('/group', routes => [
            route('/child' => sub { }, name => 'child'),
        ], namespace => 'group'),
    ]);

    is(
        refaddr($routing->route_named('./show')),
        refaddr($show),
        'a current-directory reference preserves the original leaf identity',
    );
    is(
        refaddr($routing->route_named('group/../show')),
        refaddr($show),
        'interior navigation resolves from the Router root',
    );

    my $scalar = 'show';
    my @misses = (
        ['unknown address', 'missing'],
        ['namespace only', 'group'],
        ['terminal dot', 'show/.'],
        ['terminal dot-dot', 'show/child/..'],
        ['repeated separator', 'group//child'],
        ['trailing separator', 'group/child/'],
        ['above-root traversal', '../show'],
        ['undef input', undef],
        ['arrayref input', []],
        ['scalar-ref input', \$scalar],
    );

    for my $case (@misses) {
        my ($label, $reference) = @$case;
        my $result = 'not-called';
        my $lived = lives {
            $result = $routing->route_named($reference);
        };
        is($lived, T(), "$label does not throw");
        is($result, undef, "$label returns undef");
    }
};

subtest 'an exact named leaf takes precedence over its namespace address' => sub {
    my $api = route('/direct-api' => sub { }, name => 'api');
    my $api_x = route('/x' => sub { }, name => 'x');
    my $routing = router(routes => [
        $api,
        mount('/nested-api', routes => [$api_x], namespace => 'api'),
        mount('/group', routes => [
            route('/x' => sub { }, name => 'x'),
        ], namespace => 'group'),
    ]);

    is(
        [sort keys %{$routing->named_routes}],
        [qw(/api /api/x /group/x)],
        'inspection publishes a leaf and descendants at the same address',
    );
    is(refaddr($routing->route_named('/api')), refaddr($api),
        'route_named preserves the exact leaf identity at a namespace address');

    my ($absolute, $relative, $descendant);
    is(lives { $absolute = $routing->path_for('/api') }, T(),
        'an absolute exact-leaf lookup does not fail as namespace-only');
    is($absolute, '/direct-api',
        'an absolute reference selects the exact leaf before the namespace');
    is(lives { $relative = $routing->path_for('api') }, T(),
        'a relative exact-leaf lookup does not fail as namespace-only');
    is($relative, '/direct-api',
        'a root-relative reference selects the exact leaf before the namespace');
    is(lives { $descendant = $routing->path_for('/api/x') }, T(),
        'a namespace descendant lookup remains available');
    is($descendant, '/nested-api/x',
        'a descendant below the shared namespace remains resolvable');

    like(
        dies { $routing->path_for('/group') },
        qr/resolves to a logical namespace, not a route/,
        'a namespace without an exact leaf still fails',
    );
    like(
        dies { $routing->path_for('api/.') },
        qr/resolves to a logical namespace, not a route/,
        'terminal dot remains namespace-only even when normalization lands on a leaf',
    );
    like(
        dies { $routing->path_for('api/child/..') },
        qr/resolves to a logical namespace, not a route/,
        'terminal dot-dot remains namespace-only even when normalization lands on a leaf',
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
        qr/\Apath_for reverse-routing form selector must be a hashref or named option key/,
        'path parameters must be a hashref',
    );
    like(
        dies {
            $routing->path_for(
                '/account/files', { account => 'main', path => 'file' }, [],
            );
        },
        qr/\Apath_for reverse-routing compact query must be a hashref/,
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
