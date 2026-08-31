#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test2::V0;
use Future;
use Types::Standard qw(Int);

use lib 'lib';
use PAGI::Request;
use PAGI::Response::Text ();
use PAGI::WebSocket;
use PAGI::SSE;
use PAGI::Middleware::ReverseProxy;
use PAGI::Middleware::TrustedHosts;
use PAGI::Routing qw(mount route router sse websocket);
use PAGI::Routing::Resolver;
use PAGI::Routing::URL qw(url path_for url_for);

{
    package Local::URL::NoDefault;
    PAGI::Routing::URL->import;
}

{
    package Local::URL::Named;
    PAGI::Routing::URL->import(qw(url path_for url_for));
}

{
    package Local::URL::All;
    PAGI::Routing::URL->import(':ALL');
}

{
    package Local::URL::ScopeBearer;
    sub new { return bless { scope => $_[1] }, $_[0] }
    sub scope { return $_[0]{scope} }
}

{
    package Local::URL::BadScopeBearer;
    sub new { return bless {}, $_[0] }
    sub scope { return [] }
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

sub _scope {
    my ($type, $resolver, %changes) = @_;
    return {
        type           => $type,
        method         => 'GET',
        path           => '/',
        raw_path       => '/',
        headers        => [['host', 'example.test']],
        scheme         => 'http',
        root_path      => '',
        'pagi.routing' => {
            version => 1,
            frames  => [_frame($resolver)],
        },
        %changes,
    };
}

sub _run_http {
    my ($app, %changes) = @_;
    my @events;
    my $scope = {
        type        => 'http',
        method      => 'GET',
        path        => '/',
        raw_path    => '/',
        root_path   => '',
        path_params => {},
        headers     => [['host', 'example.test']],
        scheme      => 'http',
        %changes,
    };
    my $receive = sub {
        return Future->done({ type => 'http.request', body => '', more => 0 });
    };
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    $app->($scope, $receive, $send)->get;
    return \@events;
}

sub _response_body {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
}

subtest 'exports are opt-in and uppercase-only' => sub {
    ok(!Local::URL::NoDefault->can('url'), 'url is not exported by default');
    ok(!Local::URL::NoDefault->can('path_for'),
        'path_for is not exported by default');
    ok(!Local::URL::NoDefault->can('url_for'),
        'url_for is not exported by default');

    ok(Local::URL::Named->can('url'), 'url is available by name');
    ok(Local::URL::Named->can('path_for'), 'path_for is available by name');
    ok(Local::URL::Named->can('url_for'), 'url_for is available by name');
    ok(Local::URL::All->can('url'), 'uppercase :ALL exports url');
    ok(Local::URL::All->can('path_for'), 'uppercase :ALL exports path_for');
    ok(Local::URL::All->can('url_for'), 'uppercase :ALL exports url_for');

    my $lowercase_error;
    {
        local $SIG{__WARN__} = sub { };
        $lowercase_error = dies { PAGI::Routing::URL->import(':all') };
    }
    like($lowercase_error, qr/"?:all"? is not defined|Can't continue/i,
        'lowercase :all is rejected');
};

subtest 'object and functional forms keep one-source construction strict' => sub {
    my $resolver = _resolver(route('/page/{id}' => sub { }, name => 'page'));
    my $scope = _scope('http', $resolver);
    my @keys_before = sort keys %$scope;

    my $first = url($scope);
    my $second = PAGI::Routing::URL->new(
        Local::URL::ScopeBearer->new($scope),
    );
    isa_ok($first, ['PAGI::Routing::URL']);
    isa_ok($second, ['PAGI::Routing::URL']);
    is($first->path_for('/page', { id => 7 }), '/page/7',
        'object path_for renders a string');
    is(path_for($scope, '/page', { id => 7 }), '/page/7',
        'functional path_for renders the same string');
    is(url_for($scope, '/page', { id => 7 }),
        'http://example.test/page/7',
        'functional url_for renders an absolute string');
    is(path_for($first, '/page', { id => 7 }), '/page/7',
        'the shared path_for sub recognizes an existing facade');
    is($first->path_for('/page', { id => 7 }),
        $second->path_for('/page', { id => 7 }),
        'separate facade instances guarantee equivalent output');
    is([sort keys %$scope], \@keys_before,
        'construction and use add no helper or cache key to scope');

    like(dies { PAGI::Routing::URL->new() }, qr/exactly one.*scope/i,
        'constructor rejects a missing source');
    like(dies { PAGI::Routing::URL->new($scope, $scope) },
        qr/exactly one.*scope/i, 'constructor rejects extra sources');
    like(dies { url($scope, '/page') }, qr/exactly one.*scope/i,
        'url never changes return type by accepting a route reference');
    like(dies { url('PAGI::Request') }, qr/unblessed scope hashref.*scope\(\)/i,
        'package strings are not sources');
    like(dies { url(bless({}, 'Local::URL::NoScope')) },
        qr/unblessed scope hashref.*scope\(\)/i,
        'objects without scope are not sources');
    like(dies { url(Local::URL::BadScopeBearer->new) },
        qr/unblessed scope hashref.*scope\(\)/i,
        'malformed scope returns are rejected');
};

subtest 'raw and protocol-object sources resolve their exact scopes' => sub {
    my $resolver = _resolver(route('/page' => sub { }, name => 'page'));
    my $receive = sub { };
    my $send = sub { };

    my $raw = _scope('http', $resolver);
    is(url($raw)->path_for('/page'), '/page', 'raw scope source works');

    my $request_scope = _scope('http', $resolver);
    my $request = PAGI::Request->new($request_scope, $receive);
    is(path_for($request, '/page'), '/page', 'strict Request source works');

    my $websocket_scope = _scope('websocket', $resolver, scheme => 'wss');
    my $websocket = PAGI::WebSocket->new($websocket_scope, $receive, $send);
    my @websocket_keys = sort keys %$websocket_scope;
    is(url_for($websocket, '/page'), 'https://example.test/page',
        'WebSocket source supplies its exact scope');
    is([sort keys %$websocket_scope], \@websocket_keys,
        'URL use adds no key beside the protocol object cache');

    my $sse_scope = _scope('sse', $resolver, scheme => 'https');
    my $sse_object = PAGI::SSE->new($sse_scope, $receive, $send);
    my @sse_keys = sort keys %$sse_scope;
    is(url_for($sse_object, '/page'), 'https://example.test/page',
        'SSE source supplies its exact scope');
    is([sort keys %$sse_scope], \@sse_keys,
        'URL use adds no key beside the SSE object cache');
};

subtest 'direct protocol sources preserve a mounted child boundary' => sub {
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
    my $receive = sub { };
    my $send = sub { };
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
        my ($type, $scheme, $name, $params, $path, $absolute) = @{$case};
        my $scope = _scope($type, $resolver,
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
                        path => '/tenants/{tenant}', name => 'tenant', desc => undef,
                    }],
                )],
            },
        );
        my $source = $type eq 'http'
            ? PAGI::Request->new($scope, $receive)
            : $type eq 'websocket'
                ? PAGI::WebSocket->new($scope, $receive, $send)
                : PAGI::SSE->new($scope, $receive, $send);

        is(path_for($source, $name, $params, { via => $type }), $path,
            "$type path_for retains the mounted child boundary");
        is(url_for($source, $name, $params, { via => $type }), $absolute,
            "$type url_for keeps the target protocol mapping");
        is(path_for($source, '/tenant/sibling',
            { tenant => 'acme', id => 8 }, { via => $type }),
            "/proxy/tenants/acme/sibling/8?via=$type",
            "$type absolute route reaches the mounted sibling");
    }
};

