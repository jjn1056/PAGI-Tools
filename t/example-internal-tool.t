use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use PAGI::Test::Client;

# The task board: the page renders from its templates, a bad form re-renders
# with errors and the submitted values, a good one redirects and the next
# page carries the flash, CSRF is checked on every POST, and the stylesheet
# is served from the static mount.

if ($] < 5.040) {
    plan skip_all => 'examples/internal-tool requires Perl 5.40';
    exit 0;
}
eval { require Template; 1 } or do {
    plan skip_all => 'examples/internal-tool requires Template Toolkit';
    exit 0;
};

my $app = do "$Bin/../examples/internal-tool/app.pl";
is($@, '', 'the example loads');
isa_ok($app, 'PAGI::Compose');
like(warning { $app->to_app }, qr/\APAGI::Middleware::Session: no store given/,
    'its default session store says so');

my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
$client->start;

sub token { my ($html) = @_; my ($t) = $html =~ /name="csrf_token" value="([^"]+)"/; return $t }

my $res = $client->get('/');
is($res->status, 200, 'the board is served');
like($res->text, qr/Nothing to do\./, 'empty at first');
like($res->text, qr{href="/static/style\.css"}, 'linking its stylesheet');
my $token = token($res->text);
ok($token, 'with a CSRF token in the form');

is($client->get('/static/style.css')->status, 200, 'the stylesheet is served from the static mount');

$res = $client->post('/tasks', form => { title => '', due => 'soon', csrf_token => $token });
is($res->status, 422, 'an invalid form is re-rendered');
like($res->text, qr/A title is required\./, 'with the title error');
like($res->text, qr/Use YYYY-MM-DD\./, 'and the date error');
like($res->text, qr/value="soon"/, 'keeping what was typed');

$res = $client->post('/tasks', form => { title => 'Rotate the on-call key', due => '2026-10-20' });
is($res->status, 403, 'a form without the CSRF token is refused');

$res = $client->post('/tasks', form => { title => 'Rotate the on-call key', due => '2026-10-20', csrf_token => $token });
is($res->status, 303, 'a valid form redirects');
is($res->header('location'), '/', 'back to the board');

$res = $client->get('/');
like($res->text, qr/class="flash">Added &quot;Rotate the on-call key&quot;\./, 'the next page shows the flash');
like($res->text, qr/Rotate the on-call key/, 'and the task');
like($res->text, qr/2026-10-20/, 'with its due date');
unlike($client->get('/')->text, qr/class="flash"/, 'the flash is shown once');

# The board's own errors, answered in one place at the route, with the
# route's own Request.
$res = $client->post('/tasks', form => { title => 'rotate the ON-CALL key', due => '2026-11-01', csrf_token => $token });
is($res->status, 409, 'a title already on the board is a conflict');
like($res->text, qr/There is already a task called &quot;rotate the ON-CALL key&quot;\./, 'with the error');
like($res->text, qr/value="rotate the ON-CALL key"/, 're-rendered with what was typed');
like($res->text, qr/value="2026-11-01"/, 'the whole form');

$res = $client->post('/tasks/9/toggle', form => { csrf_token => $token });
is([$res->status, $res->text], [404, 'No such task: 9.'], 'a missing task, by the id in the path');

$res = $client->get('/nowhere');
is([$res->status, $res->text], [404, 'No such page: /nowhere.'], "an unknown page: the router's 404, answered by the entry");

is($client->post('/tasks/1/toggle', form => {})->status, 403, 'a toggle without the token is refused');
is($client->post('/tasks/1/delete', form => { csrf_token => 'forged' })->status, 403,
    'a delete with a wrong token is refused');

$res = $client->post('/tasks/1/toggle', form => { csrf_token => $token });
is($res->status, 303, 'toggling redirects');
like($client->get('/')->text, qr/class="done".*Done: Rotate the on-call key\.|Done: Rotate the on-call key\..*class="done"/s,
    'and the task is done, with its flash');

is($client->post('/tasks/9/delete', form => { csrf_token => $token })->status, 404, 'deleting a missing task is a 404');
is($client->post('/tasks/1/delete', form => { csrf_token => $token })->status, 303, 'deleting redirects');
like($client->get('/')->text, qr/Deleted\..*Nothing to do\./s, 'and the board is empty again');

# Served under the root path /app, the stylesheet link keeps the prefix.
my $prefixed = PAGI::Test::Client->new(app => $app, lifespan => 1, root_path => '/app');
$prefixed->start;
my ($stylesheet) = $prefixed->get('/app/')->text =~ m{<link rel="stylesheet" href="([^"]*)">};
is($stylesheet, '/app/static/style.css', 'under a root path the stylesheet link keeps the prefix');
is($prefixed->get($stylesheet)->status, 200, 'and resolves');
$prefixed->stop;


done_testing;
