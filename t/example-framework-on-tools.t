use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use PAGI::Test::Client;
use PAGI::Compose ();
use PAGI::Routing ();

# Tiny, the small framework in examples/framework-on-tools/lib, built on
# PAGI-Tools: each test pins one seam the framework stands on.

# In BEGIN: the test loads the example's Tiny with use, at compile time.
BEGIN { plan skip_all => 'examples/framework-on-tools requires Perl 5.40' if $] < 5.040 }

my $app = do "$Bin/../examples/framework-on-tools/app.pl";
is($@, '', 'the example loads');
isa_ok($app, 'PAGI::Compose');

my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
$client->start;

# Plain-value returns: a string is HTML, an arrayref is JSON.
my $res = $client->get('/');
is($res->status, 200, 'the index is served');
like($res->content_type, qr{^text/html}, 'a returned string is HTML');
like($res->text, qr/Tiny notes/, 'with its body');

$res = $client->get('/notes');
is($res->status, 200, 'the list is served');
is($res->json, [], 'a returned arrayref is JSON');

# The around hook and the plugin edit the response after call_next.
is($res->header('x-powered-by'), 'Tiny on PAGI-Tools', 'the around hook added its header');
like($res->header('server-timing'), qr/^notes;dur=\d/, 'and the Timing plugin added Server-Timing');

# A service built at startup, read through the framework's Request subclass.
$res = $client->post('/notes', json => { text => 'buy milk' });
is($res->status, 201, 'a note is created');
is($res->json, { id => 1, text => 'buy milk' }, 'in the startup-built store');

$res = $client->get('/notes/1');
is($res->json, { id => 1, text => 'buy milk' }, 'and read back by its id through param()');

# A thrown exception class mapped to a response.
$res = $client->get('/notes/9');
is($res->status, 404, 'a thrown Note::NotFound is a 404');
is($res->json, { error => 'no such note', id => 9 }, 'rendered by the on_error mapping');
is($res->header('x-powered-by'), 'Tiny on PAGI-Tools', 'and still passes through the around hook');

# A typed path parameter: the constraint turns a non-integer into a miss.
is($client->get('/notes/x')->status, 404, 'a non-integer id does not match the route');

# The before hook short-circuits.
$res = $client->get('/admin');
is($res->status, 403, 'the before hook refuses /admin');
is($res->json, { error => 'forbidden' }, 'with its own answer');
is($client->get('/admin?token=letmein')->json, { admin => 'ok' }, 'and lets a token through');

# Delete, then the stock 405 from the Router.
is($client->delete('/notes/1')->status, 204, 'a note is deleted');
$res = $client->put('/notes/1');
is($res->status, 405, 'an unsupported method is the router 405');
is($res->header('allow'), 'GET, HEAD, DELETE', 'with Allow merged across the two routes on that path');

# The raw escape hatch.
$res = $client->get('/raw');
is($res->status, 200, 'the raw application answers');
is($res->text, "raw PAGI\n", 'with its hand-sent chunks');

# The OpenAPI document generated from the Router.
$res = $client->get('/openapi.json');
is($res->status, 200, 'the OpenAPI document is served');
my $doc = $res->json;
is($doc->{info}{title}, 'Tiny notes', 'with its title');
is([sort keys %{ $doc->{paths} }],
    ['/', '/admin', '/notes', '/notes/{id}', '/openapi.json', '/raw'],
    'listing every route path');
is([sort keys %{ $doc->{paths}{'/notes/{id}'} }], ['delete', 'get'], 'with each method');
is($doc->{paths}{'/notes/{id}'}{get}{parameters},
    [{ name => 'id', in => 'path', required => T(), schema => { type => 'integer' } }],
    'and the typed path parameter from its constraint');
is($doc->{paths}{'/notes'}{get}{summary}, 'List the notes', 'and the route desc as summary');
is($doc->{paths}{'/notes'}{get}{operationId}, 'get_notes', 'and an operationId from the method and the route address');
is($doc->{paths}{'/notes'}{post}{requestBody}{content}{'application/json'}{schema}{required}, ['text'],
    'and a hand-written requestBody from the route meta');

# The around middleware's other branches, on a second Tiny application: a
# hook that answers without calling $next, one that replaces the response
# after $next, a status edit, a streamed response passing through, and a
# handler that dies under the hook.
subtest 'around middleware branches' => sub {
    package AroundProbe;
    use Test2::V0;
    use feature 'signatures';
    no warnings 'experimental::signatures';
    use Future::AsyncAwait;
    use lib "$FindBin::Bin/../examples/framework-on-tools/lib";
    use Tiny;

    my @log;
    around async sub ($req, $next) {
        return { blocked => 1 } if $req->path eq '/block';
        my $sent = await $next->();
        push @log, "saw $sent->{status}";
        return response('Text', 'replaced', status => 418) if $req->path eq '/replace';
        $sent->status(202) if $req->path eq '/restatus';
        return $sent;
    };
    get '/ok'       => sub ($req) { push @log, 'ok';       { ok => 1 } };
    get '/block'    => sub ($req) { push @log, 'block';    { ok => 1 } };
    get '/replace'  => sub ($req) { push @log, 'replace';  { ok => 1 } };
    get '/restatus' => sub ($req) { push @log, 'restatus'; { ok => 1 } };
    get '/boom'     => sub ($req) { die "handler bug\n" };
    get '/stream'   => sub ($req) {
        response('Stream', async sub ($w) { await $w->write('a'); await $w->write('b'); push @log, 'stream done' });
    };
    my $probe = PAGI::Test::Client->new(app => tiny);

    my $res = $probe->get('/ok');
    is($res->json, { ok => 1 }, 'a response passes through the hook');
    $res = $probe->get('/block');
    is([$res->status, $res->json], [200, { blocked => 1 }], 'a hook that never calls $next answers itself');
    $res = $probe->get('/replace');
    is([$res->status, $res->text], [418, 'replaced'], 'a hook can replace the response after $next');
    $res = $probe->get('/restatus');
    is([$res->status, $res->json], [202, { ok => 1 }], 'or edit its status');
    $res = $probe->get('/stream');
    is($res->text, 'ab', 'a streamed response flows through after the start event');
    my $warning = warning { $res = $probe->get('/boom') };
    is($res->status, 500, 'a handler that dies under the hook is a 500');
    like($warning, qr/handler bug/, 'reported as the server would');
    is(\@log, [
        'ok', 'saw 200',
        'replace', 'saw 200',
        'restatus', 'saw 200',
        'saw 200', 'stream done',
    ], 'the inner handler never ran for the short circuit, and $next resolved before each body; '
        . 'an unhandled bug reaches the hook as an exception, as call_next raises in Starlette');
};