subtest 'operations read the selected frame at operation time' => sub {
    my $parent = _resolver(route('/parent/{id}' => sub { }, name => 'show'));
    my $child = _resolver(route('/child/{id}' => sub { }, name => 'show'));
    my $scope = _scope('http', $parent);
    my $urls = url($scope);

    $scope->{'pagi.routing'}{frames} = [
        _frame($parent),
        _frame($child, captures => { id => 9 }),
    ];
    is($urls->path_for('show'), '/child/9',
        'a facade built before leaf selection sees the later last frame');
};

subtest 'absolute and relative references preserve traversal and capture rules' => sub {
    my $blogs = router(routes => [
        route('/' => sub { }, name => 'index'),
        route('/{blog_id}' => sub { }, name => 'show',
            constraints => { blog_id => qr/\A\d+\z/ }),
    ]);
    my $person = router(routes => [
        route('/{person_id}' => sub { }, name => 'show'),
        mount('/{person_id}/blog', app => $blogs, name => 'blog'),
    ]);
    my $routing = router(routes => [
        route('/' => sub { }, name => 'home'),
        mount('/person', app => $person, name => 'person'),
        mount('/staff', app => $person, name => 'staff'),
    ]);
    my $resolver = $routing->_resolver;
    my $scope = _scope('http', $resolver,
        scheme => 'https',
        'pagi.routing' => {
            version => 1,
            frames => [_frame(
                $resolver,
                logical_namespace => '/person/blog',
                captures => { person_id => 42, blog_id => 7 },
                mounts => [
                    { path => '/person', name => 'person', desc => undef },
                    { path => '/{person_id}/blog', name => 'blog', desc => undef },
                ],
            )],
        },
    );
    my $urls = url($scope);

    is($urls->path_for('show'), '/person/42/blog/7',
        'relative references inherit required captures');
    is($urls->path_for('index'), '/person/42/blog/',
        'relative sibling stays in the containing namespace');
    is($urls->path_for('../show'), '/person/42',
        'parent traversal resolves exactly');
    is($urls->path_for('./show'), '/person/42/blog/7',
        'current traversal resolves exactly');
    is($urls->path_for('x/../show'), '/person/42/blog/7',
        'interior traversal resolves left to right');
    is($urls->path_for('show', { blog_id => 8 }), '/person/42/blog/8',
        'explicit params override inherited captures');
    is($urls->path_for('/home'), '/',
        'absolute reference begins at the resolver root');
    is($urls->path_for('../../home'), '/',
        'relative traversal can reach the resolver root');
    is($urls->path_for('/staff/blog/show',
        { person_id => 43, blog_id => 9 }), '/staff/43/blog/9',
        'absolute reference selects a second nested placement');
    is($urls->url_for('show', query => { view => 'full' },
        fragment => 'comments'),
        'https://example.test/person/42/blog/7?view=full#comments',
        'relative URL preserves query and fragment rendering');

    my @bad_references = (
        ['missing', qr/unknown route name 'missing'/],
        ['person/show', qr/unknown route name 'person\/show'/],
        ['../../../home', qr/traverses above the Router root/],
        ['.', qr/resolves to a logical namespace/],
        ['..', qr/resolves to a logical namespace/],
        ['show//child', qr/contains an empty logical segment/],
        ['show/', qr/contains an empty logical segment/],
        ['show/.', qr/resolves to a logical namespace/],
        ['show/child/..', qr/resolves to a logical namespace/],
    );
    for my $case (@bad_references) {
        like(dies { $urls->path_for($case->[0]) }, $case->[1],
            "invalid reference $case->[0] is rejected");
    }
    like(dies { $urls->path_for('/person/blog/show') },
        qr/missing path parameter 'person_id'/,
        'absolute references inherit no captures');
    like(dies { $urls->path_for('index', { extra => 1 }) },
        qr/unexpected path parameter 'extra'/,
        'unneeded explicit params remain errors');
    like(dies { $urls->path_for('show', { blog_id => 'bad' }) },
        qr/path parameter 'blog_id' failed constraint/,
        'overridden captures still satisfy target constraints');
};

