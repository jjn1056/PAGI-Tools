use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Future::IO;
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

# An application that keeps sending once its client has gone forgot to run
# its work in run_until_end; the test client says so, once. The idiom (the
# work in run_until_end, the terminal event only when it finished) sends at
# most once after the end.
subtest 'a stream that keeps sending after the client left is warned about, once' => sub {
    my $naive = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        for my $n (1 .. 50) {
            await $send->({ type => 'http.response.body', body => "x\n", more => 1 });
            await Future::IO->sleep(0.001);   # made over time, as a stream is
        }
        await $send->({ type => 'http.response.body', body => '', more => 0 });
    };
    my $warnings = warnings {
        my $stream = PAGI::Test::Client->new(app => $naive)->stream('/');
        $stream->receive_chunk;
        $stream->close;
    };
    is scalar @$warnings, 1, 'one warning';
    like $warnings->[0], qr/kept sending after the scope ended.*run_until_end/s, 'naming the fix';
};

subtest 'the run_until_end idiom is not warned about' => sub {
    my $raced = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        my $completed = await $scope->{'pagi.connection'}->run_until_end(async sub {
            for my $n (1 .. 50) {
                await $send->({ type => 'http.response.body', body => "x\n", more => 1 });
                await Future::IO->sleep(0.001);
            }
        });
        return unless $completed;
        await $send->({ type => 'http.response.body', body => '', more => 0 });
    };
    my $warnings = warnings {
        my $stream = PAGI::Test::Client->new(app => $raced)->stream('/');
        $stream->receive_chunk;
        $stream->close;
    };
    is $warnings, [], 'no warning';
};

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
