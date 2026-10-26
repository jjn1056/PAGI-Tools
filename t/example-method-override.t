use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use PAGI::Test::Client;

# examples/method-override: plain HTML forms rename and delete notes by
# naming the method in their action URL; MethodOverride reads the header and
# the query, never the body, so the rename route reads its own form.

plan skip_all => 'examples/method-override requires Perl 5.40' if $] < 5.040;

my $app = do "$Bin/../examples/method-override/app.pl";
is($@, '', 'the example loads');
my $client = PAGI::Test::Client->new(app => $app);

is($client->post('/notes', form => { text => 'milk' })->status, 303, 'a plain POST adds a note');
like($client->get('/notes')->text, qr{action="/notes/1\?_method=PUT".*value="milk"}s,
    'the page names the method in each form action');

my $res = $client->post('/notes/1?_method=PUT', form => { text => 'oat <milk>' });
is($res->status, 303, '?_method=PUT reaches the PUT route');
like($client->get('/notes')->text, qr/value="oat &#60;milk&#62;"/,
    'which read the form body MethodOverride left untouched');

# The id is Starlette's int converter: [0-9]+, read as a number.
is($client->post('/notes/01?_method=PUT', form => { text => 'oat <milk>' })->status, 303,
    '/notes/01 is note 1, as {id:int} reads it');
for my $id ('abc', '-1') {
    my $miss = $client->post("/notes/$id?_method=DELETE");
    is([$miss->status, $miss->text], [404, 'Not Found'], "/notes/$id is not a note id: the router's 404");
}

$res = $client->post('/notes/1', form => { _method => 'DELETE' });
is([$res->status, $res->header('Allow')], [405, 'PUT, DELETE'],
    'a _method field in the body is not an override: the POST stays a POST');

is($client->post('/notes/1', headers => { 'X-HTTP-Method-Override' => 'DELETE' })->status, 303,
    'the header overrides, for an API client');
unlike($client->get('/notes')->text, qr/<li>/, 'and the note is gone');
is($client->post('/notes/1?_method=DELETE')->status, 404, 'deleting it again: no such note');
is($client->post('/notes/1?_method=TRACE')->status, 405, 'a method not on the allowed list is not an override');

done_testing;
