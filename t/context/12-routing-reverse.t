#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test2::V0;
use Future;

use lib 'lib';
use PAGI::Context;
use PAGI::Middleware::ReverseProxy;
use PAGI::Middleware::TrustedHosts;
use PAGI::Routing qw(mount route router sse websocket);
use PAGI::Routing::Resolver;

sub _resolver {
    my (@routes) = @_;
    return PAGI::Routing::Resolver->new(routes => \@routes);
}

sub _frame {
    my ($resolver) = @_;
    return {
        resolver => $resolver,
        mounts   => [],
        match    => undef,
    };
}

sub _context {
    my ($type, $resolver, %scope) = @_;
    return PAGI::Context->new({
        type           => $type,
        headers        => [['host', 'example.test']],
        scheme         => 'http',
        root_path      => '',
        'pagi.routing' => {
            version => 1,
            frames  => [_frame($resolver)],
        },
        %scope,
    }, sub { }, sub { });
}

sub _run_compiled {
    my ($app, %scope) = @_;
    my @events;
    my $request_scope = {
        type        => 'http',
        method      => 'GET',
        path        => '/',
        root_path   => '',
        raw_path    => '/',
        path_params => {},
        headers     => [['host', 'example.test']],
        scheme      => 'http',
        %scope,
    };
    my $receive = sub { Future->done({ type => 'unused.receive' }) };
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };

    $app->($request_scope, $receive, $send)->get;
    return \@events;
}

subtest 'Context selects the last resolver from a valid routing frame stack' => sub {
    my $parent = _resolver(
        route('/parent/{id}' => sub { }, name => 'selected'),
    );
    my $child = _resolver(
        route('/child/{id}' => sub { }, name => 'selected'),
    );
    my $context = _context('http', $child,
        root_path => '/edge',
        'pagi.routing' => {
            version => 1,
            frames  => [_frame($parent), _frame($child)],
        },
    );

    is(
        $context->path_for('selected', { id => 7 }),
        '/edge/child/7',
        'the last frame supplies Context reverse paths',
    );
    is(
        $context->url_for('selected', { id => 7 }),
        'http://example.test/edge/child/7',
        'the last frame also supplies Context absolute URLs',
    );
};

subtest 'all built-in Context subclasses inherit routing reverse methods' => sub {
    my $resolver = _resolver(
        route('/page' => sub { }, name => 'page'),
    );

    for my $case (
        ['http',      'PAGI::Context::HTTP'],
        ['websocket', 'PAGI::Context::WebSocket'],
        ['sse',       'PAGI::Context::SSE'],
    ) {
        my ($type, $class) = @$case;
        my $context = _context($type, $resolver);
        isa_ok($context, $class);
        is($context->path_for('page'), '/page', "$class inherits path_for");
        is(
            $context->url_for('page'),
            'http://example.test/page',
            "$class inherits url_for",
        );
    }
};

subtest 'missing and malformed routing metadata fail at the Context boundary' => sub {
    my $resolver = _resolver(route('/page' => sub { }, name => 'page'));
    my @cases = (
        ['missing container', undef],
        ['foreign version', { version => 2, frames => [_frame($resolver)] }],
        ['frames are not an array', { version => 1, frames => {} }],
        ['frames are empty', { version => 1, frames => [] }],
        ['last frame is not a hash', { version => 1, frames => ['bad'] }],
        ['last frame lacks a resolver', {
            version => 1,
            frames  => [{ mounts => [], match => undef }],
        }],
        ['last frame has malformed mounts', {
            version => 1,
            frames  => [{ resolver => $resolver, mounts => {}, match => undef }],
        }],
        ['last frame has malformed match', {
            version => 1,
            frames  => [{ resolver => $resolver, mounts => [], match => [] }],
        }],
        ['last frame has malformed root_path', {
            version => 1,
            frames  => [{
                resolver  => $resolver,
                mounts    => [],
                match     => undef,
                root_path => [],
            }],
        }],
    );

    for my $case (@cases) {
        my ($label, $routing) = @$case;
        my %scope = (
            type    => 'http',
            headers => [['host', 'example.test']],
            scheme  => 'http',
        );
        $scope{'pagi.routing'} = $routing if defined $routing;
        my $context = PAGI::Context->new(\%scope, sub { }, sub { });

        like(
            dies { $context->path_for('page') },
            qr/\Apath_for requires a PAGI::Routing resolver in scope/,
            "$label is rejected by path_for",
        );
        like(
            dies { $context->url_for('page') },
            qr/\Aurl_for requires a PAGI::Routing resolver in scope/,
            "$label is rejected by url_for",
        );
    }
};

