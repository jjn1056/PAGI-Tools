#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test2::V0;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::Routing qw(router route websocket sse mount);
use PAGI::Routing::Resolver;

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
    package Local::ReverseLeafProvider;
    use PAGI::Routing qw(route);

    our $CALLS = 0;
    our $SIGNED_CALLS = 0;

    sub Item {
        ++$CALLS;
        return Local::ReverseType->new('leaf');
    }

    sub Signed {
        ++$SIGNED_CALLS;
        return qr/-?\d+/;
    }

    sub leaf {
        return route('/items/{item:&Item}' => sub { }, name => 'show');
    }
}

{
    package Local::ReverseMountProvider;
    use PAGI::Routing qw(mount router);

    our $CALLS = 0;

    sub Tenant {
        ++$CALLS;
        return qr/outer/;
    }

    sub inline {
        return mount('/inline/{tenant:&Tenant}',
            app => router(routes => [$_[0]]), name => 'inline');
    }

    sub known {
        my ($prefix, $router, $namespace) = @_;
        return mount($prefix . '/{tenant:&Tenant}',
            app => $router, name      => $namespace);
    }
}

{
    package Local::OpaqueRoutes;

    our $ROUTES_CALLS = 0;
    our $PATH_FOR_CALLS = 0;
    our $TO_APP_CALLS = 0;

    sub new {
        my ($class) = @_;
        return bless {}, $class;
    }

    sub routes {
        ++$ROUTES_CALLS;
        die "opaque routes must not be inspected\n";
    }

    sub path_for {
        ++$PATH_FOR_CALLS;
        die "opaque path_for must not be called\n";
    }

    sub to_app {
        ++$TO_APP_CALLS;
        die "opaque to_app must not be called during inspection\n";
    }
}

{
    package Local::CyclicRouter;
    use parent 'PAGI::Routing::Router';

    sub routes {
        my ($self) = @_;
        return [PAGI::Routing::Mount->new(
            '/again', app => $self, name      => 'loop',
        )];
    }
}

subtest 'Resolver exposes only the neutral scope-bound reverse seam' => sub {
    ok(PAGI::Routing::Resolver->can('reverse_for_scope'),
        'Resolver exposes reverse_for_scope');
    ok(!PAGI::Routing::Resolver->can('reverse_for_context'),
        'the Context-named reverse seam is removed');

    my $resolver = PAGI::Routing::Resolver->new(routes => [
        route('/page' => sub { }, name => 'page'),
    ]);
    like(
        dies {
            $resolver->reverse_for_scope(
                'redirect', {}, '/page', '', '/', {},
            );
        },
        qr/\Ascope-bound reverse operation must be path_for or url_for/,
        'operation diagnostics describe the neutral scope-bound seam',
    );
};

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

subtest 'mounted Router applications publish placement-specific reverse paths' => sub {
    my $show = route('/{id}' => sub { }, name => 'show');
    my $child = router(routes => [$show]);
    my $root = router(routes => [
        mount('/left', app => $child, name => 'left'),
        mount('/right', app => $child, name => 'right'),
    ]);
    my $unnamed = router(routes => [
        mount('/people', app => $child),
    ]);

    is($root->path_for('/left/show', { id => 7 }), '/left/7',
        'the first named placement contributes its path and namespace');
    is($root->path_for('/right/show', { id => 8 }), '/right/8',
        'the reused child receives an independent second placement');
    is($unnamed->path_for('/show', { id => 9 }), '/people/9',
        'an unnamed placement retains the current namespace');
    is(
        $root->path_for('/left/show', { id => 7 },
            { q => 'two words' }, 'details'),
        '/left/7?q=two%20words#details',
        'a mounted descendant retains query and fragment rendering',
    );
    is(refaddr($root->route_named('/left/show')), refaddr($show),
        'the first placement retains the original leaf identity');
    is(refaddr($root->route_named('/right/show')), refaddr($show),
        'the reused placement retains that same original leaf identity');

    $Local::OpaqueRoutes::ROUTES_CALLS = 0;
    $Local::OpaqueRoutes::PATH_FOR_CALLS = 0;
    $Local::OpaqueRoutes::TO_APP_CALLS = 0;
    my $opaque_named;
    is(
        lives {
            $opaque_named = router(routes => [
                mount('/legacy', app => Local::OpaqueRoutes->new,
                    name => 'legacy'),
            ]);
        },
        T(),
        'Router construction never speculatively calls an opaque routes method',
    );
    is(
        [
            $Local::OpaqueRoutes::ROUTES_CALLS,
            $Local::OpaqueRoutes::PATH_FOR_CALLS,
            $Local::OpaqueRoutes::TO_APP_CALLS,
        ],
        [0, 0, 0],
        'an arbitrary application is completely opaque to reverse inspection',
    );
    like(
        dies { $opaque_named->path_for('/legacy') },
        qr/logical namespace|unknown route/,
        'a Mount name is not an opaque target',
    );
};

