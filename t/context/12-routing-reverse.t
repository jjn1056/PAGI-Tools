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

subtest 'Context reverse methods lazily delegate to the URL compatibility facade' => sub {
    ok(!exists $INC{'PAGI/Routing/URL.pm'},
        'loading Context does not eagerly load PAGI::Routing::URL');
    my $resolver = _resolver(
        route('/page/{id}' => sub { }, name => 'page'),
    );
    my $context = _context('http', $resolver);

    is($context->path_for('/page', { id => 7 }), '/page/7',
        'the compatibility path_for method preserves its result');
    ok(exists $INC{'PAGI/Routing/URL.pm'},
        'the first reverse operation loads the URL facade lazily');
    is($context->url_for('/page', { id => 7 }),
        'http://example.test/page/7',
        'the compatibility url_for method preserves its result');
};

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

# TASK 4 RUNTIME INTEGRATION OWNERSHIP
#
# The five Context subtests below deliberately supply selected routing frames.
# They verify only Context/Resolver behavior and do not claim that Compiler
# publishes these values. Task 4's mounted-application integration coverage
# retains ownership of the removed runtime observations:
#
# - a selected blog leaf publishes namespace /person/blog and captures
#   { person_id => 42, blog_id => 7 };
# - its unnamed catchall publishes the same namespace with captures
#   { person_id => 42, rest => 'missing/path' };
# - HTTP/WebSocket/SSE child scopes use /proxy/tenants/acme while their root
#   Resolver frame boundary remains /proxy;
# - the provider-backed account request completes with HTTP 200, and dispatch
#   plus reverse generation do not reinvoke the mount provider;
# - a separately compiled service child publishes frame root paths /proxy and
#   /proxy/service while its selected scope root is /proxy/service/spaces/blue;
# - the dynamic tenant child receives the decoded scope/root boundary
#   "/edge root/tenants/caf\x{e9} 50%" before reverse output encodes it once.

subtest 'Context resolves from a supplied mounted Router child frame' => sub {
    my $blogs = router(routes => [
        route('/' => sub { }, name => 'index'),
        route('/{blog_id}' => sub { }, name => 'show',
            constraints => { blog_id => qr/\A\d+\z/ }),
    ]);
    my $person = router(routes => [
        route('/{person_id}' => sub { }, name => 'show'),
        mount('/{person_id}/blog', app => $blogs, name => 'blog'),
    ]);
    my $opaque = sub { };
    my $routing = router(routes => [
        route('/' => sub { }, name => 'home'),
        mount('/person', app => $person, name => 'person'),
        mount('/staff', app => $person, name => 'staff'),
        mount('/legacy', app => $opaque, name => 'legacy'),
    ]);
    my $resolver = $routing->_resolver;
    # Supplied frame: Task 4 owns runtime namespace/capture publication,
    # including the selected leaf and unnamed catchall observations above.
    my $context = _context('http', $resolver,
        scheme => 'https',
        'pagi.routing' => {
            version => 1,
            frames => [_frame(
                $resolver,
                root_path => '',
                logical_namespace => '/person/blog',
                captures => { person_id => 42, blog_id => 7 },
                mounts => [
                    { path => '/person', name => 'person', desc => undef },
                    { path => '/{person_id}/blog', name => 'blog', desc => undef },
                ],
            )],
        },
    );

    is($context->path_for('show'), '/person/42/blog/7',
        'relative lookup inherits captures from the selected child placement');
    is($context->path_for('index'), '/person/42/blog/',
        'a sibling leaf resolves inside the mounted child namespace');
    is($context->path_for('../show'), '/person/42',
        'parent-relative lookup stays within the selected placement');
    is($context->path_for('./show'), '/person/42/blog/7',
        'current-directory lookup remains exact');
    is($context->path_for('x/../show'), '/person/42/blog/7',
        'interior navigation normalizes from the active namespace');
    is($context->path_for('show', { blog_id => 8 }),
        '/person/42/blog/8',
        'explicit values replace inherited child captures');
    is($context->path_for('/home'), '/',
        'absolute lookup reaches the root Router');
    is($context->path_for('../../home'), '/',
        'relative navigation can reach the root Router');
    is(
        $context->path_for('/staff/blog/show',
            { person_id => 42, blog_id => 9 }),
        '/staff/42/blog/9',
        'absolute lookup selects a second placement of the same child Router',
    );
    is(
        $context->url_for('show',
            query => { view => 'full' }, fragment => 'comments'),
        'https://example.test/person/42/blog/7?view=full#comments',
        'query and fragment rendering use the selected child boundary',
    );

    my @failures = (
        ['unknown relative', 'missing', qr/unknown route name 'missing'/],
        ['no overlap folding', 'person/show', qr/unknown route name 'person\/show'/],
        ['above root', '../../../home', qr/traverses above the Router root/],
        ['bare current namespace', '.', qr/resolves to a logical namespace/],
        ['bare parent namespace', '..', qr/resolves to a logical namespace/],
        ['repeated slash', 'show//child', qr/contains an empty logical segment/],
        ['trailing slash', 'show/', qr/contains an empty logical segment/],
        ['opaque named boundary', '/legacy', qr/logical namespace|unknown route/],
    );
    for my $failure (@failures) {
        my ($label, $reference, $message) = @$failure;
        like(dies { $context->path_for($reference) }, $message, $label);
    }
    like(
        dies { $context->path_for('/person/blog/show') },
        qr/missing path parameter 'person_id'/,
        'absolute Context references inherit no captures',
    );
    like(
        dies { $routing->path_for('/person/blog/show') },
        qr/missing path parameter 'person_id'/,
        'Router-object reverse calls inherit no request captures',
    );
    like(
        dies { $context->path_for('index', { extra => 1 }) },
        qr/unexpected path parameter 'extra'/,
        'explicit parameters not required by the target still fail',
    );
    like(
        dies { $context->path_for('show', { blog_id => 'bad' }) },
        qr/path parameter 'blog_id' failed constraint/,
        'constraints run after explicit values replace inherited captures',
    );
};