subtest 'compiled inline mounts reverse from the router boundary across protocols' => sub {
    my @seen;
    my $capture = sub {
        my ($label, $own_name, $own_params) = @_;
        return sub {
            my ($context) = @_;
            my $frame = $context->scope->{'pagi.routing'}{frames}[-1];
            push @seen, {
                label           => $label,
                scope_root_path => $context->scope->{root_path},
                frame_root_path => $frame->{root_path},
                own_path        => $context->path_for(
                    $own_name,
                    $own_params,
                    { via => $label },
                ),
                own_url         => $context->url_for(
                    $own_name,
                    $own_params,
                    { via => $label },
                ),
                sibling_path    => $context->path_for(
                    'tenant.sibling',
                    { tenant => 'acme', id => 8 },
                    { via => $label },
                ),
                sibling_url     => $context->url_for(
                    'tenant.sibling',
                    { tenant => 'acme', id => 8 },
                    { via => $label },
                ),
            };
            return $context->text('ok') if $label eq 'http';
            return;
        };
    };

    my $app = router(routes => [
        mount('/tenants/{tenant}', routes => [
            route('/show/{id}' => $capture->(
                'http', 'tenant.show', { tenant => 'acme', id => 7 },
            ), name => 'show'),
            route('/sibling/{id}' => sub { return $_[0]->text('sibling') },
                name => 'sibling'),
            websocket('/socket/{room}' => $capture->(
                'ws', 'tenant.socket', { tenant => 'acme', room => 'lobby' },
            ), name => 'socket'),
            sse('/events/{channel}' => $capture->(
                'sse', 'tenant.events', { tenant => 'acme', channel => 'news' },
            ), name => 'events'),
        ], namespace => 'tenant'),
    ])->to_app;

    _run_compiled($app,
        path      => '/tenants/acme/show/7',
        raw_path  => '/proxy/tenants/acme/show/7',
        root_path => '/proxy',
        scheme    => 'https',
        headers   => [['host', 'public.example:8443']],
    );
    _run_compiled($app,
        type      => 'websocket',
        path      => '/tenants/acme/socket/lobby',
        raw_path  => '/proxy/tenants/acme/socket/lobby',
        root_path => '/proxy',
        scheme    => 'wss',
        headers   => [['host', 'public.example:8443']],
    );
    _run_compiled($app,
        type      => 'sse',
        path      => '/tenants/acme/events/news',
        raw_path  => '/proxy/tenants/acme/events/news',
        root_path => '/proxy',
        scheme    => 'https',
        headers   => [['host', 'public.example:8443']],
    );

    is(\@seen, [
        {
            label           => 'http',
            scope_root_path => '/proxy/tenants/acme',
            frame_root_path => '/proxy',
            own_path        => '/proxy/tenants/acme/show/7?via=http',
            own_url         => 'https://public.example:8443/proxy/tenants/acme/show/7?via=http',
            sibling_path    => '/proxy/tenants/acme/sibling/8?via=http',
            sibling_url     => 'https://public.example:8443/proxy/tenants/acme/sibling/8?via=http',
        },
        {
            label           => 'ws',
            scope_root_path => '/proxy/tenants/acme',
            frame_root_path => '/proxy',
            own_path        => '/proxy/tenants/acme/socket/lobby?via=ws',
            own_url         => 'wss://public.example:8443/proxy/tenants/acme/socket/lobby?via=ws',
            sibling_path    => '/proxy/tenants/acme/sibling/8?via=ws',
            sibling_url     => 'https://public.example:8443/proxy/tenants/acme/sibling/8?via=ws',
        },
        {
            label           => 'sse',
            scope_root_path => '/proxy/tenants/acme',
            frame_root_path => '/proxy',
            own_path        => '/proxy/tenants/acme/events/news?via=sse',
            own_url         => 'https://public.example:8443/proxy/tenants/acme/events/news?via=sse',
            sibling_path    => '/proxy/tenants/acme/sibling/8?via=sse',
            sibling_url     => 'https://public.example:8443/proxy/tenants/acme/sibling/8?via=sse',
        },
    ], 'inline mount prefixes appear once and sibling targets use the same router boundary');
};

