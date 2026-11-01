use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Type::Tiny;
use Types::Standard qw(Int Num Str Bool);
use PAGI::Compose qw(compose);
use PAGI::Response qw(response);
use PAGI::Routing qw(middleware mount route router sse websocket);
use PAGI::Middleware::Requires ();
use PAGI::Routing::OpenAPI qw(openapi openapi_document);
use PAGI::Test::Client;

# An OpenAPI 3.1 document from an application's route_table: one subtest per
# rule of the spec (docs/superpowers/specs/2026-10-15-openapi-generator-design.md).

my $ok = sub { response('Text', 'ok') };
my %info = (title => 'T', version => '1');
my @bearer = (security_scheme => [bearer => { type => 'http', scheme => 'bearer' }]);
sub doc_of { my ($routes, @options) = @_; return openapi_document(compose(routes => $routes), %info, @options) }
sub protected { return (middleware => [middleware('Requires', @_)]) }

subtest 'the frame of the document' => sub {
    my $doc = doc_of([route('/a' => $ok)], description => 'An API');
    is($doc->{openapi}, '3.1.0', 'OpenAPI 3.1.0');
    is($doc->{info}, { title => 'T', version => '1', description => 'An API' }, 'info from the options');
    ok(!exists $doc->{components}, 'no components unless asked for');
    require JSON::MaybeXS;
    is(JSON::MaybeXS->new(canonical => 1)->encode(openapi_document(compose(routes => []), title => 'T', version => 1)->{info}),
        '{"title":"T","version":"1"}', 'a numeric version is still a string, as OpenAPI requires');
};

subtest 'kinds' => sub {
    my $doc = doc_of([
        route('/a' => $ok),
        sse('/events' => sub { }),
        sse('/typed' => sub { }, meta => { openapi => { responses => { 200 => { description => 'mine' } } } }),
        websocket('/ws' => sub { }),
        mount('/legacy', app => sub { }),
    ]);
    is([sort keys %{ $doc->{paths} }], ['/a', '/events', '/typed'], 'websocket and mount entries are left out');
    is($doc->{paths}{'/events'}{get}{responses},
        { 200 => { description => 'An event stream', content => { 'text/event-stream' => { schema => { type => 'string' } } } } },
        'an SSE route is a GET answering text/event-stream');
    is($doc->{paths}{'/typed'}{get}{responses}, { 200 => { description => 'mine' } }, 'unless its meta says otherwise');
    my $other = doc_of([sse('/more' => sub { })]);
    $doc->{paths}{'/events'}{get}{responses}{200}{description} = 'changed';
    is($other->{paths}{'/more'}{get}{responses}{200}{description}, 'An event stream',
        "each operation's default is its own: changing one document's leaves another's");
};

subtest 'methods' => sub {
    my $doc = doc_of([
        route('/g' => $ok),
        route('/h' => $ok, methods => ['HEAD']),
        route('/s' => $ok, methods => '*'),
        route('/q' => $ok, methods => ['QUERY', 'POST']),
    ]);
    is([keys %{ $doc->{paths}{'/g'} }], ['get'], 'HEAD is folded into GET');
    is([keys %{ $doc->{paths}{'/h'} }], ['head'], 'and kept for a HEAD-only route');
    is([keys %{ $doc->{paths}{'/s'} }], ['get'], 'an unrestricted route is a GET');
    is([keys %{ $doc->{paths}{'/q'} }], ['post'], 'a method outside OpenAPI 3.1 is left out');
};

subtest 'collisions' => sub {
    like(dies { doc_of([route('/i/{id}' => $ok), route('/i/{slug}' => $ok)]) },
        qr{PAGI::Routing::OpenAPI: /i/\{slug\} and /i/\{id\} are the same OpenAPI path},
        'templates differing only in parameter names');
    like(dies { doc_of([route('/i/{id:\d+}' => $ok), route('/i/{id:[a-z]+}' => $ok)]) },
        qr{PAGI::Routing::OpenAPI: two routes for GET /i/\{id\}}, 'one method and template twice');
    like(dies { doc_of([map { route($_ => $ok, meta => { openapi => { operationId => 'same' } }) } '/a', '/b']) },
        qr/PAGI::Routing::OpenAPI: operationId same is not unique/, 'a duplicate made by meta');
};

