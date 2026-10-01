#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/../examples/large-application/lib";
use PAGI::Test::Client;

plan skip_all => 'examples/large-application requires Perl 5.40' if $] < 5.040;
plan skip_all => 'examples/large-application requires Type::Tiny' unless eval { require Type::Tiny; 1 };

# The example, unchanged, served under the root path /app (as behind a proxy
# that strips it): its lifespan still runs, and every link it renders keeps
# the prefix and resolves when followed as a browser would.
my $app = do "$Bin/../examples/large-application/app.pl";
ok($app, 'app.pl loads') or diag($@ || $!);

my $client = PAGI::Test::Client->new(app => $app, lifespan => 1, root_path => '/app');
$client->start;
my $home = $client->get('/app/');
is($home->status, 200, 'home under /app, with its lifespan state');
my @hrefs = $home->text =~ m{<a href="([^"]*)">}g;
ok(scalar @hrefs, 'home renders links');
for my $href (@hrefs) {
    next if $href =~ m{\A[a-z][a-z0-9+.-]*:}i && $href !~ m{\Ahttp://testserver/};  # another site
    (my $target = $href) =~ s{\Ahttp://testserver(?=/)}{};
    $target =~ s/#.*\z//;
    like($target, qr{\A/app/}, "$href keeps the prefix");
    is($client->get($target)->status, 200, "$href resolves");
}
$client->stop;

done_testing;