subtest 'a separately compiled child records and uses its own router boundary' => sub {
    my @seen;
    my $child = router(routes => [
        mount('/spaces/{space}', routes => [
            route('/items/{id}' => sub {
                my ($context) = @_;
                my $frames = $context->scope->{'pagi.routing'}{frames};
                push @seen, {
                    scope_root_paths => [map { $_->{root_path} } @$frames],
                    current_scope    => $context->scope->{root_path},
                    item_path        => $context->path_for(
                        'item', { space => 'blue', id => 9 }, { q => 'two words' },
                    ),
                    sibling_url     => $context->url_for(
                        'sibling', { space => 'blue', id => 10 }, { q => 'two words' },
                    ),
                };
                return $context->text('child');
            }, name => 'item'),
            route('/siblings/{id}' => sub { return $_[0]->text('sibling') },
                name => 'sibling'),
        ]),
    ])->to_app;
    my $parent = router(routes => [
        mount('/service' => $child),
    ])->to_app;

    _run_compiled($parent,
        path      => '/service/spaces/blue/items/9',
        raw_path  => '/proxy/service/spaces/blue/items/9',
        root_path => '/proxy',
        scheme    => 'https',
        headers   => [['host', 'public.example']],
    );

    is(\@seen, [{
        scope_root_paths => ['/proxy', '/proxy/service'],
        current_scope    => '/proxy/service/spaces/blue',
        item_path        => '/proxy/service/spaces/blue/items/9?q=two%20words',
        sibling_url      => 'https://public.example/proxy/service/spaces/blue/siblings/10?q=two%20words',
    }], 'the child frame excludes its parent application mount and its own inline prefix');
};

subtest 'compiled routers reject a non-scalar current root_path boundary' => sub {
    my $app = route('/inside' => sub { return $_[0]->text('inside') },
        name => 'inside')->to_app;

    like(
        dies {
            _run_compiled($app,
                path      => '/inside',
                raw_path  => '/inside',
                root_path => [],
            );
        },
        qr/\Ascope root_path must be a string/,
        'an invalid current boundary is rejected before a routing frame is published',
    );
};

subtest 'Context paths add root_path only at the application boundary' => sub {
    my $routing = router(routes => [
        route('/items/{id}' => sub { }, name => 'item'),
        route('/' => sub { }, name => 'root'),
        route('//double/' => sub { }, name => 'double'),
    ]);
    my $resolver = PAGI::Routing::Resolver->new(routes => $routing->routes);

    is(
        _context('http', $resolver)->path_for('item', { id => 'one' }),
        '/items/one',
        'an empty root_path leaves the application path unchanged',
    );
    is(
        _context('http', $resolver, root_path => '/proxy/')
            ->path_for('item', { id => 'one' }, { q => 'two words' }),
        '/proxy/items/one?q=two%20words',
        'one boundary slash is removed while the generated query is retained',
    );
    is(
        _context('http', $resolver, root_path => '/')
            ->path_for('item', { id => 'one' }),
        '/items/one',
        'a root-only deployment prefix does not duplicate the leading slash',
    );
    is(
        _context('http', $resolver, root_path => '/proxy/')
            ->path_for('root'),
        '/proxy/',
        'an application root keeps one terminal boundary slash',
    );
    is(
        _context('http', $resolver, root_path => '/proxy/')
            ->path_for('double'),
        '/proxy//double/',
        'joining the boundary does not normalize route-internal slashes',
    );
    is(
        $routing->path_for('item', { id => 'one' }, { q => 'two words' }),
        '/items/one?q=two%20words',
        'router path_for remains request-independent',
    );
};

