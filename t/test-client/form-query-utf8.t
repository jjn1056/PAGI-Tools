use strict;
use warnings;
use utf8;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../../lib";
use Future::AsyncAwait;
use PAGI::Test::Client;
use PAGI::Tools qw(compose response route);

# form => and query => values are characters, sent UTF-8 percent-encoded,
# as a browser sends them and as Test::Client's path and json => already
# are: the application decodes the characters that were given.

my %seen;
my $app = compose(routes => [route('/' => async sub {
    my ($request) = @_;
    $seen{query} = [$request->query_params->get_all('q')];
    $seen{raw_query} = $request->query_string;
    if ($request->method eq 'POST') {
        my $form = await $request->form_params;
        $seen{form} = [$form->get_all('f')];
        $seen{body} = await $request->body;
    }
    return response('Text', 'ok');
}, methods => ['GET', 'POST'])])->to_app;
my $client = PAGI::Test::Client->new(app => $app);

for my $value ("caf\x{e9}", "\x{263A}", "a b&c=d+e/f%g~h", "日本語") {
    my $name = join ' ', map { sprintf 'U+%04X', ord } split //, $value;

    %seen = ();
    $client->get('/', query => { q => $value });
    is $seen{query}, [$value], "query => { q => $name }: the route reads the characters";

    %seen = ();
    $client->post('/', form => { f => $value });
    is $seen{form}, [$value], "form => { f => $name }: the route reads the characters";
}

subtest 'the wire is UTF-8, percent-encoded' => sub {
    %seen = ();
    $client->get('/', query => { q => "caf\x{e9}" });
    is $seen{raw_query}, 'q=caf%C3%A9', 'query: é is %C3%A9';
    %seen = ();
    $client->post('/', form => { f => "\x{263A}" });
    is $seen{body}, 'f=%E2%98%BA', 'form: U+263A is %E2%98%BA';
};

subtest 'every form a value can take' => sub {
    %seen = ();
    $client->post('/', form => { f => ["caf\x{e9}", "\x{263A}"] });
    is $seen{form}, ["caf\x{e9}", "\x{263A}"], 'an arrayref of values';
    %seen = ();
    $client->post('/', form => [[f => "caf\x{e9}"], [f => 'x']]);
    is $seen{form}, ["caf\x{e9}", 'x'], 'pairs';
    %seen = ();
    $client->get('/?q=one', query => { q => "\x{e9}" });
    is $seen{query}, ['one', "\x{e9}"], 'query => appended to a query string in the path';
    %seen = ();
    $client->get('/', query => { "cl\x{e9}" => 'v' });
    is $seen{raw_query}, 'cl%C3%A9=v', 'a key is encoded too';
};

done_testing;
