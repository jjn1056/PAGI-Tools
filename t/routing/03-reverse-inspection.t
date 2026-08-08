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

subtest 'direct names render application paths and route kinds' => sub {
    my $nodes = [
        route('/health' => sub { }, name => 'health'),
        websocket('/socket/{room}' => sub { }, name => 'socket'),
        sse('/events/{channel}' => sub { }, name => 'events'),
    ];
    my $routing = router(routes => $nodes);

    is($routing->path_for('health'), '/health', 'direct literal name renders without parameter hashes');
    is($routing->path_for('socket', { room => 'general' }), '/socket/general', 'WebSocket name renders a path');
    is($routing->path_for('events', { channel => 'news' }), '/events/news', 'SSE name renders a path');
    require PAGI::Routing::Resolver;
    my $resolver = PAGI::Routing::Resolver->new(routes => $nodes);
    is($resolver->route_kind('health'), 'route', 'resolver retains the HTTP route kind');
    is($resolver->route_kind('socket'), 'websocket', 'resolver retains the WebSocket route kind');
    is($resolver->route_kind('events'), 'sse', 'resolver retains the SSE route kind');
    is($resolver->route_kind('unknown'), undef, 'unknown route kind is undefined');
};

subtest 'inline paths and optional dot namespaces remain independent' => sub {
    my $unnamed_mount = mount('/public', routes => [
        route('/users/{id}' => sub { }, name => 'user.show'),
    ]);
    my $nested_mount = mount('/tenants/{tenant_id}', routes => [
        mount('/admin', routes => [
            route('/users/{user_id}' => sub { }, name => 'user.show'),
        ], namespace => 'api.v2'),
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
        $routing->path_for('user.show', { id => 7 }),
        '/public/users/7',
        'an unnamed mount leaves the child name unprefixed but contributes its path',
    );
    is(
        $routing->path_for('tenant.api.v2.user.show', {
            tenant_id => 'acme', user_id => 42,
        }),
        '/tenants/acme/admin/users/42',
        'nested dot namespaces affect only the effective name and all mount paths affect the path',
    );
    is(
        $routing->path_for('rooted.status'),
        '/status/',
        'a root mount contributes no extra slash and a leaf trailing slash remains exact',
    );
    is(
        $routing->path_for('exact.slashes'),
        '/prefix//double/',
        'concatenation does not normalize repeated or trailing route slashes',
    );
};

subtest 'reverse rendering validates complete ancestry and escapes path and query values' => sub {
    my $type = Local::ReverseType->new('right');
    my $routing = router(routes => [
        mount('/accounts/{account}', routes => [
            route(
                '/items/{item}' => sub { },
                name => 'item.show',
                constraints => { item => $type },
            ),
            route('/files/*path' => sub { }, name => 'files'),
        ], namespace => 'account'),
    ]);

    is(
        $routing->path_for(
            'account.item.show',
            { account => "caf\x{e9} space", item => 'right' },
            { z => 'last', 'a key' => 'A&B', empty => undef },
        ),
        '/accounts/caf%C3%A9%20space/items/right?a%20key=A%26B&empty=&z=last',
        'outer and leaf values render before a sorted escaped query with undefined as empty',
    );
    is(
        $routing->path_for('account.files', {
            account => 'main', path => '../private//read me/',
        }),
        '/accounts/main/files/../private//read%20me/',
        'wildcard rendering preserves separators while escaping each component',
    );

    like(
        dies { $routing->path_for('account.item.show', { item => 'right' }) },
        qr/missing path parameter 'account'.*route 'account\.item\.show'/,
        'missing outer parameter names the effective route',
    );
    like(
        dies {
            $routing->path_for('account.item.show', {
                account => 'main', item => 'right', extra => 1,
            });
        },
        qr/unexpected path parameter 'extra'.*route 'account\.item\.show'/,
        'extra parameters name the effective route',
    );
    like(
        dies {
            $routing->path_for('account.item.show', {
                account => 'main', item => 'wrong',
            });
        },
        qr/path parameter 'item' failed constraint for route 'account\.item\.show': expected right, got wrong/,
        'Type-compatible failures use get_message in a route-specific diagnostic',
    );
    like(
        dies { $routing->path_for('account.files', [], {}) },
        qr/path parameters for route 'account\.files' must be a hashref/,
        'path parameters must be a hashref',
    );
    like(
        dies {
            $routing->path_for(
                'account.files', { account => 'main', path => 'file' }, [],
            );
        },
        qr/query parameters for route 'account\.files' must be a hashref/,
        'query parameters must be a hashref',
    );
    like(
        dies {
            $routing->path_for(
                'account.files', { account => 'main', path => 'file' }, { bad => [] },
            );
        },
        qr/query parameter 'bad' must be a scalar/,
        'query values reject references',
    );
    like(
        dies { $routing->path_for('missing') },
        qr/unknown route name 'missing'/,
        'reverse generation croaks for an unknown route name',
    );
};

subtest 'namespaces prefix only leaves with declared names' => sub {
    my $single = router(routes => [
        mount('/api', routes => [
            route('/health' => sub { }),
        ], namespace => 'api'),
    ]);
    is($single->named_routes, {}, 'one namespaced unnamed leaf is absent from named_routes');
    is($single->route_named('api'), undef, 'a namespace alone is not a route name');

    is(
        dies {
            router(routes => [
                mount('/api', routes => [
                    route('/one' => sub { }),
                    route('/two' => sub { }),
                ], namespace => 'api'),
            ]);
        },
        undef,
        'multiple namespaced unnamed siblings do not collide during construction',
    );

    my $named_child = route('/users' => sub { }, name => 'users');
    my $named = router(routes => [
        mount('/api', routes => [$named_child], namespace => 'api'),
    ]);
    is(
        [sort keys %{$named->named_routes}],
        ['api.users'],
        'an existing child name still receives the namespace prefix',
    );
    is(
        refaddr($named->route_named('api.users')),
        refaddr($named_child),
        'the namespaced entry still preserves the named child identity',
    );
};

subtest 'effective names must be unique across direct and mounted declarations' => sub {
    like(
        dies {
            router(routes => [
                route('/one' => sub { }, name => 'same'),
                route('/two' => sub { }, name => 'same'),
            ]);
        },
        qr/duplicate effective route name 'same'.*'\/one'.*'\/two'.*add or change a namespace/,
        'two direct duplicate names report both effective paths and namespace guidance',
    );

    like(
        dies {
            router(routes => [
                mount('/v1', routes => [
                    route('/child' => sub { }, name => 'show'),
                ]),
                mount('/v2', routes => [
                    route('/child' => sub { }, name => 'show'),
                ]),
            ]);
        },
        qr/duplicate effective route name 'show'.*'\/v1\/child'.*'\/v2\/child'.*add or change a namespace/,
        'unnamed mounts exposing one child name report both effective paths',
    );

    like(
        dies {
            router(routes => [
                mount('/v1', routes => [
                    route('/child' => sub { }, name => 'show'),
                ], namespace => 'api'),
                mount('/v2', routes => [
                    route('/child' => sub { }, name => 'show'),
                ], namespace => 'api'),
            ]);
        },
        qr/duplicate effective route name 'api\.show'.*'\/v1\/child'.*'\/v2\/child'.*add or change a namespace/,
        'equal namespaces report the colliding effective name and both paths',
    );
};

subtest 'known inline ancestry must have unique path parameter names' => sub {
    like(
        dies {
            router(routes => [
                mount('/accounts/{id}', routes => [
                    mount('/groups/{group}', routes => [
                        route('/users/{id}' => sub { }, name => 'user.show'),
                    ]),
                ]),
            ]);
        },
        qr/duplicate path parameter 'id'.*effective path '\/accounts\/\{id\}\/groups\/\{group\}\/users\/\{id\}'/,
        'a leaf cannot reuse a path parameter declared by an inline mount ancestor',
    );
};

subtest 'tree inspection is defensive while preserving source node identity' => sub {
    my $direct = route('/health' => sub { }, name => 'health');
    my $user = route('/users' => sub { }, name => 'users.index');
    my $nested_leaf = websocket('/socket' => sub { }, name => 'socket');
    my $nested = mount('/nested', routes => [$nested_leaf], namespace => 'inner');
    my $inline = mount('/api', routes => [$user, $nested], namespace => 'api');

    my $hidden = route('/secret' => sub { }, name => 'hidden');
    my $application = router(routes => [$hidden]);
    my $opaque = mount('/opaque' => $application);
    my $routing = router(routes => [$direct, $inline, $opaque]);

    my $direct_children = $routing->routes;
    is(
        [ map { refaddr($_) } @$direct_children ],
        [ map { refaddr($_) } ($direct, $inline, $opaque) ],
        'router routes contains only direct children in declaration order',
    );
    pop @$direct_children;
    push @$direct_children, $hidden;
    is(
        [ map { refaddr($_) } @{$routing->routes} ],
        [ map { refaddr($_) } ($direct, $inline, $opaque) ],
        'mutating the returned root array does not affect later inspection',
    );

    my $inline_children = $inline->routes;
    is(
        [ map { refaddr($_) } @$inline_children ],
        [ map { refaddr($_) } ($user, $nested) ],
        'inline mount routes exposes direct children recursively in order',
    );
    shift @$inline_children;
    is(
        [ map { refaddr($_) } @{$inline->routes} ],
        [ map { refaddr($_) } ($user, $nested) ],
        'inline mount route arrays are defensive copies',
    );
    my $nested_children = $nested->routes;
    pop @$nested_children;
    is(
        [ map { refaddr($_) } @{$nested->routes} ],
        [ refaddr($nested_leaf) ],
        'nested inline inspection remains defensive',
    );
    is($opaque->routes, undef, 'an application mount remains an opaque inspection leaf');

    my $named = $routing->named_routes;
    is(
        [ sort keys %$named ],
        [qw(api.inner.socket api.users.index health)],
        'named route inspection includes effective inline names but no opaque application names',
    );
    is(refaddr($named->{health}), refaddr($direct), 'direct named route preserves original leaf identity');
    is(refaddr($named->{'api.users.index'}), refaddr($user), 'mounted named route preserves original leaf identity');
    is(refaddr($named->{'api.inner.socket'}), refaddr($nested_leaf), 'nested named route preserves original leaf identity');
    is(refaddr($routing->route_named('api.users.index')), refaddr($user), 'route_named returns the original leaf');
    is($routing->route_named('hidden'), undef, 'route_named cannot see inside an application mount');
    is($routing->route_named('missing'), undef, 'route_named returns undef for an unknown name');

    delete $named->{health};
    $named->{invented} = $hidden;
    is(refaddr($routing->route_named('health')), refaddr($direct), 'mutating named_routes cannot remove an internal entry');
    is($routing->route_named('invented'), undef, 'mutating named_routes cannot add an internal entry');
};

done_testing;