subtest 'Resolver metadata indexes every inspectable Router placement' => sub {
    my $show = route('/show/{item}' => sub { },
        name => 'show',
        desc => 'show leaf',
        constraints => { item => Local::ReverseType->new('leaf') },
    );
    my $grandchild = router(routes => [$show]);
    my $team_mount = mount('/teams/{team}',
        app => $grandchild,
        name => 'team',
        desc => 'team placement',
        constraints => { team => qr/\A\d+\z/ },
    );
    my $child = router(routes => [$team_mount]);
    my $health = route('/health' => sub { },
        name => 'health', desc => 'root leaf');
    my $left_mount = mount('/left/{account}',
        app => $child,
        name => 'left',
        desc => 'left placement',
        constraints => { account => qr/\A[a-z]+\z/ },
    );
    my $right_mount = mount('/right/{account}',
        app => $child,
        name => 'right',
        desc => 'right placement',
        constraints => { account => qr/\A[a-z]+\z/ },
    );
    my $opaque_mount = mount('/legacy/{legacy}',
        app => Local::OpaqueRoutes->new,
        name => 'legacy',
        desc => 'legacy placement',
        constraints => { legacy => qr/\A[a-z]+\z/ },
    );
    my $root = router(routes => [
        $health, $left_mount, $right_mount, $opaque_mount,
    ]);
    my $resolver = $root->_resolver;

    my @metadata_cases = (
        ['root leaf', [0], {
            match => {
                kind => 'route', route => '/health', name => '/health',
                logical_namespace => '/', desc => 'root leaf',
            },
            mount => undef,
            logical_namespace => '/',
        }],
        ['left root placement', [1], {
            match => {
                kind => 'mount', route => '/left/{account}', name => undef,
                logical_namespace => '/', desc => 'left placement',
            },
            mount => {
                path => '/left/{account}', name => 'left',
                desc => 'left placement',
            },
            logical_namespace => '/left',
        }],
        ['left nested placement', [1, 0], {
            match => {
                kind => 'mount', route => '/left/{account}/teams/{team}',
                name => undef, logical_namespace => '/left',
                desc => 'team placement',
            },
            mount => {
                path => '/teams/{team}', name => 'team',
                desc => 'team placement',
            },
            logical_namespace => '/left/team',
        }],
        ['left grandchild leaf', [1, 0, 0], {
            match => {
                kind => 'route',
                route => '/left/{account}/teams/{team}/show/{item}',
                name => '/left/team/show',
                logical_namespace => '/left/team', desc => 'show leaf',
            },
            mount => undef,
            logical_namespace => '/left/team',
        }],
        ['right root placement', [2], {
            match => {
                kind => 'mount', route => '/right/{account}', name => undef,
                logical_namespace => '/', desc => 'right placement',
            },
            mount => {
                path => '/right/{account}', name => 'right',
                desc => 'right placement',
            },
            logical_namespace => '/right',
        }],
        ['right nested placement', [2, 0], {
            match => {
                kind => 'mount', route => '/right/{account}/teams/{team}',
                name => undef, logical_namespace => '/right',
                desc => 'team placement',
            },
            mount => {
                path => '/teams/{team}', name => 'team',
                desc => 'team placement',
            },
            logical_namespace => '/right/team',
        }],
        ['right grandchild leaf', [2, 0, 0], {
            match => {
                kind => 'route',
                route => '/right/{account}/teams/{team}/show/{item}',
                name => '/right/team/show',
                logical_namespace => '/right/team', desc => 'show leaf',
            },
            mount => undef,
            logical_namespace => '/right/team',
        }],
        ['opaque placement', [3], {
            match => {
                kind => 'mount', route => '/legacy/{legacy}', name => undef,
                logical_namespace => '/', desc => 'legacy placement',
            },
            mount => {
                path => '/legacy/{legacy}', name => 'legacy',
                desc => 'legacy placement',
            },
            logical_namespace => '/legacy',
        }],
    );

    for my $case (@metadata_cases) {
        my ($label, $location, $expected) = @$case;
        my $metadata = $resolver->_metadata_for_location($location);
        is($metadata, $expected, "$label has exact effective metadata");
        ok(!exists $metadata->{is_raw}, "$label publishes no retired is_raw flag");
    }

    my @record_cases = (
        ['0', [0], [], $health],
        ['1', [1], [qw(account)], $left_mount],
        ['1.0', [1, 0], [qw(account team)], $team_mount],
        ['1.0.0', [1, 0, 0], [qw(account item team)], $show],
        ['2', [2], [qw(account)], $right_mount],
        ['2.0', [2, 0], [qw(account team)], $team_mount],
        ['2.0.0', [2, 0, 0], [qw(account item team)], $show],
        ['3', [3], [qw(legacy)], $opaque_mount],
    );
    for my $case (@record_cases) {
        my ($key, $location, $parameters, $source) = @$case;
        my $record = $resolver->{metadata_by_location}{$key};
        is($record->{location}, $location,
            "$key retains its defensive location path");
        is([sort keys %{$record->{predicate_records}}], $parameters,
            "$key retains the exact effective predicate ancestry");
        is(refaddr($record->{source}), refaddr($source),
            "$key retains the original source node identity");
        ok(!exists $record->{is_raw},
            "$key stores no retired is_raw metadata");
    }

    my $source_predicates = $show->_pattern->_predicate_records;
    is(
        refaddr($resolver->{metadata_by_location}{'1.0.0'}
            {predicate_records}{item}[0]{check}),
        refaddr($source_predicates->{item}[0]{check}),
        'effective metadata preserves the leaf predicate check identity',
    );
    is(
        $root->path_for('/left/team/show', {
            account => 'acme', team => 7, item => 'leaf',
        }),
        '/left/acme/teams/7/show/leaf',
        'left metadata ancestry renders every placement capture',
    );
    is(
        $root->path_for('/right/team/show', {
            account => 'globex', team => 8, item => 'leaf',
        }),
        '/right/globex/teams/8/show/leaf',
        'reused metadata ancestry renders every second-placement capture',
    );
    like(
        dies { $resolver->_metadata_for_location([3, 0]) },
        qr/metadata location is unknown/,
        'an opaque Mount has placement metadata but no descendant locations',
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
        ], name      => 'group'),
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
        ], name      => 'group'),
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
        mount('/nested-api', routes => [$api_x], name      => 'api'),
        mount('/group', routes => [
            route('/x' => sub { }, name => 'x'),
        ], name      => 'group'),
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
        ], name      => 'api'),
    ], name      => 'tenant');
    my $root_mount = mount('/', routes => [
        route('/status/' => sub { }, name => 'status'),
    ], name      => 'rooted');
    my $exact_mount = mount('/prefix', routes => [
        route('//double/' => sub { }, name => 'slashes'),
    ], name      => 'exact');
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
        ], name      => 'account'),
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

