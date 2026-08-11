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

{
    package Local::ContextReverseProvider;
    our $CALLS = 0;
    sub Account {
        ++$CALLS;
        return qr/acme/;
    }
}

sub _resolver {
    my (@routes) = @_;
    return PAGI::Routing::Resolver->new(routes => \@routes);
}

sub _frame {
    my ($resolver, %changes) = @_;
    return {
        resolver          => $resolver,
        logical_namespace => '/',
        captures          => {},
        mounts            => [],
        match             => undef,
        %changes,
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
        $context->path_for('/selected', { id => 7 }),
        '/edge/child/7',
        'the last frame supplies Context reverse paths',
    );
    is(
        $context->url_for('/selected', { id => 7 }),
        'http://example.test/edge/child/7',
        'the last frame also supplies Context absolute URLs',
    );
};

subtest 'compiled Context references resolve exactly from the matched containing namespace' => sub {
    my (@show_results, @catchall_results);
    my $routing;
    $routing = router(routes => [
        route('/' => sub { return $_[0]->text('home') }, name => 'home'),
        mount('/person', routes => [
            route('/{person_id}' => sub { return $_[0]->text('person') },
                name => 'show'),
            mount('/{person_id}/blog', routes => [
                route('/' => sub { return $_[0]->text('blogs') }, name => 'index'),
                route('/{blog_id}' => sub {
                    my ($c) = @_;
                    my $frame = $c->scope->{'pagi.routing'}{frames}[-1];
                    push @show_results, {
                        logical_namespace => $frame->{logical_namespace},
                        captures         => { %{$frame->{captures}} },
                        show             => $c->path_for('show'),
                        index            => $c->path_for('index'),
                        parent_show      => $c->path_for('../show'),
                        dot_show         => $c->path_for('./show'),
                        interior_show    => $c->path_for('x/../show'),
                        override         => $c->path_for('show', { blog_id => 8 }),
                        absolute_home    => $c->path_for('/home'),
                        relative_home    => $c->path_for('../../home'),
                        absolute_show    => $c->path_for(
                            '/person/blog/show',
                            { person_id => 42, blog_id => 9 },
                        ),
                        with_suffixes    => $c->url_for(
                            'show',
                            query    => { view => 'full' },
                            fragment => 'comments',
                        ),
                    };

                    my @failures = (
                        ['unknown relative', 'missing', qr/unknown route name 'missing'/],
                        ['no overlap folding', 'person/show', qr/unknown route name 'person\/show'/],
                        ['above root', '../../../home', qr/traverses above the Router root/],
                        ['bare current namespace', '.', qr/resolves to a logical namespace/],
                        ['bare parent namespace', '..', qr/resolves to a logical namespace/],
                        ['repeated slash', 'show//child', qr/contains an empty logical segment/],
                        ['trailing slash', 'show/', qr/contains an empty logical segment/],
                    );
                    for my $failure (@failures) {
                        my ($label, $reference, $message) = @$failure;
                        like(dies { $c->path_for($reference) }, $message, $label);
                    }
                    like(
                        dies { $c->path_for('/person/blog/show') },
                        qr/missing path parameter 'person_id'/,
                        'absolute Context references inherit no captures',
                    );
                    like(
                        dies { $routing->path_for('/person/blog/show') },
                        qr/missing path parameter 'person_id'/,
                        'Router-object reverse calls inherit no request captures',
                    );
                    like(
                        dies { $c->path_for('index', { extra => 1 }) },
                        qr/unexpected path parameter 'extra'/,
                        'explicit parameters not required by the target still fail',
                    );
                    like(
                        dies { $c->path_for('show', { blog_id => 'bad' }) },
                        qr/path parameter 'blog_id' failed constraint/,
                        'constraints run after explicit values replace inherited captures',
                    );
                    return $c->text('show');
                },
                    name => 'show',
                    constraints => { blog_id => qr/\A\d+\z/ },
                ),
                route('/*rest' => sub {
                    my ($c) = @_;
                    my $frame = $c->scope->{'pagi.routing'}{frames}[-1];
                    push @catchall_results, {
                        logical_namespace => $frame->{logical_namespace},
                        captures          => { %{$frame->{captures}} },
                        index             => $c->path_for('index'),
                    };
                    return $c->text('catchall');
                }),
            ], name      => 'blog'),
        ], name      => 'person'),
    ]);
    my $app = $routing->to_app;

    _run_compiled($app,
        path => '/person/42/blog/7',
        raw_path => '/person/42/blog/7',
        scheme => 'https',
    );
    _run_compiled($app,
        path => '/person/42/blog/missing/path',
        raw_path => '/person/42/blog/missing/path',
    );

    is(\@show_results, [{
        logical_namespace => '/person/blog',
        captures      => { person_id => 42, blog_id => 7 },
        show          => '/person/42/blog/7',
        index         => '/person/42/blog/',
        parent_show   => '/person/42',
        dot_show      => '/person/42/blog/7',
        interior_show => '/person/42/blog/7',
        override      => '/person/42/blog/8',
        absolute_home => '/',
        relative_home => '/',
        absolute_show => '/person/42/blog/9',
        with_suffixes => 'https://example.test/person/42/blog/7?view=full#comments',
    }], 'relative Context generation uses the exact active namespace and target captures');
    is(\@catchall_results, [{
        logical_namespace => '/person/blog',
        captures          => { person_id => 42, rest => 'missing/path' },
        index             => '/person/42/blog/',
    }], 'an unnamed catchall keeps its containing namespace and filters its wildcard capture');
};

