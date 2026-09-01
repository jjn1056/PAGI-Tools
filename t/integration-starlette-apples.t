use strict;
use warnings;

use Test2::V0;
use FindBin qw($Bin);
use Digest::SHA qw(sha256_hex);
use JSON::PP ();
use Scalar::Util qw(refaddr);
use lib "$Bin/../lib";
use PAGI::Test::Client;

if ($] < 5.040) {
    plan skip_all => 'examples/starlette-apples requires Perl 5.40';
    exit 0;
}

my $app_file = "$Bin/../examples/starlette-apples/app.pl";
my $readme_file = "$Bin/../examples/starlette-apples/README.md";
my $example_lib = "$Bin/../examples/starlette-apples/lib";
unshift @INC, $example_lib;

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot open $path: $!\n";
    local $/;
    my $text = <$fh>;
    close $fh or die "cannot close $path: $!\n";
    return $text;
}

subtest 'README preserves the comparison and current executable source' => sub {
    my $readme = _slurp($readme_file);
    my $app_source = _slurp($app_file);
    my ($python) = $readme =~ /```python\n(.*?)```/s;
    my ($perl) = $readme =~ /```perl\n(.*?)```/s;

    is(
        sha256_hex($python // ''),
        '5841982d7452eaaba77a23fc9063fbe6fef53b8ea291371e7ed179789adb1835',
        'the supplied Python Starlette application remains byte-for-byte intact',
    );
    is($perl, $app_source,
        'the copied Perl application stays identical to the executable example');

    like($app_source, qr/compose\s*\(\s*routes\s*=>/s,
        'apples uses direct routes-form Compose');
    like($app_source, qr/http_default\s*=>\s*not_found/s,
        'apples configures its root default without nested router ceremony');
    unlike($app_source, qr/compose\s*\(\s*app\s*=>/s,
        'apples has no retired Compose app mode');
    unlike($app_source, qr/compose\s*\(\s*router\s*=>\s*router\s*\(/s,
        'apples does not construct a redundant nested Router expression');
};

subtest 'Moose model owns fixture and CRUD behavior' => sub {
    my $loaded = eval { require AppleApp::Model; 1 };
    ok($loaded, 'AppleApp::Model loads from the runner-supplied library path')
        or diag($@);
    return unless $loaded;

    my $imported = eval { AppleApp::Model->import('apple_model'); 1 };
    ok($imported, 'AppleApp::Model exports its model factory on request')
        or diag($@);
    return unless $imported;

    my $factory = __PACKAGE__->can('apple_model');
    ok($factory, 'apple_model is installed in the requesting package');
    return unless $factory;

    my $model = $factory->();
    my $other_model = $factory->();
    isa_ok($model, 'AppleApp::Model');
    isnt(refaddr($model), refaddr($other_model),
        'apple_model returns a fresh model instance');
    is($model->all, [
        { id => 1, name => 'Gala',       color => 'Red/Yellow' },
        { id => 2, name => 'Honeycrisp', color => 'Rosy Red' },
    ], 'model owns the ordered fixture collection');
    is($model->find(1),
        { id => 1, name => 'Gala', color => 'Red/Yellow' },
        'model finds one apple');

    my $created = $model->create({ name => 'Fuji', color => 'Red' });
    is($created, { id => 3, name => 'Fuji', color => 'Red' },
        'model assigns the next numeric ID');
    is($model->update(3, { color => 'Crimson' }),
        { id => 3, name => 'Fuji', color => 'Crimson' },
        'model updates an existing apple');
    is($model->update(999, { color => 'Green' }), undef,
        'model declines an update for a missing apple');
    is($model->delete(3),
        { id => 3, name => 'Fuji', color => 'Crimson' },
        'model returns the deleted apple');
    is($model->find(3), undef,
        'deleted apple is no longer present');
};

my $app = do $app_file;
my $load_error = $@ || $!;
ok(!$load_error, 'Starlette comparison example loads cleanly')
    or diag($load_error);
isa_ok($app, 'PAGI::Compose');

subtest 'apple manager, welcome, routing outcomes, and apples CRUD' => sub {
    plan skip_all => 'example did not load'
        unless ref($app) eq 'PAGI::Compose';

    PAGI::Test::Client->run($app, sub {
        my ($client) = @_;
        isa_ok($client->state->{apples}, 'AppleApp::Model');

    my $manager = $client->get('/', headers => { Accept => 'text/html' });
    is($manager->status, 200, 'apple manager route responds');
    is($manager->content_type, 'text/html',
        'apple manager is an HTML application');
    like($manager->text, qr/<title>Apple Manager<\/title>/,
        'root identifies the apple manager');
    like($manager->text, qr/<form\b[^>]*id="apple-form"/,
        'manager provides the create and edit form');
    like($manager->text, qr/<section\b[^>]*id="apple-list"/,
        'manager provides a live apple list');
    like($manager->text, qr/href="\/welcome"/,
        'manager links to the PAGI welcome page');
    ok(defined($manager->header('X-Request-ID'))
            && length($manager->header('X-Request-ID')),
        'global RequestId middleware identifies the manager response');
    is($manager->header('X-Apples-API'), undef,
        'apples middleware does not leak onto the manager response');

    my $manager_head = $client->head('/');
    is($manager_head->status, 200,
        'static manager application defaults HEAD alongside GET');
    is($manager_head->text, '',
        'HEAD suppresses the static manager response body');

    my $manager_wrong_method = $client->put('/',
        headers => { Accept => 'application/problem+json' });
    is($manager_wrong_method->status, 405,
        'static manager application rejects methods outside its GET default');
    is($manager_wrong_method->header('Allow'), 'GET, HEAD',
        'static manager application publishes its GET and HEAD method union');

    my $welcome = $client->get('/welcome',
        headers => { Accept => 'text/html' });
    is($welcome->status, 200, 'welcome route responds');
    like($welcome->text, qr/<title>200 Welcome to PAGI<\/title>/,
        '/welcome uses the shared Pages welcome endpoint');

    my $list = $client->get('/apples');
    is($list->status, 200, 'apple collection responds');
    is($list->json, [
        {
            id => 1, name => 'Gala', color => 'Red/Yellow',
            url => 'http://testserver/apples/1',
        },
        {
            id => 2, name => 'Honeycrisp', color => 'Rosy Red',
            url => 'http://testserver/apples/2',
        },
    ], 'collection preserves numeric ID order');
    ok(defined($list->header('X-Request-ID'))
            && length($list->header('X-Request-ID')),
        'global RequestId middleware identifies the apples response');
    is($list->header('X-Apples-API'), '1',
        'apples middleware marks the mounted API response');

    my $slash_list = $client->get('/apples/');
    is($slash_list->status, 200,
        'mounted collection index also responds with a trailing slash');
    is($slash_list->json, $list->json,
        '/apples and /apples/ reach the same child index');

    my $gala = $client->get('/apples/1');
    is($gala->status, 200, 'apple detail responds');
    is($gala->json,
        { id => 1, name => 'Gala', color => 'Red/Yellow' },
        'detail returns the selected apple');

    my $missing_apple = $client->get('/apples/999');
    is($missing_apple->status, 404,
        'missing database record is an application 404');
    is($missing_apple->content_type, 'application/json',
        'resource miss retains the application JSON representation');
    is($missing_apple->json, { error => 'Apple not found' },
        'resource miss retains the application error shape');

    my $missing_update = $client->put('/apples/999');
    is($missing_update->status, 404,
        'missing update is rejected before reading a request body');
    is($missing_update->json, { error => 'Apple not found' },
        'missing update retains the application error shape');

    my $invalid_id = $client->get('/apples/not-an-int',
        headers => { Accept => 'application/problem+json' });
    is($invalid_id->status, 404,
        'failed Int constraint is a routing 404');
    is($invalid_id->content_type, 'application/problem+json',
        'selected child Router negotiates the routing miss');
    is($invalid_id->json->{title}, 'Not Found',
        'routing miss uses the stock Pages title');
    is($invalid_id->json->{detail},
        'The requested resource was not found.',
        'selected child Router keeps its stock 404 detail');
    ok(!exists $invalid_id->json->{error},
        'routing miss never reaches the application error branch');

    my $negative_id = $client->get('/apples/-1');
    is($negative_id->status, 404,
        'Types::Standard Int accepts negative integer text');
    is($negative_id->json, { error => 'Apple not found' },
        'negative integer reaches the resource handler unchanged');

    my $wrong_method = $client->patch('/apples',
        headers => { Accept => 'application/problem+json' });
    is($wrong_method->status, 405,
        'known collection with unsupported method is 405');
    is($wrong_method->header('Allow'), 'GET, HEAD, POST',
        'selected child Router owns its method union');
    is($wrong_method->json->{title}, 'Method Not Allowed',
        'selected child Router renders the stock method response');

    my $created = $client->post('/apples', json => {
        name  => 'Fuji',
        color => 'Red',
    });
    is($created->status, 201, 'create returns 201');
    is($created->json,
        { id => 3, name => 'Fuji', color => 'Red' },
        'create assigns the next numeric ID');
    is($created->header('Location'), '/apples/3',
        'create publishes the generated item path');

    my $updated = $client->put('/apples/3', json => {
        color => 'Crimson',
    });
    is($updated->status, 200, 'update responds');
    is($updated->json,
        { id => 3, name => 'Fuji', color => 'Crimson' },
        'update merges supplied members into the stored record');

    my $deleted = $client->delete('/apples/3');
    is($deleted->status, 200, 'delete responds');
    my $deleted_json = $deleted->json;
    ok(JSON::PP::is_bool($deleted_json->{success}),
        'delete success is a real JSON boolean');
    ok($deleted_json->{success}, 'delete success is true');
    is($deleted_json->{deleted},
        { id => 3, name => 'Fuji', color => 'Crimson' },
        'delete returns the removed record');

    my $after_delete = $client->get('/apples/3');
    is($after_delete->status, 404,
        'deleted record is no longer available');
    is($after_delete->json, { error => 'Apple not found' },
        'post-delete miss remains application output');

    my $unknown = $client->get('/elsewhere',
        headers => { Accept => 'application/problem+json' });
    is($unknown->status, 404, 'unknown root path uses root Router NotFound');
    is($unknown->content_type, 'application/problem+json',
        'root routing miss negotiates problem JSON');
    is($unknown->json->{title}, 'Not Found',
        'root routing miss uses the shared Pages response');
    is($unknown->json->{detail},
        'That page does not exist in the Apple demo.',
        'root routing miss uses the application-owned default detail');

    my $unknown_delete = $client->delete('/elsewhere',
        headers => { Accept => 'application/problem+json' });
    is($unknown_delete->status, 404,
        'unknown DELETE is a Router NONE 404, not a wildcard 405');
    is($unknown_delete->json->{detail},
        'That page does not exist in the Apple demo.',
        'custom root default handles unknown methods as well as GET');

    my $welcome_wrong_method = $client->put('/welcome',
        headers => { Accept => 'application/problem+json' });
    is($welcome_wrong_method->status, 405,
        'known welcome path preserves its method-owned 405');
    is($welcome_wrong_method->header('Allow'), 'GET, HEAD',
        'known welcome path publishes its exact method union');
    is($welcome_wrong_method->json->{title}, 'Method Not Allowed',
        'root default does not swallow a known-path 405');
    });
};

done_testing;
