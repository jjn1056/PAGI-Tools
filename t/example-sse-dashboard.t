use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use PAGI::Test::Client;

# The SSE dashboard: one broadcaster pushes the same metrics to every
# subscribed client. The handler receives one PAGI::SSE; no event loop is
# named in the application.

my $file = "$Bin/../examples/sse-dashboard/app.pl";
my $source = do { open my $fh, '<', $file or die "$file: $!"; local $/; <$fh> };

like($source, qr/sse\('\/events'\s*=>\s*\\&events\)/, 'an SSE route takes the one-$sse handler');
like($source, qr/async sub events \{\s*my \(\$sse\) = \@_;/, 'the handler receives one PAGI::SSE');
like($source, qr/route\('\/\*path'\s*=>\s*PAGI::App::File->from_app_path\('public'\)\)/,
    'static files are an HTTP catch-all route');
unlike($source, qr/IO::Async/, 'no event loop named');
unlike($source, qr/PAGI::SSE->new|\(\$scope,\s*\$receive,\s*\$send\)|as_app_object/,
    'no raw PAGI application');

my ($app, $stderr) = (undef, '');
{
    local *STDERR;
    open STDERR, '>', \$stderr or die $!;
    $app = do $file;
}
is($@, '', 'the example loads');
isa_ok($app, 'PAGI::Compose');

my $client = PAGI::Test::Client->new(app => $app);
is($client->get('/')->status, 200, 'the dashboard page is served');

{
    local *STDERR;
    open STDERR, '>', \$stderr or die $!;
    $client->sse('/events', sub {
        my ($sse) = @_;
        my $hello = $sse->receive_event;
        is($hello->{event}, 'connected', 'a client is welcomed');
        like($hello->{data}, qr/"subscriber_id"/, 'with its subscriber id');
    });

    $client->sse('/events', headers => { 'Last-Event-ID' => '41' }, sub {
        my ($sse) = @_;
        is($sse->receive_event->{event}, 'connected', 'a reconnecting client is welcomed');
        my $again = $sse->receive_event;
        is($again->{event}, 'reconnected', 'and told it reconnected');
        like($again->{data}, qr/"last_id":"?41"?/, 'from the id it last saw');
    });
}
like($stderr, qr/SSE client \d+ connected/, 'connections are logged');
like($stderr, qr/SSE client \d+ disconnected/, 'and cleaned up on disconnect');

done_testing;