subtest 'an exact leaf wins at a shared namespace address' => sub {
    my $resolver = _resolver(
        route('/direct-api' => sub { }, name => 'api'),
        mount('/nested-api', app => router(routes => [
            route('/x' => sub { }, name => 'x'),
        ]), name => 'api'),
        mount('/group', app => router(routes => [
            route('/x' => sub { }, name => 'x'),
        ]), name => 'group'),
    );
    my $root = url(_scope('http', $resolver));
    my $nested = url(_scope('http', $resolver,
        'pagi.routing' => {
            version => 1,
            frames => [_frame($resolver, logical_namespace => '/api')],
        },
    ));

    is($root->path_for('/api'), '/direct-api',
        'absolute lookup selects the exact leaf');
    is($root->path_for('api'), '/direct-api',
        'root-relative lookup selects the exact leaf');
    is($nested->path_for('../api'), '/direct-api',
        'parent-relative lookup selects the exact leaf');
    is($root->path_for('/api/x'), '/nested-api/x',
        'absolute descendant remains available');
    is($nested->path_for('x'), '/nested-api/x',
        'relative descendant remains available');
    like(dies { $root->path_for('/group') },
        qr/resolves to a logical namespace, not a route/,
        'namespace without an exact leaf is rejected');
};

subtest 'capture inheritance selects target keys only' => sub {
    my $resolver = _resolver(
        route('/target/{required}' => sub { }, name => 'target'),
    );
    my $urls = url(_scope('http', $resolver,
        'pagi.routing' => {
            version => 1,
            frames => [_frame($resolver, captures => {
                required => 'kept',
                query    => 'must-not-appear',
                fragment => 'must-not-appear',
                unused   => 'must-not-be-extra',
            })],
        },
    ));
    is($urls->path_for('target'), '/target/kept',
        'only required path values are inherited');
    is($urls->path_for('target', { required => 'explicit' }),
        '/target/explicit', 'explicit values replace inherited values');
};