# The compact {id:&Int} form: route() looks the provider up in its caller,
# which is Tiny; Tiny names the application's package instead.
subtest 'compact typed path parameters' => sub {
    package CompactProbe;
    use Test2::V0;
    use feature 'signatures';
    no warnings 'experimental::signatures';
    use lib "$FindBin::Bin/../examples/framework-on-tools/lib";
    use Tiny;
    use Types::Standard qw(Int);

    my $built = eval { get '/n/{id:&Int}' => sub ($req) { 'n' . $req->param('id') }; 1 } || $@;
    is($built, 1, 'the route builds with the provider from the application');
    SKIP: {
        skip 'the route did not build', 2 unless $built eq '1';
        my $probe = PAGI::Test::Client->new(app => tiny());
        is($probe->get('/n/7')->text, 'n7', 'an integer id matches');
        is($probe->get('/n/x')->status, 404, 'anything else is a miss');
    }
};

subtest 'the OpenAPI document refuses colliding paths and keeps operationIds unique' => sub {
    my $ok = sub { 'ok' };
    my $tiny = sub {
        my $t = Tiny->new('OpenAPIProbe');
        $t->add_route(@$_) for @_;
        $t->to_compose;
        return $t;
    };
    like dies { $tiny->(['GET', '/items/{id:\d+}', $ok], ['GET', '/items/{slug:[a-z]+}', $ok])->openapi_doc },
        qr/same OpenAPI path/, 'templates differing only in parameter names are an error';
    like dies { $tiny->(['GET', '/items/{id:\d+}', $ok], ['GET', '/items/{id:[a-z]+}', $ok])->openapi_doc },
        qr{two routes for GET /items/\{id\}}, 'one template and method declared twice is an error';
    is [keys %{ $tiny->(['HEAD', '/ping', $ok])->openapi_doc->{paths}{'/ping'} }], ['head'],
        'a HEAD-only route is documented as head';

    # What Tiny's own verbs cannot declare (a child Router under two mounts, a
    # named route answering two methods): the composition is set directly.
    my $child = PAGI::Routing::router(routes => [
        PAGI::Routing::route('/show' => sub { }, name => 'show', methods => ['GET', 'POST']),
    ]);
    my $t = Tiny->new('OpenAPIProbe2');
    $t->{compose} = PAGI::Compose::compose(routes => [
        PAGI::Routing::mount('/api', app => $child, name => 'api'),
        PAGI::Routing::mount('/v2',  app => $child, name => 'v2'),
    ]);
    my $doc = $t->openapi_doc;
    is [sort map { $_->{operationId} } map { values %$_ } values %{ $doc->{paths} }],
        [qw(get_api_show get_v2_show post_api_show post_v2_show)],
        'distinct operationIds across methods and placements';
};

# on_error: the most specific class answers, whatever the declaration order
# (Tiny's on_error is ErrorHandler's catch), and a status works as a key.
subtest 'on_error precedence' => sub {
    package CatchProbe;
    use Test2::V0;
    use PAGI::Exception::HTTP;
    use feature 'signatures';
    no warnings 'experimental::signatures';
    use lib "$FindBin::Bin/../examples/framework-on-tools/lib";
    use Tiny;

    package CatchProbe::General  { sub new { bless {}, shift } }
    package CatchProbe::Specific { our @ISA = ('CatchProbe::General') }
    package CatchProbe;

    on_error 'CatchProbe::General'  => sub ($req, $exc) { response('Text', 'general', status => 409) };
    on_error 'CatchProbe::Specific' => sub ($req, $exc) { response('Text', 'specific', status => 409) };
    on_error 404                    => sub ($req, $exc) { response('Text', 'by status', status => 404) };
    get '/specific' => sub ($req) { die CatchProbe::Specific->new };
    get '/missing'  => sub ($req) { die PAGI::Exception::HTTP->new(404) };
    my $probe = PAGI::Test::Client->new(app => tiny);

    is($probe->get('/specific')->text, 'specific', 'the most specific class answers, though its parent is declared first');
    is($probe->get('/missing')->text, 'by status', 'a status key answers an HTTP error');
};

done_testing;