subtest 'operationIds' => sub {
    my $doc = doc_of([
        mount('/a', name => 'a', routes => [route('/show' => $ok, name => 'show')]),
        mount('/b', name => 'b', routes => [route('/show' => $ok, name => 'show')]),
        mount('/api', name => 'v1', routes => [route('/items/{id}' => $ok, name => 'item')]),
        route('/' => $ok),
        route('/health' => $ok),
        route('/notes/{id}' => $ok, methods => ['DELETE']),
        route('/mine' => $ok, meta => { openapi => { operationId => 'fetchMine' } }),
    ]);
    my %id = map { my $path = $_; map { ("$_ $path" => $doc->{paths}{$path}{$_}{operationId}) } keys %{ $doc->{paths}{$path} } }
        keys %{ $doc->{paths} };
    is(\%id, {
        'get /a/show' => 'get_a_show', 'get /b/show' => 'get_b_show', 'get /api/items/{id}' => 'get_v1_item',
        'get /' => 'get',
        'get /health' => 'get_health', 'delete /notes/{id}' => 'delete_notes_id', 'get /mine' => 'fetchMine',
    }, 'named: method and address; unnamed: method and template; meta replaces it');
};

subtest 'parameter types' => sub {
    my $Positive = Type::Tiny->new(name => 'Positive', parent => Int, constraint => sub { $_ > 0 });
    my $doc = doc_of([route('/p/{a:&Int}/{b:&Num}/{c:&Bool}/{d:\d+}/{e}/{f}/{g}/{h}' => $ok,
        constraints => { e => qr/x/, g => $Positive, h => sub { 1 } }),
        route('/s/{s:&Str}' => $ok)]);
    is($doc->{paths}{'/s/{s}'}{get}{parameters}[0]{schema}, { type => 'string' }, 'Str is a string');
    is([map { [$_->{name}, $_->{schema}{type}] } @{ $doc->{paths}{'/p/{a}/{b}/{c}/{d}/{e}/{f}/{g}/{h}'}{get}{parameters} }],
        [[a => 'integer'], [b => 'number'], [c => 'boolean'], [d => 'string'], [e => 'string'], [f => 'string'],
         [g => 'integer'], [h => 'string']],
        'Types::Standard types and their subtypes map; regexps, coderefs and none are strings');
    is($doc->{paths}{'/p/{a}/{b}/{c}/{d}/{e}/{f}/{g}/{h}'}{get}{parameters}[0],
        { name => 'a', in => 'path', required => T(), schema => { type => 'integer' } }, 'a path parameter in full');
};

subtest 'meta parameters merge by name and in' => sub {
    my $doc = doc_of([route('/n/{id:&Int}' => $ok, meta => { openapi => { parameters => [
        { name => 'id', in => 'path', schema => { type => 'integer', minimum => 1 } },
        { name => 'q',  in => 'query', schema => { type => 'string' } },
        { '$ref' => '#/components/parameters/Page' },
    ] } })]);
    is($doc->{paths}{'/n/{id}'}{get}{parameters}, [
        { name => 'id', in => 'path', required => T(), schema => { type => 'integer', minimum => 1 } },
        { name => 'q',  in => 'query', schema => { type => 'string' } },
        { '$ref' => '#/components/parameters/Page' },
    ], 'a matching parameter takes the fragment keys; another, or a $ref, is appended');
};

