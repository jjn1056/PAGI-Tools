use strict;
use warnings;
use Test2::V0;

BEGIN {
    if ($] < 5.040) {
        plan skip_all => 'Auth cookbook example requires Perl 5.40';
        exit;
    }
}

use PAGI::Test::Client;
use PAGI::Compose qw(compose);
use PAGI::Routing qw(mount);

open my $pod, '<', 'lib/PAGI/Auth.pm' or die "Cannot read Auth POD: $!";
my $source = do { local $/; <$pod> };
close $pod;

my $heading = '=head2 Protecting a group of endpoints';
my $start = index $source, $heading;
die "Auth cookbook section is missing" if $start < 0;
my @lines = split /\n/, substr($source, $start + length($heading));
my (@block, $started);
for my $line (@lines) {
    if (!$started) {
        next unless $line =~ /^  \S/;
        $started = 1;
    }
    last if length($line) && $line !~ /^  /;
    push @block, length($line) ? substr($line, 2) : '';
}
pop @block while @block && $block[-1] eq '';
die "Auth cookbook code block is missing" unless @block;

my $example = join("\n", @block) . "\n";
my $app = eval "package AuthCookbookFixture;\n" . $example;
ok !$@, 'published group-protection recipe compiles' or diag $@;
ok $app->isa('PAGI::Compose'), 'recipe returns an ordinary application';

my $protected_group = $app->routes->[1]->app;
my $descriptors = $protected_group->middleware;
is scalar @$descriptors, 2, 'Authentication runs before the protection wrapper';
my $plain_group = compose(
    middleware => [$descriptors->[0]],
    routes => $protected_group->routes,
);
my $plain = compose(routes => [
    $app->routes->[0],
    mount('/', app => $plain_group),
]);

my $client_after_stop;
PAGI::Test::Client->run($app, sub {
    my ($client) = @_;
    $client_after_stop = $client;
    is $client->state->{ready}, 1, 'startup callback ran';
    my $missing = $client->get('/one');
    is $missing->status, 401, 'first route refuses a guest';
    is $missing->header('WWW-Authenticate'), 'Bearer realm="example"',
        'missing credentials have no Bearer error';
    is $client->get('/two')->status, 401, 'second route refuses a guest';
    is $client->get('/public')->status, 200, 'public route stays open';
    my $unsupported = $client->get('/one', headers => {
        Authorization => 'Basic YWRhOnRlc3Q=',
    });
    is $unsupported->status, 401, 'unsupported scheme remains a guest';
    is $unsupported->header('WWW-Authenticate'), 'Bearer realm="example"',
        'unsupported scheme has no Bearer error';
    for my $path (qw(/one /two)) {
        is $client->get($path, headers => { Authorization => 'Bearer accepted' })->status,
            200, "$path accepts the documented credential";
        my $rejected = $client->get($path, headers => {
            Authorization => 'Bearer rejected',
        });
        is $rejected->status,
            401, "$path refuses rejected credentials";
        is $rejected->header('WWW-Authenticate'),
            'Bearer realm="example", error="invalid_token"',
            "$path identifies rejected Bearer credentials";
    }
    my $malformed = $client->get('/one', headers => {
        Authorization => 'Bearer first second',
    });
    is $malformed->status, 400, 'malformed Bearer syntax is a bad request';
    is $malformed->header('WWW-Authenticate'),
        'Bearer realm="example", error="invalid_request"',
        'malformed syntax receives invalid_request';
    my $duplicate = $client->get('/one', headers => [
        ['Authorization', 'Bearer rejected'],
        ['Authorization', 'Bearer accepted'],
    ]);
    is $duplicate->status, 400, 'duplicate fields cannot select accepted token';
    is $duplicate->header('WWW-Authenticate'),
        'Bearer realm="example", error="invalid_request"',
        'duplicate fields receive invalid_request';
});
is $client_after_stop->state->{ready}, 0, 'shutdown callback ran';

PAGI::Test::Client->run($plain, sub {
    my ($client) = @_;
    is $client->get('/one')->status, 200, 'first route is open without protection';
    is $client->get('/two')->status, 200, 'second route is open without protection';
});

done_testing;