subtest 'compact and named params-query-fragment forms are equivalent' => sub {
    my $resolver = _resolver(
        route('/items/{id}' => sub { }, name => 'show'),
        route('/items' => sub { }, name => 'index'),
    );
    my $scope = _scope('http', $resolver, scheme => 'https', root_path => '/edge');
    my $urls = url($scope);
    my @cases = (
        ['defaults', ['/index'], '/items'],
        ['compact params', ['/show', { id => 7 }], '/items/7'],
        ['compact query', ['/show', { id => 7 }, { q => 'two words' }],
            '/items/7?q=two%20words'],
        ['compact fragment', ['/show', { id => 7 }, { q => 'two words' },
            'details'], '/items/7?q=two%20words#details'],
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
        ['compact undef fragment', ['/show', { id => 7 }, {}, undef], '/items/7'],
        ['named undef fragment', ['/show', fragment => undef,
            params => { id => 7 }], '/items/7'],
        ['compact empty fragment', ['/show', { id => 7 }, {}, ''], '/items/7#'],
        ['named empty fragment', ['/show', params => { id => 7 }, fragment => ''],
            '/items/7#'],
    );
    for my $case (@cases) {
        is($urls->path_for(@{$case->[1]}), "/edge$case->[2]",
            "path_for $case->[0]");
        is($urls->url_for(@{$case->[1]}),
            "https://example.test/edge$case->[2]", "url_for $case->[0]");
    }

    my $object = bless {}, 'Local::URL::ArgumentObject';
    my $scalar = 'value';
    my @failures = (
        ['too many compact', ['/show', {}, {}, 'section', 'extra'],
            'compact form accepts at most params, query, and fragment'],
        ['compact query array', ['/show', {}, []],
            'compact query must be a hashref'],
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
        ['named fragment ref', ['/show', fragment => \$scalar],
            'named fragment must be a plain scalar or undef'],
        ['mixed forms', ['/show', { id => 8 }, query => { view => 'full' }],
            'compact and named reverse-routing forms cannot be mixed'],
    );
    for my $operation (qw(path_for url_for)) {
        for my $failure (@failures) {
            like(dies { $urls->$operation(@{$failure->[1]}) },
                qr/\A\Q$operation reverse-routing $failure->[2]\E/,
                "$operation $failure->[0]");
        }
    }
};

