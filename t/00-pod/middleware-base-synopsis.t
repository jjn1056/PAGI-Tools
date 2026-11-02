use strict;
use warnings;
use Test2::V0;
use PAGI::Middleware;
use PAGI::Response qw(response);
use PAGI::Test::Client;

# PAGI::Middleware's SYNOPSIS runs as published: its middleware class loads
# through the builder and its app answers.
my $file = $INC{'PAGI/Middleware.pm'};
open my $fh, '<', $file or die "$file: $!";
my $pod = do { local $/; <$fh> };
my ($synopsis) = $pod =~ /^=head1 SYNOPSIS\n(.*?)^=head1 /ms;
ok defined $synopsis, 'the SYNOPSIS is found';
$synopsis =~ s/^    //mg;

our ($static_app, $my_app) = (response('Text', 'static'), response('Text', 'app'));
my $app = eval "no strict 'vars'; package main; $synopsis; \$app";
ok $app, 'the SYNOPSIS builds an app' or diag $@;

my $client = PAGI::Test::Client->new(app => $app, raise_app_exceptions => 1);
for my $path ('/', '/api/x') {
    my $res = $client->get($path);
    is $res->status, 200, "GET $path answers 200";
    is $res->text, 'app', "GET $path reaches the app";
}

done_testing;