subtest 'Context URI-encodes decoded root_path without re-encoding generated paths' => sub {
    my $resolver = _resolver(
        route('/items/{id}' => sub { }, name => 'item'),
    );
    my $context = _context('http', $resolver,
        root_path => "/proxy space/50%/caf\x{e9}/",
        scheme    => 'https',
        headers   => [['host', 'public.example']],
    );

    is(
        $context->path_for('item', { id => 'a b%' }, { q => "caf\x{e9} %" }),
        '/proxy%20space/50%25/caf%C3%A9/items/a%20b%25?q=caf%C3%A9%20%25',
        'path_for encodes the decoded prefix component-wise and preserves the generated query',
    );
    is(
        $context->url_for('item', { id => 'a b%' }, { q => "caf\x{e9} %" }),
        'https://public.example/proxy%20space/50%25/caf%C3%A9/items/a%20b%25?q=caf%C3%A9%20%25',
        'url_for emits the same single-encoded path after the authority',
    );
};

subtest 'a dynamic application mount keeps scope paths decoded and reverses from its encoded child boundary' => sub {
    my @seen;
    my $child = router(routes => [
        route('/items/{id}' => sub {
            my ($context) = @_;
            my $frames = $context->scope->{'pagi.routing'}{frames};
            push @seen, {
                scope_root_path => $context->scope->{root_path},
                frame_root_path => $frames->[-1]{root_path},
                path => $context->path_for(
                    'item', { id => 'a b%' }, { q => "caf\x{e9} %" },
                ),
                url => $context->url_for(
                    'item', { id => 'a b%' }, { q => "caf\x{e9} %" },
                ),
            };
            return $context->text('child');
        }, name => 'item'),
    ])->to_app;
    my $parent = router(routes => [
        mount('/tenants/{tenant}' => $child),
    ])->to_app;

    _run_compiled($parent,
        path      => "/tenants/caf\x{e9} 50%/items/current",
        raw_path  => '/edge%20root/tenants/caf%C3%A9%2050%25/items/current',
        root_path => '/edge root/',
        scheme    => 'https',
        headers   => [['host', 'public.example']],
    );

    is(
        \@seen,
        [{
            scope_root_path => "/edge root/tenants/caf\x{e9} 50%",
            frame_root_path => "/edge root/tenants/caf\x{e9} 50%",
            path => '/edge%20root/tenants/caf%C3%A9%2050%25/items/a%20b%25?q=caf%C3%A9%20%25',
            url => 'https://public.example/edge%20root/tenants/caf%C3%A9%2050%25/items/a%20b%25?q=caf%C3%A9%20%25',
        }],
        'the mounted child sees decoded scope data and emits each prefix and generated value exactly once',
    );
};

subtest 'url_for uses validated Host and only absent Host permits server fallback' => sub {
    my $resolver = _resolver(route('/page' => sub { }, name => 'page'));

    is(
        _context('http', $resolver,
            scheme  => 'https',
            headers => [['host', 'public.example:8443']],
            server  => ['internal.example', 9000],
        )->url_for('page'),
        'https://public.example:8443/page',
        'a validated Host with an explicit port wins over server',
    );
    is(
        _context('http', $resolver,
            scheme  => 'https',
            headers => [],
            server  => ['fallback.example', 9443],
        )->url_for('page'),
        'https://fallback.example:9443/page',
        'server supplies authority only when Host is absent',
    );

    like(
        dies {
            _context('http', $resolver,
                headers => [['host', 'bad host']],
                server  => ['fallback.example', 80],
            )->url_for('page');
        },
        qr/\Ainvalid authority/,
        'a malformed Host failure propagates without server fallback',
    );
    like(
        dies {
            _context('http', $resolver,
                headers => [['host', 'one.example'], ['Host', 'two.example']],
                server  => ['fallback.example', 80],
            )->url_for('page');
        },
        qr/\AHost header must occur at most once/,
        'a duplicate Host failure propagates without server fallback',
    );
    like(
        dies {
            _context('http', $resolver, headers => [], server => undef)
                ->url_for('page');
        },
        qr/\Ascope server cannot provide an authority/,
        'url_for croaks when neither Host nor server can supply authority',
    );
};

