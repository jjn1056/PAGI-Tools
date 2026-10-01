use strict;
use warnings;
use Test2::V0;
use lib 'lib';
use PAGI::App::WrapPSGI;
use PAGI::Compose qw(compose);
use PAGI::Routing qw(mount);
use PAGI::Test::Client;

# A wrapped PSGI app sees PSGI's split: SCRIPT_NAME and PATH_INFO as bytes,
# and REQUEST_URI as the URI the client requested.

my %env;
my $psgi = PAGI::App::WrapPSGI->new(psgi_app => sub {
    my ($e) = @_;
    %env = map { $_ => $e->{$_} } qw(SCRIPT_NAME PATH_INFO REQUEST_URI);
    return [200, ['Content-Type' => 'text/plain'], ['ok']];
});
my $client = PAGI::Test::Client->new(app => compose(routes => [mount('/legacy', app => $psgi)]));

is($client->get('/legacy/caf%C3%A9/a%2Fb?y=1')->status, 200, 'the request reaches the PSGI app');
is(\%env, {
    SCRIPT_NAME => '/legacy',
    PATH_INFO   => "/caf\xC3\xA9/a/b",
    REQUEST_URI => '/legacy/caf%C3%A9/a%2Fb?y=1',
}, 'bytes, not characters, and REQUEST_URI present');
ok(!utf8::is_utf8($env{PATH_INFO}), 'PATH_INFO carries no character semantics');

SKIP: {
    skip 'Plack::Request not installed', 1 unless eval { require Plack::Request; 1 };
    my %captured;
    my $plack = PAGI::App::WrapPSGI->new(psgi_app => sub {
        $captured{uri} = Plack::Request->new($_[0])->uri->as_string;
        return [200, [], ['ok']];
    });
    PAGI::Test::Client->new(app => compose(routes => [mount('/legacy', app => $plack)]))
        ->get('/legacy/%E6%97%A5?q=1', headers => { Host => 'example.com' });
    is($captured{uri}, 'http://example.com/legacy/%E6%97%A5?q=1', 'Plack::Request->uri works on a CJK path');
}

done_testing;
