use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/../examples/endpoint-lifecycle/lib";

BEGIN { plan skip_all => 'examples/endpoint-lifecycle requires Perl 5.40' if $] < 5.040 }

use Future;
use JSON::MaybeXS ();
use PAGI::Test::Client;

# One endpoint() spelling, three lifecycles: classes built fresh per request
# or connection (no BUILD_APP), a per-request builder, and one shared object.

# The application is a module: loading it builds nothing until a server (or
# the test client) asks for the application.
my $app = do "$Bin/../examples/endpoint-lifecycle/lib/NotesApp.pm" or die $@ || $!;
can_ok $app, 'to_app';

# Counts NotesApp::Notes constructions; the real constructor still runs.
# endpoint() runs when the application is built, so the class is loaded here
# first; endpoint() then uses it as defined.
my $notes_built = 0;
{
    require NotesApp::Notes;
    no strict 'refs';
    no warnings qw(redefine once);
    my $new = NotesApp::Notes->can('new');
    *{'NotesApp::Notes::new'} = sub { $notes_built++; goto &$new };
}

PAGI::Test::Client->run($app, sub {
    my ($client) = @_;

    my $res = $client->get('/notes');
    is [$res->status, $res->json], [200, []], 'GET /notes: empty';
    is $res->header('X-Page-Size'), 50, 'route config reached the per-request object';

    $res = $client->post('/notes', json => { text => 'buy milk' }, headers => { 'X-User' => 'alice' });
    is [$res->status, $res->header('Location')], [201, '/notes/1'], 'POST /notes: 201 with Location';
    is $notes_built, 2, 'one NotesApp::Notes per request';

    is $client->get('/notes/1')->json, { id => 1, text => 'buy milk', author => 'alice' },
        'GET /notes/1 from a plain-Perl per-request class';
    is $client->get('/notes/99')->status, 404, 'GET /notes/99 is a 404';

    $res = $client->put('/notes');
    is [$res->status, $res->header('Allow')], [405, 'GET, HEAD, OPTIONS, POST'],
        'PUT /notes: the Router answers 405 from the class';
    is $notes_built, 2, 'no object was built for the 405';
    is $client->options('/notes/1')->header('Allow'), 'DELETE, GET, HEAD, OPTIONS',
        'automatic OPTIONS reaches the endpoint';
    $res = $client->head('/notes/1');
    is [$res->status, $res->content], [200, ''], 'HEAD is answered by get, without a body';

    is $client->get('/health')->json, { status => 'ok', version => '1.0', hits => 1 }, 'health once';
    is $client->get('/health')->json, { status => 'ok', version => '1.0', hits => 2 },
        'health twice: the same object';

    my $a = $client->websocket('/watch');
    my $b = $client->websocket('/watch');
    is $a->receive_json, { type => 'hello', greeting => 'welcome', delivered => 1 }, 'a: hello';
    is $b->receive_json, { type => 'hello', greeting => 'welcome', delivered => 1 }, 'b: hello';
    $a->send_json({ op => 'add', text => 'from a' });
    is $a->receive_json->{delivered}, 2, 'a: second message';
    $a->send_json({ op => 'list' });
    my $list = $a->receive_json;
    is [$list->{delivered}, scalar $list->{notes}->@*, $list->{notes}[1]{author}],
        [3, 2, 'watcher'], 'a: third message lists both notes';
    $b->send_json({ op => 'list' });
    is $b->receive_json->{delivered}, 2, 'b keeps its own count';
    $a->close;
    $b->close;
    is $client->state->{notes}->watch_log, [3, 2], "on_disconnect saw each connection's own state";

    is [map { $client->get("/notes/$_")->json->{text} } 1, 2], ['buy milk', 'from a'],
        "NotesApp::Note, no BUILD_APP, keeps each request's note on its own object";

    is $client->delete('/notes/1')->status, 204, 'DELETE /notes/1';
    is $client->delete('/notes/1')->status, 404, 'DELETE again is a 404';
});

subtest 'overlapping per-request objects do not share state' => sub {
    my $code = $app->to_app;
    my $before = $notes_built;
    my $store = NotesApp::Store->new;
    my %body = (alice => Future->new, bob => Future->new);
    my %events;
    my %done = map {
        my $user = $_;
        $user => $code->(
            {
                type => 'http', method => 'POST', path => '/notes', root_path => '',
                query_string => '', state => { notes => $store },
                headers => [['x-user', $user], ['content-type', 'application/json']],
            },
            sub { $body{$user} },
            sub { push @{ $events{$user} }, $_[0]; Future->done },
        );
    } keys %body;
    is $notes_built - $before, 2, 'both objects exist before either body arrives';
    ok !$done{alice}->is_ready && !$done{bob}->is_ready, 'both requests in flight';
    $body{bob}->done({ type => 'http.request', body => '{"text":"from bob"}', more => 0 });
    $body{alice}->done({ type => 'http.request', body => '{"text":"from alice"}', more => 0 });
    Future->needs_all(values %done)->get;
    my %note = map {
        $_ => JSON::MaybeXS::decode_json(join '', map { $_->{body} // '' } @{ $events{$_} })
    } keys %events;
    is $note{alice}, { id => 2, text => 'from alice', author => 'alice' }, 'alice answered with alice';
    is $note{bob},   { id => 1, text => 'from bob',   author => 'bob'   }, 'bob answered with bob';
};

done_testing;