subtest 'Context prefers an exact leaf that shares a namespace address' => sub {
    my $api = route('/direct-api' => sub { }, name => 'api');
    my $api_child = router(routes => [
        route('/x' => sub { }, name => 'x'),
    ]);
    my $group_child = router(routes => [
        route('/x' => sub { }, name => 'x'),
    ]);
    my $resolver = _resolver(
        $api,
        mount('/nested-api', app => $api_child, name => 'api'),
        mount('/group', app => $group_child, name => 'group'),
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

subtest 'Context reverses supplied child-boundary frames across protocols' => sub {
    my $tenant = router(routes => [
        route('/show/{id}' => sub { }, name => 'show'),
        route('/sibling/{id}' => sub { }, name => 'sibling'),
        websocket('/socket/{room}' => sub { }, name => 'socket'),
        sse('/events/{channel}' => sub { }, name => 'events'),
    ]);
    my $routing = router(routes => [
        mount('/tenants/{tenant}', app => $tenant, name => 'tenant'),
    ]);
    my $resolver = $routing->_resolver;

    my @cases = (
        ['http', 'https', 'show', { id => 7 },
            '/proxy/tenants/acme/show/7?via=http',
            'https://public.example:8443/proxy/tenants/acme/show/7?via=http'],
        ['websocket', 'wss', 'socket', { room => 'lobby' },
            '/proxy/tenants/acme/socket/lobby?via=websocket',
            'wss://public.example:8443/proxy/tenants/acme/socket/lobby?via=websocket'],
        ['sse', 'https', 'events', { channel => 'news' },
            '/proxy/tenants/acme/events/news?via=sse',
            'https://public.example:8443/proxy/tenants/acme/events/news?via=sse'],
    );

    for my $case (@cases) {
        my ($type, $scheme, $name, $params, $path, $url) = @$case;
        # Supplied frame: Task 4 owns cross-protocol scope/root publication.
        my $context = _context($type, $resolver,
            root_path => '/proxy/tenants/acme',
            scheme => $scheme,
            headers => [['host', 'public.example:8443']],
            'pagi.routing' => {
                version => 1,
                frames => [_frame(
                    $resolver,
                    root_path => '/proxy',
                    logical_namespace => '/tenant',
                    captures => { tenant => 'acme' },
                    mounts => [{
                        path => '/tenants/{tenant}',
                        name => 'tenant',
                        desc => undef,
                    }],
                )],
            },
        );

        is($context->path_for($name, $params, { via => $type }), $path,
            "$type relative lookup uses the mounted Router boundary");
        is($context->url_for($name, $params, { via => $type }), $url,
            "$type URL lookup preserves the target protocol kind");
        is(
            $context->path_for('/tenant/sibling',
                { tenant => 'acme', id => 8 }, { via => $type }),
            "/proxy/tenants/acme/sibling/8?via=$type",
            "$type absolute lookup reaches a sibling through the root resolver",
        );
    }
};

subtest 'Context reverse generation inherits captures and applies each composed predicate once' => sub {
    $Local::ContextReverseProvider::CALLS = 0;
    my $explicit_calls = 0;
    my $account = router(routes => [
        route('/items/{item}' => sub { },
            name => 'show',
            constraints => {
                item => sub {
                    ++$explicit_calls;
                    return $_[0] eq 'good';
                },
            },
        ),
    ]);
    my $routing = router(routes => [
        mount('/accounts/{account:&Local::ContextReverseProvider::Account}',
            app => $account, name => 'account',
        ),
    ]);
    my $resolver = $routing->_resolver;
    # Supplied frame: Task 4 owns provider-backed dispatch and HTTP completion.
    my $context = _context('http', $resolver,
        root_path => '/edge/accounts/acme',
        scheme    => 'https',
        headers   => [['host', 'public.example']],
        'pagi.routing' => {
            version => 1,
            frames => [_frame(
                $resolver,
                root_path => '/edge',
                logical_namespace => '/account',
                captures => { account => 'acme' },
                mounts => [{
                    path => '/accounts/{account}',
                    name => 'account',
                    desc => undef,
                }],
            )],
        },
    );

    $explicit_calls = 0;
    my $path = $context->path_for('show', { item => 'good' });
    my $after_path = $explicit_calls;
    my $url = $context->url_for(
        'show', { item => 'good' }, { q => 'two words' }, 'details',
    );
    my $after_url = $explicit_calls;
    my $invalid = dies { $context->url_for('show', { item => 'bad' }) };

    is($path, '/edge/accounts/acme/items/good',
        'relative path_for inherits the valid mount capture');
    is($url,
        'https://public.example/edge/accounts/acme/items/good?q=two%20words#details',
        'url_for validates the leaf and appends query and fragment');
    is([$after_path, $after_url, $explicit_calls],
        [1, 2, 3],
        'each successful or failed render applies the explicit leaf predicate exactly once');
    like($invalid, qr/path parameter 'item' failed constraint/,
        'url_for rejects an invalid explicit leaf value');
    is($Local::ContextReverseProvider::CALLS, 1,
        'Context reverse generation does not reinvoke the mount provider');
};

subtest 'Context uses a supplied root Resolver and selected namespace' => sub {
    my $space = router(routes => [
        route('/items/{id}' => sub { }, name => 'item'),
        route('/siblings/{id}' => sub { }, name => 'sibling'),
    ]);
    my $child = router(routes => [
        mount('/spaces/{space}', app => $space, name => 'space'),
    ]);
    my $parent = router(routes => [
        mount('/service', app => $child, name => 'service'),
    ]);
    my $resolver = $parent->_resolver;
    # Supplied frame: Task 4 owns the compiled parent/child frame stack.
    my $context = _context('http', $resolver,
        root_path => '/proxy/service/spaces/blue',
        scheme    => 'https',
        headers   => [['host', 'public.example']],
        'pagi.routing' => {
            version => 1,
            frames => [_frame(
                $resolver,
                root_path => '/proxy',
                logical_namespace => '/service/space',
                captures => { space => 'blue' },
                mounts => [
                    { path => '/service', name => 'service', desc => undef },
                    { path => '/spaces/{space}', name => 'space', desc => undef },
                ],
            )],
        },
    );

    is(
        $context->path_for('item', { id => 9 }, { q => 'two words' }),
        '/proxy/service/spaces/blue/items/9?q=two%20words',
        'relative lookup starts at the selected mounted child namespace',
    );
    is(
        $context->url_for('/service/space/sibling',
            { space => 'blue', id => 10 }, { q => 'two words' }),
        'https://public.example/proxy/service/spaces/blue/siblings/10?q=two%20words',
        'absolute lookup keeps the root resolver across the child boundary',
    );
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

subtest 'Context encodes supplied mounted captures exactly once' => sub {
    my $child = router(routes => [
        route('/items/{id}' => sub { }, name => 'item'),
    ]);
    my $parent = router(routes => [
        mount('/tenants/{tenant}', app => $child),
    ]);
    my $resolver = $parent->_resolver;
    # Supplied frame: Task 4 owns decoded child-scope boundary publication.
    my $context = _context('http', $resolver,
        root_path => "/edge root/tenants/caf\x{e9} 50%",
        scheme    => 'https',
        headers   => [['host', 'public.example']],
        'pagi.routing' => {
            version => 1,
            frames => [_frame(
                $resolver,
                root_path => '/edge root/',
                logical_namespace => '/',
                captures => { tenant => "caf\x{e9} 50%" },
                mounts => [{
                    path => '/tenants/{tenant}',
                    name => undef,
                    desc => undef,
                }],
            )],
        },
    );

    is(
        $context->path_for('item',
            { id => 'a b%' }, { q => "caf\x{e9} %" }),
        '/edge%20root/tenants/caf%C3%A9%2050%25/items/a%20b%25?q=caf%C3%A9%20%25',
        'path_for emits the decoded mounted prefix and generated values once',
    );
    is(
        $context->url_for('item',
            { id => 'a b%' }, { q => "caf\x{e9} %" }),
        'https://public.example/edge%20root/tenants/caf%C3%A9%2050%25/items/a%20b%25?q=caf%C3%A9%20%25',
        'url_for uses the same encoded mounted child boundary',
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
