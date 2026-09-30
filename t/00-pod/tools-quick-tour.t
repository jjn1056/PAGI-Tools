use strict;
use warnings;
use Test2::V0;
use FindBin;

use PAGI::Test::Client;

# The README is generated from PAGI::Tools' POD, so its "A QUICK TOUR" code is
# the first program most people run. Execute it exactly as published and check
# what the surrounding prose promises.

my $pod = do {
    open my $fh, '<', "$FindBin::Bin/../../lib/PAGI/Tools.pm" or die "Tools.pm: $!";
    local $/;
    <$fh>;
};

my ($section) = $pod =~ /^=head1 A QUICK TOUR\n(.*?)^=head1 /ms;
ok defined $section, 'the POD has a QUICK TOUR section' or bail_out('no tour');

# The tour's code is its indented verbatim paragraphs, joined in order.
my $code = join "\n",
    grep { /\S/ }
    map  { my $p = $_; $p =~ s/^    //mg; $p }
    grep { /\A {4}\S/ } split /\n{2,}/, $section;

my $app = eval "package PAGITest::QuickTour; $code; \$app";
is $@, '', 'the tour compiles and runs as published';

my $client = PAGI::Test::Client->new(app => $app);

my $res = $client->get('/people/7');
is [$res->status, $res->json], [200, { id => 7 }], 'the JSON route answers';

$res = $client->get('/export');
is $res->header('content-type'), 'application/x-ndjson', 'the export streams NDJSON';
is $res->text, qq{{"n":1}\n{"n":2}\n{"n":3}\n}, 'one record per line';

$client->websocket('/echo', sub {
    my ($ws) = @_;
    $ws->send_text('hi');
    is $ws->receive_text, 'echo: hi', 'the WebSocket route echoes';
});

is $client->get('/nope')->status, 404, 'an unmatched path answers 404';
$res = $client->post('/people/7');
is $res->status, 405, 'a wrong method answers 405';
like $res->header('allow'), qr/\bGET\b/, 'with an Allow header';

done_testing;
