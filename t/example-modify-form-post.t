use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";

BEGIN { plan skip_all => 'examples/modify-form-post requires Perl 5.40' if $] < 5.040 }

use Future::AsyncAwait;
use PAGI::Test::Client;
use PAGI::Tools qw(compose middleware response route);

# A middleware rewrites a urlencoded POST body before the route reads it:
# the route sees the trimmed, upper-cased username and the field the
# middleware added, and nothing else changes.

my $app = do "$Bin/../examples/modify-form-post/app.pl" or die $@ || $!;
my $client = PAGI::Test::Client->new(app => $app);

like $client->get('/')->text, qr/<form action="\/submit" method="post">/, 'the form page';

my $res = $client->post('/submit', form => { username => ' john_doe ', role => 'Developer' });
is $res->status, 200, 'the post is answered';
like $res->text,
    qr/\Q&#123;&#39;received_username&#39;: &#39;JOHN_DOE&#39;, &#39;received_role&#39;: &#39;Developer&#39;, &#39;injected_by_middleware&#39;: &#39;true&#39;&#125;\E/,
    'the route reads the rewritten form';

like $client->post('/submit', form => { username => 'ann', role => 'a&b' })->text,
    qr/&#39;received_role&#39;: &#39;a&amp;b&#39;/, 'other fields reach it unchanged, and escaped in the page';

like $client->post('/submit', form => { username => '<b>x</b>' })->text,
    qr/&lt;B&gt;X&lt;\/B&gt;/, 'a value is escaped in the page';

like $client->post('/submit', json => { username => ' john_doe ' })->text,
    qr/&#39;injected_by_middleware&#39;: &#39;&#39;/, 'a JSON body is not a form: left alone';

# The middleware itself, under a route that reports the form it got.
my $seen;
my $probe = PAGI::Test::Client->new(app => compose(
    routes => [route('/submit' => async sub {
        my ($request) = @_;
        $seen = await $request->form_params;
        return response('Text', 'ok');
    }, methods => ['POST'])],
    middleware => [middleware(\&main::modify_form_post)],
));

$probe->post('/submit', body => 'username=ada&middleware_processed=false',
    headers => { 'Content-Type' => 'application/x-www-form-urlencoded' });
is [$seen->get_all('middleware_processed')], ['true'], 'the stamp replaces a client\'s: one value, the middleware\'s';

# Sent as a browser sends it, UTF-8 bytes percent-encoded (Test::Client's
# form => encodes characters as Latin-1).
my $tricky = "caf\x{e9} & co=1+2 / 50%";
$probe->post('/submit', body => 'username=ann&role=caf%C3%A9+%26+co%3D1%2B2+%2F+50%25',
    headers => { 'Content-Type' => 'application/x-www-form-urlencoded' });
is [$seen->get('role'), $seen->get('username')], [$tricky, 'ANN'],
    'the re-encoded body carries UTF-8, &, =, +, / and % unchanged';

done_testing;
