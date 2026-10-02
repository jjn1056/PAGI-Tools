use strict;
use warnings;

use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use PAGI::Test::Client;

# Ending an SSE stream explicitly: progress events, a client-facing 'done'
# sentinel, then close(reason => ...) with a reason the server logs.

my $file = "$Bin/../examples/sse-close/app.pl";
my $source = do { open my $fh, '<', $file or die "$file: $!"; local $/; <$fh> };

like($source, qr/sse\('\/jobs'\s*=>\s*\\&jobs\)/, 'an SSE route takes the one-$sse handler');
like($source, qr/route\('\/'\s*=>\s*response\('HTML', \$PAGE\)\)/, 'the page is a Response value on a route');
unlike($source, qr/Future::IO::Impl/, 'the application binds no Future::IO implementation');
unlike($source, qr/PAGI::SSE->new|\(\$scope,\s*\$receive,\s*\$send\)|type\s*=>\s*'http\.response/,
    'no raw PAGI application or hand-built response');

my $app = do $file;
is($@, '', 'the example loads');
isa_ok($app, 'PAGI::Compose');

my $client = PAGI::Test::Client->new(app => $app);
my $page = $client->get('/');
is($page->status, 200, 'the page is served');
like($page->text, qr/<title>PAGI SSE close demo<\/title>/, 'as HTML');
is($client->get('/')->status, 200, 'and the same Response value serves it again');

# PAGI::Test::Client does not run an event loop, so it cannot wait out the
# handler's Future::IO sleeps; it checks the stream's start here. The whole
# sequence (four progress events, done, close with its logged reason) is
# exercised under pagi-server.
my $closed = '';
{
    local *STDERR;
    open STDERR, '>', \$closed or die $!;
    $client->sse('/jobs', sub {
        my ($sse) = @_;
        my $first = $sse->receive_event;
        is($first->{event}, 'progress', 'the stream starts with a progress event');
        like($first->{data}, qr/"pct":\s*25/, 'at 25%');
    });
}
is($closed, "SSE stream closed: client_closed\n",
    'a client leaving early is reported with the server-supplied reason');

done_testing;