subtest 'security from Requires' => sub {
    my $doc = openapi_document(compose(
        middleware => [middleware('Requires', scopes => ['app'])],
        routes => [route('/z' => $ok)],
    ), %info, @bearer);
    is($doc->{paths}{'/z'}{get}{security}, [{ bearer => ['app'] }], "a Requires in Compose's application middleware");

    $doc = doc_of([
        route('/w' => $ok, protected(scopes => ['notes:write'])),
        route('/any' => $ok, protected()),
        route('/plus' => $ok, middleware => [middleware('+PAGI::Middleware::Requires', scopes => ['c'])]),
        mount('/m', protected(scopes => 'b'), routes => [route('/x' => $ok, protected(scopes => ['a', 'b']))]),
        route('/open' => $ok),
    ], @bearer);
    is($doc->{paths}{'/w'}{get}{security}, [{ bearer => ['notes:write'] }], "a route's Requires");
    is($doc->{paths}{'/any'}{get}{security}, [{ bearer => [] }], 'no scopes: any authenticated user');
    is($doc->{paths}{'/plus'}{get}{security}, [{ bearer => ['c'] }], 'the full class name is recognized');
    is($doc->{paths}{'/m/x'}{get}{security}, [{ bearer => ['a', 'b'] }], 'every Requires on the route, scopes unique and sorted');
    ok(!exists $doc->{paths}{'/open'}{get}{security}, 'a route without Requires has no security');
    my $object = doc_of([route('/obj' => $ok, middleware => [middleware(PAGI::Middleware::Requires->new(scopes => ['x']))])]);
    ok(!exists $object->{paths}{'/obj'}{get}{security}, 'a Requires given as a configured object is not recognized (and does not die)');
    is($doc->{components}{securitySchemes}, { bearer => { type => 'http', scheme => 'bearer' } }, 'the scheme in components');

    like(dies { doc_of([route('/w' => $ok, protected())]) },
        qr/PAGI::Routing::OpenAPI: routes use Requires; give a security_scheme/, 'Requires without a scheme');
};

subtest 'meta merges outermost first; responses default' => sub {
    my $doc = doc_of([
        mount('/m', meta => { openapi => { tags => ['m'], summary => 'from mount' } }, routes => [
            route('/r' => $ok, desc => 'D', meta => { openapi => { summary => 'from route' } }),
        ]),
        route('/typed' => $ok, meta => { openapi => { responses => { 204 => { description => 'none' } } } }),
    ]);
    is($doc->{paths}{'/m/r'}{get}{tags}, ['m'], "a mount's fragment reaches its routes");
    is($doc->{paths}{'/m/r'}{get}{summary}, 'from route', 'and a route overrides it (desc first, then mount, then route)');
    is($doc->{paths}{'/m/r'}{get}{responses}, { default => { description => 'response' } }, 'responses default');
    is($doc->{paths}{'/typed'}{get}{responses}, { 204 => { description => 'none' } }, 'unless meta gives them');
};

subtest 'components' => sub {
    my $doc = doc_of([route('/a' => $ok)], components => { schemas => { X => { type => 'object' } } }, @bearer);
    is($doc->{components}, {
        schemas => { X => { type => 'object' } },
        securitySchemes => { bearer => { type => 'http', scheme => 'bearer' } },
    }, 'merged with the security scheme');
};

subtest 'constructor and argument errors' => sub {
    like(dies { PAGI::Routing::OpenAPI->new(version => '1') }, qr/PAGI::Routing::OpenAPI: title is required/, 'title');
    like(dies { PAGI::Routing::OpenAPI->new(title => 'T') }, qr/PAGI::Routing::OpenAPI: version is required/, 'version');
    like(dies { PAGI::Routing::OpenAPI->new(%info, colour => 'red') },
        qr/PAGI::Routing::OpenAPI: unknown option 'colour'/, 'an unknown option');
    like(dies { openapi_document(sub { }, %info) }, qr/PAGI::Routing::OpenAPI: .*route_table/, 'a source without route_table');
};