subtest 'documented HTTP proxy and Host middleware order feeds routing URL generation' => sub {
    my $routing = router(routes => [
        route('/external' => sub {
            my ($context) = @_;
            return $context->text($context->url_for('external'));
        }, name => 'external'),
    ]);
    my $trusted = PAGI::Middleware::TrustedHosts->new(
        hosts => ['public.example:8443'],
    );
    my $proxy = PAGI::Middleware::ReverseProxy->new(
        trusted_proxies => ['127.0.0.1'],
    );
    my $app = $proxy->wrap($trusted->wrap($routing->to_app));

    my $events = _run_compiled(
        $app,
        path     => '/external',
        raw_path => '/external',
        client   => ['127.0.0.1', 12345],
        server   => ['internal.example', 5000],
        headers  => [
            ['host', 'internal.example'],
            ['x-forwarded-proto', 'https'],
            ['x-forwarded-host', 'public.example:8443'],
        ],
    );

    is($events->[0]{status}, 200,
        'TrustedHosts accepts the external authority installed by ReverseProxy');
    is($events->[1]{body}, 'https://public.example:8443/external',
        'url_for consumes the proxy-normalized scheme and validated authority');

    my $missing_calls = 0;
    my $missing_routing = router(routes => [
        route('/missing' => sub {
            my ($context) = @_;
            ++$missing_calls;
            return $context->text($context->url_for('missing'));
        }, name => 'missing'),
    ]);
    my $allow_empty = PAGI::Middleware::TrustedHosts->new(
        hosts       => ['public.example'],
        allow_empty => 1,
    );
    my $missing_app = $proxy->wrap(
        $allow_empty->wrap($missing_routing->to_app),
    );

    like(
        dies {
            _run_compiled(
                $missing_app,
                path     => '/missing',
                raw_path => '/missing',
                client   => ['127.0.0.1', 12345],
                server   => undef,
                headers  => [],
            );
        },
        qr/\Ascope server cannot provide an authority/,
        'a composed stack still exposes missing authority at the url_for boundary',
    );
    is($missing_calls, 1,
        'allow_empty Host policy lets routing enforce absolute-URL authority');
};

subtest 'url_for maps the request scheme according to the named route kind' => sub {
    my $resolver = _resolver(
        route('/page' => sub { }, name => 'page'),
        websocket('/socket' => sub { }, name => 'socket'),
        sse('/events' => sub { }, name => 'events'),
    );

    my @cases = (
        ['http target keeps http',             'page',   'http',
            'http://example.test/page'],
        ['http target keeps https',            'page',   'https',
            'https://example.test/page'],
        ['http target maps ws to http',        'page',   'ws',
            'http://example.test/page'],
        ['http target maps wss to https',      'page',   'wss',
            'https://example.test/page'],
        ['SSE target maps ws to http',         'events', 'ws',
            'http://example.test/events'],
        ['SSE target maps wss to https',       'events', 'wss',
            'https://example.test/events'],
        ['WebSocket target maps http to ws',   'socket', 'http',
            'ws://example.test/socket'],
        ['WebSocket target maps https to wss', 'socket', 'https',
            'wss://example.test/socket'],
        ['WebSocket target keeps ws',          'socket', 'ws',
            'ws://example.test/socket'],
        ['WebSocket target keeps wss',         'socket', 'wss',
            'wss://example.test/socket'],
    );

    for my $case (@cases) {
        my ($label, $name, $scope_scheme, $expected) = @$case;
        is(
            _context('http', $resolver, scheme => $scope_scheme)->url_for($name),
            $expected,
            $label,
        );
    }

    my $missing_scheme = _context('http', $resolver);
    delete $missing_scheme->scope->{scheme};
    is(
        $missing_scheme->url_for('page'),
        'http://example.test/page',
        'a missing scheme defaults to http',
    );
    like(
        dies { _context('http', $resolver, scheme => 'ftp')->url_for('page') },
        qr/\Aunsupported URL scheme/,
        'an unsupported scheme croaks instead of inventing a mapping',
    );
};

done_testing;
