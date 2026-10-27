use strict;
use warnings;
use utf8;
use Test2::V0;

BEGIN { plan skip_all => 'examples/gut-check requires Perl 5.40' if $] < 5.040 }
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/lib";
use Digest::SHA qw(sha256_hex);
use PAGI::Test::Client;
use PAGITest::LeavingClient qw(leaves_at_handshake);

# The gut-check apps (examples/gut-check), each driven with the request
# sequence its README describes. Each file compiles in a package of its own,
# so their top-level subs cannot collide -- except in a file that switches
# package itself: 02 and 05 return to package main, where 05's subs live.

my $loaded = 0;

sub load_app {
    my ($name) = @_;
    my $file = "$Bin/../examples/gut-check/$name";
    my $package = 'PAGITest::GutCheck' . ++$loaded;
    my $app = eval "package $package; do \$file or die \$@ || \$!"
        or die "$name: $@";
    return $app;
}

subtest '01: errors as responses' => sub {
    my $client = PAGI::Test::Client->new(app => load_app('01-errors-as-responses.pl'));

    my $res = $client->get('/notes/1');
    is($res->status, 200, 'a note is served');
    is($res->json, { id => 1, text => 'buy milk' }, 'as JSON');

    $res = $client->get('/notes/9');
    is($res->status, 404, 'a missing note is a 404 thrown from the model');
    is($res->json, { error => 'no such note: 9' }, 'rendered as JSON by the handler');

    $res = $client->get('/nope');
    is($res->status, 404, 'a path no route matches is a 404');
    is($res->json, { error => 'Not Found' }, 'in the same JSON shape');

    $res = $client->post('/notes/1');
    is([$res->status, $res->json, $res->header('Allow')], [405, { error => 'Method Not Allowed' }, 'GET, HEAD'],
        "a wrong method: the router's 405, in the JSON shape, keeping its Allow");

    like(
        warning { $res = $client->get('/boom') },
        qr/exception after response completed: an ordinary bug/,
        'an ordinary bug is reported',
    );
    is($res->status, 500, 'and answered with the stock 500');
};

subtest '02: notes resource' => sub {
    my $client = PAGI::Test::Client->new(
        app => load_app('02-notes-resource.pl'), lifespan => 1,
    );
    $client->start;

    my $res = $client->post('/notes', json => { text => 'buy milk' });
    is($res->status, 201, 'POST creates');
    is($res->header('location'), '/notes/1', 'with a Location from the route name');

    $res = $client->get('/notes/1');
    is($res->status, 200, 'the note is served');
    is($res->json, { id => 1, text => 'buy milk' }, 'as stored');
    is($client->get('/notes')->json, [{ id => 1, text => 'buy milk' }], 'the list holds it');

    is($client->delete('/notes/1')->status, 204, 'DELETE removes it');
    is($client->get('/notes/1')->status, 404, 'and it is gone');
    is($client->get('/notes/abc')->status, 404, 'a non-integer id matches no route');

    $client->stop;
};

subtest '03: broadcast hub' => sub {
    my $client = PAGI::Test::Client->new(app => load_app('03-broadcast-hub.pl'));
    my $ws  = $client->websocket('/chat');
    my $sse = $client->sse('/watch');

    my $res = $client->post('/announce', body => 'tea is ready');
    is($res->status, 202, 'an announcement is accepted');
    is($res->json, { delivered_to => 2 }, 'and delivered to both listeners');
    is($ws->receive_text, 'announce: tea is ready', 'the chat client hears it');
    is($sse->receive_event->{data}, 'announce: tea is ready', 'the watcher hears it');

    $ws->send_text('hello');
    is($sse->receive_event->{data}, 'chat: hello', 'a chat message reaches the watcher');

    $ws->close;
    $sse->close;
    is($client->post('/announce', body => 'x')->json, { delivered_to => 0 },
        'nobody listens once both have left');

    # Clients that leave as the handshake goes out must not stay registered.
    $client = PAGI::Test::Client->new(app => leaves_at_handshake(load_app('03-broadcast-hub.pl')));
    $client->websocket('/chat', sub { });
    $client->sse('/watch', sub { });
    is($client->post('/announce', body => 'x')->json, { delivered_to => 0 },
        'clients that left at the handshake are not listening');
};

