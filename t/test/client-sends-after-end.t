use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use PAGI::Test::Client;
use Test::Lib;
use PAGITest::LowercaseHeaders;

# PAGI::Spec 0.6, "Send Completion Contract": once a scope has ended, a send
# does no work and resolves successfully on a later turn of the event loop,
# never within the call to $send. The test client keeps that rule, as a
# server does.

# The start each kind of scope sends, and a send of its own kind.
my %KIND = (
    http      => [ { type => 'http.response.start', status => 200, headers => [] },
                   { type => 'http.response.body', body => 'late', more => 1 } ],
    websocket => [ { type => 'websocket.accept' },
                   { type => 'websocket.send', text => 'late' } ],
    sse       => [ { type => 'sse.start', status => 200 },
                   { type => 'sse.send', data => 'late' } ],
);

for my $type (qw(http websocket sse)) {
    subtest "$type: a send after the scope has ended settles on a later turn" => sub {
        my %seen;
        my $app = async sub {
            my ($scope, $receive, $send) = @_;
            await $receive->() unless $type eq 'http';   # the scope's opening event
            await $send->($KIND{$type}[0]);
            $scope->{'pagi.connection'}->abort('gave up');
            my $late = $seen{late} = $send->($KIND{$type}[1]);
            $seen{settled_in_call} = $late->is_ready ? 1 : 0;
            await $late;
            $seen{returned} = 1;
        };
        my $client = PAGI::Test::Client->new(app => $app);
        if    ($type eq 'http')      { $client->get('/') }
        elsif ($type eq 'websocket') { $client->websocket('/') }
        else                         { $client->sse('/') }
        $seen{late}->get;   # a later turn of the event loop
        is $seen{settled_in_call}, 0, 'the send did not settle within the call';
        ok $seen{late}->is_done, 'it settled later, successfully';
        ok $seen{returned}, 'and the application went on';
    };
}

subtest 'every scope reports PAGI core 0.6' => sub {
    my %version;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $version{ $scope->{type} } = $scope->{pagi}{version};
        await $receive->() unless $scope->{type} eq 'http';
        await $send->($KIND{ $scope->{type} }[0]);
        await $send->({ type => 'http.response.body', body => '', more => 0 }) if $scope->{type} eq 'http';
    };
    my $client = PAGI::Test::Client->new(app => $app);
    $client->get('/');
    $client->websocket('/')->close;
    $client->sse('/')->close;
    is \%version, { http => '0.6', websocket => '0.6', sse => '0.6' }, 'version 0.6';
};

done_testing;