subtest 'root_path and nested Mount boundaries are applied exactly once' => sub {
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
    my $urls = url(_scope('http', $resolver,
        root_path => '/proxy/service/spaces/blue',
        scheme => 'https',
        headers => [['host', 'public.example']],
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
    ));

    is($urls->path_for('item', { id => 9 }, { q => 'two words' }),
        '/proxy/service/spaces/blue/items/9?q=two%20words',
        'relative nested path uses the compiled frame boundary once');
    is($urls->url_for('/service/space/sibling',
        { space => 'blue', id => 10 }),
        'https://public.example/proxy/service/spaces/blue/siblings/10',
        'absolute nested URL keeps the root resolver and boundary');

    my $plain = _resolver(
        route('/items/{id}' => sub { }, name => 'item'),
        route('/' => sub { }, name => 'root'),
        route('//double/' => sub { }, name => 'double'),
    );
    is(url(_scope('http', $plain, root_path => '/proxy/'))
        ->path_for('/item', { id => 'one' }), '/proxy/items/one',
        'one boundary slash is retained');
    is(url(_scope('http', $plain, root_path => '/'))
        ->path_for('/item', { id => 'one' }), '/items/one',
        'root-only prefix does not duplicate a slash');
    is(url(_scope('http', $plain, root_path => '/proxy/'))
        ->path_for('/root'), '/proxy/',
        'application root keeps one terminal slash');
    is(url(_scope('http', $plain, root_path => '/proxy/'))
        ->path_for('/double'), '/proxy//double/',
        'route-internal slashes are not normalized');
};

subtest 'decoded boundaries and generated suffixes encode exactly once' => sub {
    my $resolver = _resolver(route('/items/{id}' => sub { }, name => 'item'));
    my $urls = url(_scope('http', $resolver,
        root_path => "/proxy space/50%/caf\x{e9}/",
        scheme => 'https',
        headers => [['host', 'public.example']],
    ));
    my $path = '/proxy%20space/50%25/caf%C3%A9/items/a%20b%25'
        . '?q=caf%C3%A9%20%25#two%20words';
    is($urls->path_for('/item', { id => 'a b%' },
        { q => "caf\x{e9} %" }, 'two words'), $path,
        'path_for encodes root, params, query, and fragment once');
    is($urls->url_for('/item', { id => 'a b%' },
        { q => "caf\x{e9} %" }, 'two words'), "https://public.example$path",
        'url_for uses the same single-encoded rendered path');
};

subtest 'Type::Tiny, regex, coderef, and protocol constraints remain active' => sub {
    my $coderef_calls = 0;
    my $routing = router(routes => [
        route('/typed/{id}' => sub { }, name => 'typed',
            constraints => { id => Int }),
        route('/regex/{word}' => sub { }, name => 'regex',
            constraints => { word => qr/[a-z]+/ }),
        route('/code/{value}' => sub { }, name => 'code',
            constraints => { value => sub {
                ++$coderef_calls;
                return $_[0] eq 'ok';
            } }),
        websocket('/socket/{id:-?\d+}' => sub { }, name => 'socket'),
        sse('/events/{name:[a-z]+}' => sub { }, name => 'events'),
    ]);
    my $urls = url(_scope('http', $routing->_resolver));

    is($urls->path_for('/typed', { id => -7 }), '/typed/-7',
        'Type::Tiny Int accepts a signed integer');
    is($urls->path_for('/regex', { word => 'letters' }), '/regex/letters',
        'explicit regex accepts a complete value');
    is($urls->path_for('/code', { value => 'ok' }), '/code/ok',
        'coderef constraint accepts a valid value');
    is($coderef_calls, 1, 'coderef runs exactly once for one render');
    is($urls->path_for('/socket', { id => -1 }), '/socket/-1',
        'WebSocket inline regex remains active');
    is($urls->path_for('/events', { name => 'news' }), '/events/news',
        'SSE inline regex remains active');
    like(dies { $urls->path_for('/typed', { id => 'x' }) },
        qr/path parameter 'id' failed constraint/, 'Type::Tiny rejects bad input');
    like(dies { $urls->path_for('/regex', { word => '123' }) },
        qr/path parameter 'word' failed constraint/, 'regex rejects bad input');
    like(dies { $urls->path_for('/code', { value => 'bad' }) },
        qr/path parameter 'value' failed constraint/, 'coderef rejects bad input');
    is($coderef_calls, 2, 'failed coderef render also runs exactly once');
};