subtest 'Context prefers an exact leaf that shares a namespace address' => sub {
    my $api = route('/direct-api' => sub { }, name => 'api');
    my $resolver = _resolver(
        $api,
        mount('/nested-api', routes => [
            route('/x' => sub { }, name => 'x'),
        ], name      => 'api'),
        mount('/group', routes => [
            route('/x' => sub { }, name => 'x'),
        ], name      => 'group'),
    );
    my $root = _context('http', $resolver);
    my $nested = PAGI::Context->new({
        type      => 'http',
        headers   => [['host', 'example.test']],
        scheme    => 'http',
        root_path => '',
        'pagi.routing' => {
            version => 1,
            frames => [_frame(
                $resolver,
                logical_namespace => '/api',
            )],
        },
    }, sub { }, sub { });

    my ($absolute, $root_relative, $parent_relative, $absolute_child,
        $relative_child);
    is(lives { $absolute = $root->path_for('/api') }, T(),
        'Context absolute exact-leaf lookup does not fail as namespace-only');
    is($absolute, '/direct-api',
        'Context absolute lookup selects the exact leaf');
    is(lives { $root_relative = $root->path_for('api') }, T(),
        'Context root-relative exact-leaf lookup does not fail as namespace-only');
    is($root_relative, '/direct-api',
        'Context relative lookup selects the exact leaf from root');
    is(lives { $parent_relative = $nested->path_for('../api') }, T(),
        'Context parent-relative exact-leaf lookup does not fail as namespace-only');
    is($parent_relative, '/direct-api',
        'Context relative parent lookup selects the exact leaf from a child namespace');
    is(lives { $absolute_child = $root->path_for('/api/x') }, T(),
        'Context absolute descendant lookup remains available');
    is($absolute_child, '/nested-api/x',
        'Context still resolves a descendant below the shared namespace');
    is(lives { $relative_child = $nested->path_for('x') }, T(),
        'Context relative descendant lookup remains available');
    is($relative_child, '/nested-api/x',
        'Context keeps local descendant lookup in the shared namespace');

    like(
        dies { $root->path_for('/group') },
        qr/resolves to a logical namespace, not a route/,
        'Context still rejects a namespace without an exact leaf',
    );
    like(
        dies { $root->path_for('api/.') },
        qr/resolves to a logical namespace, not a route/,
        'Context terminal dot remains namespace-only at a leaf address',
    );
    like(
        dies { $root->path_for('api/child/..') },
        qr/resolves to a logical namespace, not a route/,
        'Context terminal dot-dot remains namespace-only at a leaf address',
    );
};

subtest 'Context inheritance selects only target path keys and never invents suffixes' => sub {
    my $resolver = _resolver(
        route('/target/{required}' => sub { }, name => 'target'),
    );
    my $context = PAGI::Context->new({
        type      => 'http',
        headers   => [['host', 'example.test']],
        scheme    => 'http',
        root_path => '',
        'pagi.routing' => {
            version => 1,
            frames  => [_frame($resolver,
                logical_namespace => '/',
                captures => {
                    required => 'kept',
                    query    => 'must-not-appear',
                    fragment => 'must-not-appear',
                    unused   => 'must-not-be-an-extra-param',
                },
            )],
        },
    }, sub { }, sub { });

    is(
        $context->path_for('target'),
        '/target/kept',
        'only target-required path keys are inherited and query/fragment stay absent',
    );
    is(
        $context->path_for('target', { required => 'explicit' }),
        '/target/explicit',
        'explicit path parameters override inherited values',
    );
};

