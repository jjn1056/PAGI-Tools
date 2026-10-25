use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";

BEGIN { plan skip_all => 'examples/signed-requests requires Perl 5.40' if $] < 5.040 }

use Digest::SHA qw(hmac_sha256_hex sha256_hex);
use Future;
use PAGI::Test::Client;

# A middleware checks a signature over the body as the routes read it -- a
# JSON event through PAGI::Request, an artifact streamed to disk -- and
# fails the read of the last chunk when the signature does not cover it.
# Test::Client sends a body as one event; a forged artifact sent in chunks
# leaving nothing on disk is t/integration/example-signed-requests-chunked.t.

local $ENV{SIGNING_SECRET} = 'test-secret';
my $app = do "$Bin/../examples/signed-requests/app.pl" or die $@ || $!;
my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
$client->start;

sub signed {
    my ($body, $secret) = @_;
    return { 'X-Signature' => 'sha256=' . hmac_sha256_hex(sha256_hex($body), $secret // 'test-secret') };
}

my $event = '{"build":42,"status":"passed"}';
my $res = $client->post('/signed/events', body => $event,
    headers => { %{ signed($event) }, 'Content-Type' => 'application/json' });
is $res->status, 202, 'a signed event is accepted';
is $res->json, { ok => 1, build => 42 }, 'read as JSON after the check';

is $client->post('/signed/events', body => $event)->status, 401, 'an unsigned event is refused';
is $client->post('/signed/events', body => $event, headers => signed($event, 'wrong'))->status, 401,
    'so is one signed with another secret';
is $client->post('/signed/events', body => 'not json', headers => signed('not json'))->status, 400,
    'a signed body that is not JSON is the stock 400';
is $client->get('/signed/events')->status, 401, 'a request without a signature is refused before the router';
is $client->get('/signed/events', headers => { 'X-Signature' => 'sha256=forged' })->status, 405,
    'a forged header on a request whose route reads no body is not checked: the router answers';
is $client->get('/events')->json, [{ build => 42, status => 'passed' }], 'only the signed event was recorded';

for my $case (['small', join('', map { chr } 0 .. 255) x 4], ['large', join('', map { chr($_ % 256) } 0 .. 2_000_000)]) {
    my ($size, $bytes) = @$case;
    $res = $client->post('/signed/artifacts/build.tar', body => $bytes, headers => signed($bytes));
    is $res->status, 201, "a signed $size artifact is accepted";
    is $res->json, { bytes => length $bytes, sha256 => sha256_hex($bytes) }, 'and stored exactly as signed';
}

my $bytes = join '', map { chr($_ % 256) } 0 .. 2_000_000;
$res = $client->post('/signed/artifacts/evil.tar', body => $bytes, headers => signed($bytes, 'wrong'));
is [$res->status, $res->json], [401, { error => 'bad signature' }], 'a forged artifact is refused';

$client->stop;

subtest "a route's own 401 is not taken for a bad signature" => sub {
    require PAGI::Exception::HTTP;
    my $wrapped = SignedRequests::VerifySignature->new(secret => 'test-secret')->wrap(sub {
        PAGI::Exception::HTTP->throw(401, 'log in first');
    });
    my $error = dies {
        $wrapped->({ type => 'http', method => 'GET', path => '/', headers => [['x-signature', 'sha256=x']] },
            sub { Future->done({ type => 'http.disconnect' }) }, sub { Future->done })->get;
    };
    isa_ok($error, ['PAGI::Exception::HTTP'], 'it propagates');
    is($error->client_message, 'log in first', 'as the route threw it');
};

done_testing;