subtest 'composed reverse routes retain source providers and exact predicates' => sub {
    $Local::ReverseLeafProvider::CALLS = 0;
    $Local::ReverseMountProvider::CALLS = 0;

    my $inline_leaf = Local::ReverseLeafProvider::leaf();
    my $shared_leaf = Local::ReverseLeafProvider::leaf();
    my $shared = router(routes => [$shared_leaf]);
    my $inline_mount = Local::ReverseMountProvider::inline($inline_leaf);
    my $left_mount = Local::ReverseMountProvider::known('/left', $shared, 'left');
    my $right_mount = Local::ReverseMountProvider::known('/right', $shared, 'right');
    my $routing = router(routes => [
        $inline_mount,
        $left_mount,
        $right_mount,
    ]);

    is($Local::ReverseLeafProvider::CALLS, 2,
        'each declared leaf provider occurrence runs once despite repeated placement');
    is($Local::ReverseMountProvider::CALLS, 3,
        'each declared mount provider occurrence runs once');

    my $source_leaf_records = $shared_leaf->_pattern->_predicate_records;
    my $source_mount_records = $left_mount->_pattern->_predicate_records;
    my $effective_records = $routing->_resolver->{by_name}{'/left/show'}{pattern}
        ->_predicate_records;
    is(refaddr($effective_records->{item}[0]{check}),
        refaddr($source_leaf_records->{item}[0]{check}),
        'effective composition preserves the source leaf check identity');
    is(refaddr($effective_records->{tenant}[0]{check}),
        refaddr($source_mount_records->{tenant}[0]{check}),
        'effective composition preserves the source mount check identity');
    isnt(refaddr($effective_records->{item}[0]),
        refaddr($source_leaf_records->{item}[0]),
        'effective composition copies private predicate record containers');

    is($routing->path_for('/inline/show', { tenant => 'outer', item => 'leaf' }),
        '/inline/outer/items/leaf',
        'inline composition renders with both source predicates');
    is($routing->path_for('/left/show', { tenant => 'outer', item => 'leaf' }),
        '/left/outer/items/leaf',
        'the first known Router placement renders with both source predicates');
    is($routing->path_for('/right/show', { tenant => 'outer', item => 'leaf' }),
        '/right/outer/items/leaf',
        'reusing the child Router produces an independent canonical placement');

    like(
        dies {
            $routing->path_for('/inline/show', {
                tenant => 'wrong', item => 'leaf',
            });
        },
        qr/path parameter 'tenant' failed constraint for route '\/inline\/show'/,
        'the composed mount predicate rejects an invalid outer value',
    );
    like(
        dies {
            $routing->path_for('/left/show', {
                tenant => 'outer', item => 'wrong',
            });
        },
        qr/path parameter 'item' failed constraint for route '\/left\/show': expected leaf, got wrong/,
        'the source check object keeps its detailed diagnostic after composition',
    );
    is($Local::ReverseLeafProvider::CALLS, 2,
        'reverse rendering never reinvokes a leaf provider');
    is($Local::ReverseMountProvider::CALLS, 3,
        'reverse rendering never reinvokes a mount provider');
};