subtest 'openapi returns the application, its document a route inside it' => sub {
    my ($started, @seen) = (0);
    my $spy = sub {
        my ($app) = @_;
        return sub { my ($scope) = @_; push @seen, "$scope->{method} $scope->{path}" if $scope->{type} eq 'http'; return $app->(@_) };
    };
    my $inner = compose(
        routes       => [route('/a' => $ok, name => 'a')],
        middleware   => [middleware($spy)],
        http_default => response('Text', 'custom 404', status => 404),
        lifespan     => { startup => sub { $started++; return } },
    );
    my $app = openapi($inner, %info);
    isa_ok($app, ['PAGI::Compose'], 'a Compose');
    is([sort map { $_->template } $app->route_table], ['/a', '/openapi.json'], 'listing the document route and the application');

    my $client = PAGI::Test::Client->new(app => $app, lifespan => 'auto');
    $client->start;
    my $res = $client->get('/openapi.json');
    is($res->status, 200, 'GET /openapi.json answers');
    is([keys %{ $res->json->{paths} }], ['/a'], 'with the application, not itself');
    ok(!exists $res->json->{servers}, 'no servers at the root');
    my $head = $client->head('/openapi.json');
    is([$head->status, $head->content], [200, ''], 'HEAD too, through Compose');
    is($client->post('/openapi.json')->status, 404, 'another method reaches the application');
    is($client->get('/a')->text, 'ok', 'other requests reach the application');
    is($client->get('/nope')->text, 'custom 404', "and its http_default");
    is($app->http_default, $inner->http_default, 'which the result reports, as it does desc');
    ok((grep { $_ eq 'GET /openapi.json' } @seen), "the application's own middleware sees the document request");
    is($started, 1, 'and lifespan runs');

    my $outer = compose(routes => [mount('/api', app => openapi($inner, %info))]);
    is(PAGI::Test::Client->new(app => $outer)->get('/api/openapi.json')->json->{servers}, [{ url => '/api' }],
        'served under a prefix, servers says where');

    my $moved = openapi($inner, %info, path => '/docs.json');
    is(PAGI::Test::Client->new(app => $moved)->get('/docs.json')->status, 200, 'path moves it');

    my $from_router = openapi(router(routes => [route('/r' => $ok)]), %info);
    my $rc = PAGI::Test::Client->new(app => $from_router);
    is([keys %{ $rc->get('/openapi.json')->json->{paths} }], ['/r'], 'a Router source is documented');
    is($rc->get('/r')->text, 'ok', 'and served');

    like(dies { openapi(compose(routes => [route('/i/{a}' => $ok), route('/i/{b}' => $ok)]), %info) },
        qr/same OpenAPI path/, 'a bad document dies when applied');
    like(dies { openapi(compose(routes => [route('/openapi.json' => $ok)]), %info) },
        qr{PAGI::Routing::OpenAPI: the application answers GET /openapi\.json},
        'as does an application route the document would shadow');
    ok(lives { openapi(compose(routes => [route('/openapi.json' => $ok, methods => ['POST'])]), %info) },
        'a route there for another method is not shadowed');

    require PAGI::Tools;
    ok(PAGI::Tools->_exports->{openapi} == PAGI::Routing::OpenAPI->_exports->{openapi}, 'PAGI::Tools re-exports openapi');
};

subtest 'a subclass builds on it' => sub {
    package My::OpenAPI {
        use parent -norequire, 'PAGI::Routing::OpenAPI';
        sub operation { my ($self, $entry, $method, $op) = @_; $op->{tags} = ['api']; return $op }
        sub parameter_schema { my ($self, $name) = @_; return { type => 'string', format => $name } }
        sub operation_id { my ($self, $entry, $method) = @_; return 'X' . $method }
        sub security_for { return [{ s => [] }] }
    }
    my $doc = My::OpenAPI->new(%info)->document(compose(routes => [route('/a/{id:&Int}' => $ok)]));
    is($doc->{paths}{'/a/{id}'}{get}{tags}, ['api'], 'operation has the last word');
    is($doc->{paths}{'/a/{id}'}{get}{parameters}[0]{schema}, { type => 'string', format => 'id' }, 'parameter_schema is used');
    is($doc->{paths}{'/a/{id}'}{get}{operationId}, 'XGET', 'operation_id is used');
    is($doc->{paths}{'/a/{id}'}{get}{security}, [{ s => [] }], 'security_for is used');
};

done_testing;
