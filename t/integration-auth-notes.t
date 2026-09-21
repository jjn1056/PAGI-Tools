use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../examples/auth-notes/lib";
use Future;
use PAGI::Test::Client;

my $path = "$Bin/../examples/auth-notes/app.pl";
my $app = do $path;
ok(defined $app, 'Notes example loads') or do {
    diag($@ || $!);
    done_testing;
    exit;
};
isa_ok($app, 'PAGI::Compose');

my $store = NotesDemo::TokenStore->new;
my $notes = NotesDemo::Library->new;
my $client = PAGI::Test::Client->new(app => build_app($store, $notes));
sub bearer { return { Authorization => 'Bearer ' . $_[0] } }

for my $credential (undef, 'unknown') {
    my $res = $client->get('/notes',
        defined($credential) ? (headers => bearer($credential)) : ());
    is($res->status, 200, 'public notes survive absent or rejected credentials');
    is($res->json->{viewer}, 'Guest', 'public response displays Guest');
    is($res->header('WWW-Authenticate'), undef, 'public handler does not challenge');
}
my $missing = $client->get('/me');
is($missing->status, 401, 'identity route challenges absence');
is($missing->header('WWW-Authenticate'), 'Bearer realm="notes"', 'absence has no wire error');
my $rejected = $client->get('/me', headers => bearer('unknown'));
is($rejected->status, 401, 'identity route rejects unknown token');
like($rejected->header('WWW-Authenticate'), qr/error="invalid_token"/, 'rejection has wire error');
for my $row (['alice-reader', 'alice', 'Alice'], ['export-service', 'export-bot', 'Note exporter']) {
    my $res = $client->get('/me', headers => bearer($row->[0]));
    is($res->status, 200, "$row->[0] has an authenticated user");
    is($res->json->{user_id}, $row->[1], 'identity comes from trusted record');
    is($res->json->{display_name}, $row->[2], 'trusted display name');
}
my $before = $notes->all_published->get;
my $count = @$before;

# Observe calls at the application-owned publisher boundary, retaining real storage.
my $publish_calls = 0;
my $publish = NotesDemo::Library->can('publish');
{
    no warnings qw(redefine once);
    local *NotesDemo::Library::publish = sub { ++$publish_calls; $publish->(@_) };
    for my $token ('alice-reader', 'write-only', 'unknown') {
        my $res = $client->post('/notes', headers => bearer($token), json => {text => 'Denied'});
        is($res->status, $token eq 'unknown' ? 401 : 403, "$token cannot publish");
        if ($token ne 'unknown') {
            like($res->header('WWW-Authenticate'), qr/error="insufficient_scope"/, 'denial explains missing grant');
            like($res->header('WWW-Authenticate'), qr/scope="notes:read notes:write"/, 'requires both grants');
        }
    }
    for my $data ({}, {text => ''}, {text => []}, []) {
        my $res = $client->post('/notes', headers => bearer('alice-editor'), json => $data);
        is($res->status, 400, 'invalid note input is refused before publication');
    }
    is($publish_calls, 0, 'denied requests never invoke publishing service');
    for my $token ('alice-editor', 'read-write') {
        my $res = $client->post('/notes', headers => bearer($token),
            json => {text => "Published by $token", author_id => 'mallory'});
        is($res->status, 201, "$token can publish (no named authenticated grant required)");
        is($res->json->{author_id}, 'alice', 'author comes from user, not request JSON');
        is($res->json->{text}, "Published by $token", 'note text is stored');
    }
    is($publish_calls, 2, 'only permitted requests call publisher');
}
is(scalar @{$notes->all_published->get}, $count + 2, 'exactly two public notes added');
my $public = $client->get('/notes', headers => bearer('alice-reader'));
is($public->json->{viewer}, 'Alice', 'public endpoint can display authenticated viewer');
is(scalar @{$public->json->{notes}}, $count + 2, 'published notes are publicly listed');

for my $row (['export-service', 200], ['case-reader', 403], ['no-scopes', 403]) {
    my $res = $client->get('/notes/export', headers => bearer($row->[0]));
    is($res->status, $row->[1], "$row->[0] export uses exact read grant");
    like($res->header('WWW-Authenticate'), qr/error="insufficient_scope"/, 'export denial challenges scope')
        if $row->[1] == 403;
}
my $export_me = $client->get('/me', headers => bearer('export-service'));
is($export_me->json->{scopes}, ['notes:read'], 'authenticated user does not add a named grant');
for my $headers (
    [['Authorization', 'Bearer alice-editor'], ['Authorization', 'Bearer alice-reader']],
    { Authorization => 'Bearer first second' },
) {
    my $res = $client->get('/me', headers => $headers);
    is($res->status, 400, 'duplicate or malformed Authorization uses application 400');
    like($res->header('WWW-Authenticate'), qr/error="invalid_request"/, 'malformed header wire error');
    is($client->get('/notes', headers => $headers)->status, 200, 'malformed credentials do not close public route');
}
my $other = $client->get('/me', headers => { Authorization => 'Basic abc' });
is($other->header('WWW-Authenticate'), 'Bearer realm="notes"', 'another scheme remains an ordinary guest');

# Use the actual backend outside Compose to see failed Futures before its 500 boundary.
my $authentication = build_authentication($store);
my $backend_reads = 0;
my $header_all = PAGI::Request->can('header_all');
my $direct = $authentication->wrap(sub { Future->done });
my $receive = sub { Future->done({type => 'http.request', body => '', more_body => 0}) };
my $send = sub { die 'authentication failure must not emit HTTP' };
{
    no warnings qw(redefine once);
    local *PAGI::Request::header_all = sub { ++$backend_reads; $header_all->(@_) };
    for my $headers ([], [['authorization', 'Bearer unknown']]) {
        $direct->({type => 'http', headers => $headers}, $receive, $send)->get;
    }
}
is($backend_reads, 2, 'actual backend reads headers for missing and rejected credentials');
{
    no warnings qw(redefine once);
    local *NotesDemo::TokenStore::find_active = sub { Future->fail('token storage unavailable', 'storage') };
    like(dies {
        $direct->({type => 'http', headers => [['authorization', 'Bearer alice-reader']]}, $receive, $send)->get;
    }, qr/token storage unavailable/, 'operational store failure propagates without a 401 response');
}

done_testing;