subtest 'reverse constraints cover protocol leaves, inline regexes, and signed values' => sub {
    $Local::ReverseLeafProvider::SIGNED_CALLS = 0;
    my $stream_type = Local::ReverseType->new('event');
    my $routing = router(routes => [
        websocket('/socket/{id:&Local::ReverseLeafProvider::Signed}' => sub { },
            name => 'socket'),
        sse('/events/{id}' => sub { }, name => 'events',
            constraints => { id => $stream_type }),
        mount('/groups/{group:[a-z]+}', routes => [
            route('/items/{item:\\d+}' => sub { }, name => 'item'),
        ], name      => 'group'),
    ]);

    is($Local::ReverseLeafProvider::SIGNED_CALLS, 1,
        'the qualified signed provider runs once at source construction');
    is($routing->path_for('/socket', { id => -1 }), '/socket/-1',
        'a provider-backed negative integer renders without coercion');
    is($routing->path_for('/events', { id => 'event' }), '/events/event',
        'a named SSE route enforces and renders its explicit constraint');
    is($routing->path_for('/group/item', { group => 'staff', item => 42 }),
        '/groups/staff/items/42',
        'inline regex predicates survive mount and leaf composition');
    like(dies { $routing->path_for('/socket', { id => 'not-int' }) },
        qr/path parameter 'id' failed constraint for route '\/socket'/,
        'the named WebSocket provider rejects an invalid reverse value');
    like(dies { $routing->path_for('/events', { id => 'wrong' }) },
        qr/expected event, got wrong/,
        'the named SSE check object preserves its diagnostic');
    like(
        dies {
            $routing->path_for('/group/item', { group => '123', item => 42 });
        },
        qr/path parameter 'group' failed constraint/,
        'an inline mount regex rejects an invalid reverse value',
    );
    like(
        dies {
            $routing->path_for('/group/item', { group => 'staff', item => 'x' });
        },
        qr/path parameter 'item' failed constraint/,
        'an inline leaf regex rejects an invalid reverse value',
    );
    is($Local::ReverseLeafProvider::SIGNED_CALLS, 1,
        'protocol reverse rendering does not reinvoke its provider');
};

