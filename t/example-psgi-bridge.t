use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use PAGI::Test::Client;

# A legacy PSGI application running inside a PAGI-Tools application: wrapped
# once, then placed on an ordinary route beside native routes.

my $file = "$Bin/../examples/09-psgi-bridge/app.pl";
my $source = do { open my $fh, '<', $file or die "$file: $!"; local $/; <$fh> };

like($source, qr/compose\(/, 'the PSGI app is part of a compose');
like($source, qr/route\('\/\*path'\s*=>\s*PAGI::App::WrapPSGI->new\(psgi_app\s*=>\s*\$psgi_app\),\s*methods\s*=>\s*'\*'\)/,
    'on an HTTP catch-all route that hands every method to the PSGI app');

my $app = do $file;
is($@, '', 'the example loads');
isa_ok($app, 'PAGI::Compose');

my $client = PAGI::Test::Client->new(app => $app);
is($client->get('/health')->json, { ok => 1 }, 'a native route answers beside it');
my $res = $client->get('/anything');
is($res->status, 200, 'other paths reach the PSGI app');
like($res->text, qr/PSGI says hi/, 'which answers');
like($client->post('/submit', body => 'hello')->text, qr/Body: hello/,
    'and reads the request body through psgi.input');

done_testing;