subtest 'authority validation and target kinds preserve HTTP HTTPS WS WSS mappings' => sub {
    my $resolver = _resolver(
        route('/page' => sub { }, name => 'page'),
        websocket('/socket' => sub { }, name => 'socket'),
        sse('/events' => sub { }, name => 'events'),
    );
    my @cases = (
        ['/page', 'http', 'http://example.test/page'],
        ['/page', 'https', 'https://example.test/page'],
        ['/page', 'ws', 'http://example.test/page'],
        ['/page', 'wss', 'https://example.test/page'],
        ['/events', 'ws', 'http://example.test/events'],
        ['/events', 'wss', 'https://example.test/events'],
        ['/socket', 'http', 'ws://example.test/socket'],
        ['/socket', 'https', 'wss://example.test/socket'],
        ['/socket', 'ws', 'ws://example.test/socket'],
        ['/socket', 'wss', 'wss://example.test/socket'],
    );
    for my $case (@cases) {
        is(url_for(_scope('http', $resolver, scheme => $case->[1]), $case->[0]),
            $case->[2], "$case->[1] maps $case->[0] by target kind");
    }

    is(url_for(_scope('http', $resolver,
        scheme => 'https', headers => [], server => ['fallback.example', 9443]),
        '/page'), 'https://fallback.example:9443/page',
        'server supplies authority only when Host is absent');
    like(dies { url_for(_scope('http', $resolver,
        headers => [['host', 'bad host']],
        server => ['fallback.example', 80]), '/page') },
        qr/\Ainvalid authority/, 'malformed Host does not fall back to server');
    like(dies { url_for(_scope('http', $resolver,
        headers => [['host', 'one.example'], ['Host', 'two.example']],
        server => ['fallback.example', 80]), '/page') },
        qr/\AHost header must occur at most once/,
        'duplicate Host does not fall back to server');
    like(dies { url_for(_scope('http', $resolver,
        headers => [], server => undef), '/page') },
        qr/\Ascope server cannot provide an authority/,
        'missing authority remains an error');
    like(dies { url_for(_scope('http', $resolver, scheme => 'ftp'), '/page') },
        qr/\Aunsupported URL scheme/, 'unsupported scheme remains an error');
};

subtest 'ReverseProxy normalizes authority before TrustedHosts and url_for' => sub {
    my $routing = router(routes => [
        route('/external' => sub {
            my ($request) = @_;
            return PAGI::Response::Text->new(url_for($request, '/external'));
        }, name => 'external'),
    ]);
    my $proxy = PAGI::Middleware::ReverseProxy->new(
        trusted_proxies => ['127.0.0.1'],
    );
    my $trusted = PAGI::Middleware::TrustedHosts->new(
        hosts => ['public.example:8443'],
    );
    my $app = $proxy->wrap($trusted->wrap($routing->to_app));
    my $events = _run_http($app,
        path => '/external', raw_path => '/external',
        client => ['127.0.0.1', 12345],
        server => ['internal.example', 5000],
        headers => [
            ['host', 'internal.example'],
            ['x-forwarded-proto', 'https'],
            ['x-forwarded-host', 'public.example:8443'],
        ],
    );

    is($events->[0]{status}, 200,
        'TrustedHosts accepts the authority normalized by ReverseProxy');
    is(_response_body($events), 'https://public.example:8443/external',
        'url_for uses normalized scheme and validated external authority');
};