subtest 'Context path_for and url_for share compact and named reverse arguments' => sub {
    my $resolver = _resolver(
        route('/items/{id}' => sub { }, name => 'show'),
        route('/items' => sub { }, name => 'index'),
    );
    my ($receive_calls, $send_calls) = (0, 0);
    my $context = PAGI::Context->new({
        type      => 'http',
        headers   => [['host', 'example.test']],
        scheme    => 'https',
        root_path => '/edge',
        'pagi.routing' => {
            version => 1,
            frames  => [_frame($resolver)],
        },
    }, sub { ++$receive_calls }, sub { ++$send_calls });

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
            query => { q => 'two words' }, params => { id => 7 }],
            '/items/7?q=two%20words#details'],
        ['named query first', ['/show', query => { q => 'two words' },
            params => { id => 7 }], '/items/7?q=two%20words'],
        ['compact undef fragment', ['/show', { id => 7 }, {}, undef], '/items/7'],
        ['named undef fragment', ['/show', fragment => undef, params => { id => 7 }],
            '/items/7'],
        ['compact empty fragment', ['/show', { id => 7 }, {}, ''], '/items/7#'],
        ['named empty fragment', ['/show', params => { id => 7 }, fragment => ''],
            '/items/7#'],
    );

    for my $case (@cases) {
        my ($label, $args, $suffix) = @$case;
        is($context->path_for(@$args), "/edge$suffix", "path_for $label");
        is($context->url_for(@$args), "https://example.test/edge$suffix",
            "url_for $label");
    }
    is($receive_calls, 0, 'reverse routing performs no receive I/O');
    is($send_calls, 0, 'reverse routing performs no send I/O');
};

subtest 'Context reverse methods share operation-specific argument failures' => sub {
    my $resolver = _resolver(
        route('/items/{id}' => sub { }, name => 'show'),
    );
    my $context = _context('http', $resolver);
    my $object = bless {}, 'Local::ContextReverseArgumentsObject';
    my $scalar = 'value';

    my @cases = (
        ['too many compact values', ['/show', {}, {}, 'section', 'extra'],
            'compact form accepts at most params, query, and fragment'],
        ['compact query array', ['/show', {}, []], 'compact query must be a hashref'],
        ['compact fragment object', ['/show', {}, {}, $object],
            'compact fragment must be a plain scalar or undef'],
        ['undef selector', ['/show', undef],
            'form selector must be a hashref or named option key'],
        ['array selector', ['/show', []],
            'form selector must be a hashref or named option key'],
        ['object selector', ['/show', $object],
            'form selector must be a hashref or named option key'],
        ['scalar-ref selector', ['/show', \$scalar],
            'form selector must be a hashref or named option key'],
        ['odd named list', ['/show', params => { id => 7 }, 'query'],
            'named option list must contain key/value pairs'],
        ['unknown named key', ['/show', parameters => { id => 7 }],
            "unknown named option 'parameters'"],
        ['named params array', ['/show', params => []],
            'named params must be a hashref'],
        ['named query object', ['/show', query => $object],
            'named query must be a hashref'],
        ['named fragment scalar ref', ['/show', fragment => \$scalar],
            'named fragment must be a plain scalar or undef'],
        ['mixed forms', ['/show', { id => 8 }, query => { view => 'full' }],
            'compact and named reverse-routing forms cannot be mixed'],
    );

    for my $operation (qw(path_for url_for)) {
        for my $case (@cases) {
            my ($label, $args, $message) = @$case;
            like(
                dies { $context->$operation(@$args) },
                qr/\A\Q$operation reverse-routing $message\E/,
                "$operation $label",
            );
        }
    }
};