subtest 'composed Router graph exposes every Router application placement' => sub {
    my $hidden = route('/secret' => sub { }, name => 'hidden');
    my $hidden_router = router(routes => [$hidden]);

    my $blog_index = route('/' => sub { }, name => 'index');
    my $blog_show = route('/{post_id}' => sub { }, name => 'show');
    my $blog_archive = route('/archive' => sub { }, name => 'archive');
    my $blogs = router(routes => [
        $blog_index,
        $blog_show,
        mount('/legacy', app => $hidden_router),
        $blog_archive,
    ]);

    my $person_show = route('/profile' => sub { }, name => 'show');
    my $notifications = route('/notifications' => sub { }, name => 'notifications');
    my $person = router(routes => [
        $person_show,
        mount('/blogs', app => $blogs, name      => 'blog'),
        mount('/settings', routes => [$notifications], name      => 'settings'),
    ]);

    my $health = route('/health' => sub { }, name => 'health');
    my $root = router(routes => [
        $health,
        mount('/people/{person_id}', app => $person, name      => 'person'),
        mount('/opaque', app => $hidden_router),
    ]);

    is(
        [sort keys %{$root->named_routes}],
        [qw(
            /health
            /hidden
            /person/blog/archive
            /person/blog/hidden
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
    is(refaddr($root->route_named('/person/blog/hidden')), refaddr($hidden),
        'a Router base application is inspectable within a known Router');
    is(refaddr($root->route_named('/hidden')), refaddr($hidden),
        'an unnamed Router application mount contributes its child route');
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
                ], name      => 'person'),
                mount('/router', app => $child, name      => 'person'),
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
                    app => $repeated_child,
                    name      => 'person',
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
                    mount('/opaque/{id}', app => sub { }),
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
            mount('/authors', app => $shared, name      => 'authors'),
            mount('/editors', app => $shared, name      => 'editors'),
            mount('/groups/{id}', routes => [
                route('/first' => sub { }, name => 'first'),
            ], name      => 'groups'),
            mount('/teams/{id}', routes => [
                route('/second' => sub { }, name => 'second'),
            ], name      => 'teams'),
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
        mount('/api', routes => [$unnamed, $named_leaf], name      => 'api'),
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
