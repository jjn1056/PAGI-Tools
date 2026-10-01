use strict;
use warnings;
use Test2::V0;
use FindBin;

use PAGI::Test::Client;

# PAGI::Middleware::Session's SYNOPSIS, run exactly as published: its
# indented verbatim paragraphs, joined in order, build $app (the default
# cookie state and memory store) and $production (the cookie store with a
# configured cookie).

eval { require PAGI::Middleware::Session::Store::Cookie; 1 }
    or skip_all 'the SYNOPSIS uses PAGI::Middleware::Session::Store::Cookie, not installed';

my $pod = do {
    open my $fh, '<', "$FindBin::Bin/../../lib/PAGI/Middleware/Session.pm" or die $!;
    local $/;
    <$fh>;
};
my ($section) = $pod =~ /^=head1 SYNOPSIS\n(.*?)^=head1 /ms;
my $code = join "\n",
    map  { my $p = $_; $p =~ s/^    //mg; $p }
    grep { /\A[ \t]/ } split /\n{2,}/, ($section // '') =~ s/\A\n+//r;

local $ENV{STORE_SECRET}   = 'another-test-secret-at-least-32-bytes!';
my ($app, $production) = eval "package PAGITest::SessionSynopsis; $code; (\$app, \$production)";
is($@, '', 'the SYNOPSIS compiles and runs as published');

for my $case ([default => $app], [production => $production]) {
    my ($name, $built) = @$case;
    my $client = PAGI::Test::Client->new(app => $built);
    my $first = $client->get('/visits');
    is([$first->json->{visits}, $client->get('/visits')->json->{visits}], [1, 2],
        "$name: the session carries across requests");
    if ($name eq 'production') {
        like($first->header('set-cookie'), qr/HttpOnly.*Secure.*SameSite=Lax/,
            'production: the configured cookie keeps HttpOnly and adds Secure');
    }
}

done_testing;