subtest 'Context terminal navigation always denotes a namespace' => sub {
    my $resolver = _resolver(
        route('/show' => sub { }, name => 'show'),
    );
    my $context = _context('http', $resolver);

    for my $operation (qw(path_for url_for)) {
        for my $reference ('show/.', 'show/child/..') {
            like(
                dies { $context->$operation($reference) },
                qr/\A\Q$operation route reference '$reference' resolves to a logical namespace, not a route\E/,
                "$operation rejects terminal navigation landing on a leaf for $reference",
            );
        }
    }
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
        is($context->path_for('/page'), '/page', "$class inherits path_for");
        is(
            $context->url_for('/page'),
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
                logical_namespace => '/',
                captures  => {},
                mounts    => [],
                match     => undef,
                root_path => [],
            }],
        }],
        ['last frame lacks a logical namespace', {
            version => 1,
            frames  => [{
                resolver => $resolver,
                captures => {},
                mounts   => [],
                match    => undef,
            }],
        }],
        ['last frame has a non-scalar logical namespace', {
            version => 1,
            frames  => [_frame($resolver, logical_namespace => [])],
        }],
        ['last frame has a relative logical namespace', {
            version => 1,
            frames  => [_frame($resolver, logical_namespace => 'person')],
        }],
        ['last frame has a trailing-slash logical namespace', {
            version => 1,
            frames  => [_frame($resolver, logical_namespace => '/person/')],
        }],
        ['last frame has a navigation logical namespace', {
            version => 1,
            frames  => [_frame($resolver, logical_namespace => '/person/../blog')],
        }],
        ['last frame lacks captures', {
            version => 1,
            frames  => [{
                resolver          => $resolver,
                logical_namespace => '/',
                mounts            => [],
                match             => undef,
            }],
        }],
        ['last frame has malformed captures', {
            version => 1,
            frames  => [_frame($resolver, captures => [])],
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
            dies { $context->path_for('/page') },
            qr/\Apath_for requires a PAGI::Routing resolver in scope/,
            "$label is rejected by path_for",
        );
        like(
            dies { $context->url_for('/page') },
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
                    '/tenant/sibling',
                    { tenant => 'acme', id => 8 },
                    { via => $label },
                ),
                sibling_url     => $context->url_for(
                    '/tenant/sibling',
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
                'http', '/tenant/show', { tenant => 'acme', id => 7 },
            ), name => 'show'),
            route('/sibling/{id}' => sub { return $_[0]->text('sibling') },
                name => 'sibling'),
            websocket('/socket/{room}' => $capture->(
                'ws', '/tenant/socket', { tenant => 'acme', room => 'lobby' },
            ), name => 'socket'),
            sse('/events/{channel}' => $capture->(
                'sse', '/tenant/events', { tenant => 'acme', channel => 'news' },
            ), name => 'events'),
        ], name      => 'tenant'),
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