subtest '04: everyday middleware, hand-written' => sub {
    my $client = PAGI::Test::Client->new(app => load_app('04-everyday-middleware.pl'));
    my $res = $client->get('/');
    is($res->status, 200, 'the app answers');
    like($res->header('server-timing'), qr/\Aapp;dur=\d+\.\d\z/, 'with Server-Timing');

    local $ENV{MAINTENANCE} = 1;
    $client = PAGI::Test::Client->new(app => load_app('04-everyday-middleware.pl'));
    $res = $client->get('/');
    is($res->status, 503, 'maintenance mode answers 503');
    is($res->header('retry-after'), 60, 'with Retry-After');
    is($client->get('/health')->status, 200, 'except /health');
};

subtest '04b: the same jobs with bundled middleware' => sub {
    my $client = PAGI::Test::Client->new(app => load_app('04b-bundled-middleware.pl'));
    my $res = $client->get('/');
    is($res->status, 200, 'the app answers');
    like($res->header('x-runtime'), qr/\A\d+\.\d+\z/, 'with X-Runtime');

    local $ENV{MAINTENANCE} = 1;
    $client = PAGI::Test::Client->new(app => load_app('04b-bundled-middleware.pl'));
    $res = $client->get('/');
    is($res->status, 503, 'maintenance mode answers 503');
    is($res->header('retry-after'), 60, 'with Retry-After');
    is($client->get('/health')->status, 200, 'except /health');
};

subtest '05: streaming' => sub {
    my $client = PAGI::Test::Client->new(app => load_app('05-streaming.pl'));

    my $res = $client->get('/ticks');
    is($res->status, 200, 'the NDJSON feed streams');
    is([split /\n/, $res->text], [map { qq({"tick":$_}) } 0 .. 4], 'five ticks, one per line');

    $res = $client->get('/report.tsv');
    is($res->status, 200, 'the custom format streams');
    is($res->text, "city\tpopulation\nLisbon\t545000\nKraków\t800000\n",
        'three tab-separated rows in UTF-8');
};

subtest '06: sessions' => sub {
    my $app = load_app('06-sessions.pl');
    like(warning { $app->to_app }, qr/\APAGI::Middleware::Session: no store given/, 'the default store says so');
    my $client = PAGI::Test::Client->new(app => $app);

    is($client->get('/visits')->json, { visits => 1, name => undef }, 'a first visit');
    is($client->get('/visits')->json, { visits => 2, name => undef }, 'counts with the cookie');
    is($client->post('/name', body => 'Ada')->status, 204, 'a name is stored');
    is($client->get('/visits')->json, { visits => 3, name => 'Ada' }, 'and remembered');

    my $res;
    like(
        warning { $res = $client->get('/strict') },
        qr/Available keys: name, visits/,
        'a typo names the keys that exist',
    );
    is($res->status, 500, 'and is a 500');
};

subtest '07: upload relay' => sub {
    my $client = PAGI::Test::Client->new(app => load_app('07-upload-relay.pl'));
    my $body = join '', map { chr($_ % 256) } 0 .. 99_999;

    is($client->post('/relay', body => $body)->content, $body, 'the upload is relayed byte for byte');
    my $res = $client->post('/shout', body => 'hello');
    is($res->content, 'HELLO', 'and transformed chunk by chunk');
    is($res->header('content-type'), 'text/plain; charset=utf-8', 'as UTF-8 text');
    is($client->post('/shout', body => "caf\xc3\xa9 \xe2\x82\xac \xc2\xb5")->content,
        "CAF\xc3\x89 \xe2\x82\xac \xce\x9c", 'UTF-8 when no charset is declared');
    is($client->post('/shout', body => "caf\xe9",
            headers => { 'Content-Type' => 'text/plain; charset=ISO-8859-1' })->content,
        "CAF\xc3\x89", 'by the declared charset otherwise');
    is($client->post('/sha256', body => $body)->json,
        { bytes => length($body), sha256 => sha256_hex($body) }, 'and checksummed');
};

subtest '08: negotiation' => sub {
    my $client = PAGI::Test::Client->new(app => load_app('08-negotiation.pl'));

    my $res = $client->get('/note', headers => { Accept => 'application/json' });
    is($res->json, { id => 1, text => 'buy milk' }, 'JSON for an API client');

    $res = $client->get('/note', headers => { Accept => 'text/html;q=0.9, application/json;q=0.5' });
    is($res->text, '<h1>buy milk</h1>', 'HTML when it has the higher quality');

    is($client->get('/note', headers => { Accept => 'image/png' })->status, 406,
        'neither is a 406');

    for my $accept ('application/json', 'text/html', 'image/png', undef) {
        my $res = $client->get('/note', defined $accept ? (headers => { Accept => $accept }) : ());
        is($res->header('vary'), 'Accept', 'Vary: Accept for ' . ($accept // 'no Accept'));
    }
};

done_testing;