subtest 'missing malformed and versioned routing frames fail at operation time' => sub {
    my $resolver = _resolver(route('/page' => sub { }, name => 'page'));
    my @cases = (
        ['missing container', undef],
        ['missing version', { frames => [_frame($resolver)] }],
        ['foreign version', { version => 2, frames => [_frame($resolver)] }],
        ['version reference', { version => \1, frames => [_frame($resolver)] }],
        ['frames not array', { version => 1, frames => {} }],
        ['empty frames', { version => 1, frames => [] }],
        ['non-hash frame', { version => 1, frames => ['bad'] }],
        ['missing resolver', { version => 1, frames => [{
            logical_namespace => '/', captures => {}, mounts => [], match => undef,
        }] }],
        ['malformed mounts', { version => 1, frames => [_frame(
            $resolver, mounts => {},
        )] }],
        ['malformed match', { version => 1, frames => [_frame(
            $resolver, match => [],
        )] }],
        ['malformed root_path', { version => 1, frames => [_frame(
            $resolver, root_path => [],
        )] }],
        ['missing namespace', { version => 1, frames => [{
            resolver => $resolver, captures => {}, mounts => [], match => undef,
        }] }],
        ['relative namespace', { version => 1, frames => [_frame(
            $resolver, logical_namespace => 'person',
        )] }],
        ['trailing namespace slash', { version => 1, frames => [_frame(
            $resolver, logical_namespace => '/person/',
        )] }],
        ['navigation namespace', { version => 1, frames => [_frame(
            $resolver, logical_namespace => '/person/../blog',
        )] }],
        ['missing captures', { version => 1, frames => [{
            resolver => $resolver, logical_namespace => '/',
            mounts => [], match => undef,
        }] }],
        ['malformed captures', { version => 1, frames => [_frame(
            $resolver, captures => [],
        )] }],
        ['invalid ancestor before valid leaf', { version => 1, frames => [
            _frame($resolver, captures => []), _frame($resolver),
        ] }],
    );

    for my $case (@cases) {
        my $scope = {
            type => 'http', headers => [['host', 'example.test']], scheme => 'http',
        };
        $scope->{'pagi.routing'} = $case->[1] if defined $case->[1];
        my $urls = url($scope);
        like(dies { $urls->path_for('/page') },
            qr/\Apath_for requires a PAGI::Routing resolver in scope/,
            "$case->[0] is rejected by path_for");
        like(dies { $urls->url_for('/page') },
            qr/\Aurl_for requires a PAGI::Routing resolver in scope/,
            "$case->[0] is rejected by url_for");
    }
};

subtest 'real compiled frames follow the active Router placement' => sub {
    my @seen;
    my $child = router(routes => [
        route('/{person_id}' => sub {
            my ($request) = @_;
            my $urls = url($request);
            my $frame = $request->scope->{'pagi.routing'}{frames}[-1];
            push @seen, {
                path => $urls->path_for('show'),
                logical_namespace => $frame->{logical_namespace},
                captures => { %{$frame->{captures}} },
            };
            return PAGI::Response::Text->new('person');
        }, name => 'show'),
    ]);
    my $app = router(routes => [
        mount('/authors', app => $child, name => 'authors'),
        mount('/editors', app => $child, name => 'editors'),
    ])->to_app;

    is(_response_body(_run_http($app,
        path => '/authors/42', raw_path => '/authors/42')), 'person',
        'first compiled Mount completes');
    is(_response_body(_run_http($app,
        path => '/editors/42', raw_path => '/editors/42')), 'person',
        'second compiled Mount completes');
    is(\@seen, [
        {
            path => '/authors/42',
            logical_namespace => '/authors',
            captures => { person_id => 42 },
        },
        {
            path => '/editors/42',
            logical_namespace => '/editors',
            captures => { person_id => 42 },
        },
    ], 'URL reads real compiled leaf frames for both placements');
};

done_testing;