subtest 'Context reverse generation inherits captures and applies each composed predicate once' => sub {
    $Local::ContextReverseProvider::CALLS = 0;
    my $explicit_calls = 0;
    my @seen;
    my $app = router(routes => [
        mount('/accounts/{account:&Local::ContextReverseProvider::Account}',
            routes => [
                route('/items/{item}' => sub {
                    my ($context) = @_;
                    $explicit_calls = 0;
                    my $path = $context->path_for('show', { item => 'good' });
                    my $after_path = $explicit_calls;
                    my $url = $context->url_for(
                        'show',
                        { item => 'good' },
                        { q => 'two words' },
                        'details',
                    );
                    my $after_url = $explicit_calls;
                    my $invalid = dies {
                        $context->url_for('show', { item => 'bad' });
                    };
                    push @seen, {
                        path       => $path,
                        url        => $url,
                        after_path => $after_path,
                        after_url  => $after_url,
                        after_bad  => $explicit_calls,
                        invalid    => $invalid,
                    };
                    return $context->text('reverse');
                },
                    name => 'show',
                    constraints => {
                        item => sub {
                            ++$explicit_calls;
                            return $_[0] eq 'good';
                        },
                    },
                ),
            ],
            name      => 'account',
        ),
    ])->to_app;

    my $events = _run_compiled($app,
        path      => '/accounts/acme/items/good',
        raw_path  => '/edge/accounts/acme/items/good',
        root_path => '/edge',
        scheme    => 'https',
        headers   => [['host', 'public.example']],
    );

    is($seen[0]{path}, '/edge/accounts/acme/items/good',
        'relative path_for inherits the valid mount capture');
    is($seen[0]{url},
        'https://public.example/edge/accounts/acme/items/good?q=two%20words#details',
        'url_for validates the leaf and appends query and fragment');
    is([$seen[0]{after_path}, $seen[0]{after_url}, $seen[0]{after_bad}],
        [1, 2, 3],
        'each successful or failed render applies the explicit leaf predicate exactly once');
    like($seen[0]{invalid}, qr/path parameter 'item' failed constraint/,
        'url_for rejects an invalid explicit leaf value');
    is($Local::ContextReverseProvider::CALLS, 1,
        'Context dispatch and reverse generation do not reinvoke the mount provider');
    is($events->[0]{status}, 200, 'the provider-backed request still completes normally');
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
                        '/item', { space => 'blue', id => 9 }, { q => 'two words' },
                    ),
                    sibling_url     => $context->url_for(
                        '/sibling', { space => 'blue', id => 10 }, { q => 'two words' },
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
        _context('http', $resolver)->path_for('/item', { id => 'one' }),
        '/items/one',
        'an empty root_path leaves the application path unchanged',
    );
    is(
        _context('http', $resolver, root_path => '/proxy/')
            ->path_for('/item', { id => 'one' }, { q => 'two words' }),
        '/proxy/items/one?q=two%20words',
        'one boundary slash is removed while the generated query is retained',
    );
    is(
        _context('http', $resolver, root_path => '/')
            ->path_for('/item', { id => 'one' }),
        '/items/one',
        'a root-only deployment prefix does not duplicate the leading slash',
    );
    is(
        _context('http', $resolver, root_path => '/proxy/')
            ->path_for('/root'),
        '/proxy/',
        'an application root keeps one terminal boundary slash',
    );
    is(
        _context('http', $resolver, root_path => '/proxy/')
            ->path_for('/double'),
        '/proxy//double/',
        'joining the boundary does not normalize route-internal slashes',
    );
    is(
        $routing->path_for('/item', { id => 'one' }, { q => 'two words' }),
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
        $context->path_for('/item', { id => 'a b%' }, { q => "caf\x{e9} %" }),
        '/proxy%20space/50%25/caf%C3%A9/items/a%20b%25?q=caf%C3%A9%20%25',
        'path_for encodes the decoded prefix component-wise and preserves the generated query',
    );
    is(
        $context->url_for('/item', { id => 'a b%' }, { q => "caf\x{e9} %" }),
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
                    '/item', { id => 'a b%' }, { q => "caf\x{e9} %" },
                ),
                url => $context->url_for(
                    '/item', { id => 'a b%' }, { q => "caf\x{e9} %" },
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
        )->url_for('/page'),
        'https://public.example:8443/page',
        'a validated Host with an explicit port wins over server',
    );
    is(
        _context('http', $resolver,
            scheme  => 'https',
            headers => [],
            server  => ['fallback.example', 9443],
        )->url_for('/page'),
        'https://fallback.example:9443/page',
        'server supplies authority only when Host is absent',
    );

    like(
        dies {
            _context('http', $resolver,
                headers => [['host', 'bad host']],
                server  => ['fallback.example', 80],
            )->url_for('/page');
        },
        qr/\Ainvalid authority/,
        'a malformed Host failure propagates without server fallback',
    );
    like(
        dies {
            _context('http', $resolver,
                headers => [['host', 'one.example'], ['Host', 'two.example']],
                server  => ['fallback.example', 80],
            )->url_for('/page');
        },
        qr/\AHost header must occur at most once/,
        'a duplicate Host failure propagates without server fallback',
    );
    like(
        dies {
            _context('http', $resolver, headers => [], server => undef)
                ->url_for('/page');
        },
        qr/\Ascope server cannot provide an authority/,
        'url_for croaks when neither Host nor server can supply authority',
    );
};

subtest 'documented HTTP proxy and Host middleware order feeds routing URL generation' => sub {
    my $routing = router(routes => [
        route('/external' => sub {
            my ($context) = @_;
            return $context->text($context->url_for('/external'));
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
            return $context->text($context->url_for('/missing'));
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
        ['http target keeps http',             '/page',   'http',
            'http://example.test/page'],
        ['http target keeps https',            '/page',   'https',
            'https://example.test/page'],
        ['http target maps ws to http',        '/page',   'ws',
            'http://example.test/page'],
        ['http target maps wss to https',      '/page',   'wss',
            'https://example.test/page'],
        ['SSE target maps ws to http',         '/events', 'ws',
            'http://example.test/events'],
        ['SSE target maps wss to https',       '/events', 'wss',
            'https://example.test/events'],
        ['WebSocket target maps http to ws',   '/socket', 'http',
            'ws://example.test/socket'],
        ['WebSocket target maps https to wss', '/socket', 'https',
            'wss://example.test/socket'],
        ['WebSocket target keeps ws',          '/socket', 'ws',
            'ws://example.test/socket'],
        ['WebSocket target keeps wss',         '/socket', 'wss',
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
        $missing_scheme->url_for('/page'),
        'http://example.test/page',
        'a missing scheme defaults to http',
    );
    like(
        dies { _context('http', $resolver, scheme => 'ftp')->url_for('/page') },
        qr/\Aunsupported URL scheme/,
        'an unsupported scheme croaks instead of inventing a mapping',
    );
};

done_testing;
