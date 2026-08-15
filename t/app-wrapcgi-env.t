use strict;
use warnings;

use Test2::V0;
use Future::AsyncAwait;
use FindBin;
use JSON::MaybeXS ();

use PAGI::App::WrapCGI;

{
    package TestWrapCGIStartFailure;
    use parent 'PAGI::App::WrapCGI';

    our $OPEN_CALLS = 0;

    sub _open_cgi {
        $OPEN_CALLS++;
        return (undef, undef);
    }
}

my $receive = sub { Future->done({ type => 'http.request', body => '', more => 0 }) };
my $fork_supported = eval {
    my $pid = fork;
    die "fork unavailable\n" unless defined $pid;
    exit if $pid == 0;
    waitpid($pid, 0);
    1;
};

SKIP: {
    skip 'fork not supported', 3 unless $fork_supported;

    my $app = PAGI::App::WrapCGI->new(
        script => "$FindBin::Bin/cgi-bin/env.cgi",
    )->to_app;

    my @sent;
    my $send = sub { my ($msg) = @_; push @sent, $msg; Future->done };

    $app->({
        type      => 'http',
        method    => 'GET',
        path      => '/info',
        root_path => '/cgi',
        headers   => [],
    }, $receive, $send)->get;

    is $sent[0]{status}, 200, 'CGI ran';
    like $sent[1]{body}, qr/SCRIPT_NAME=\/cgi;/,
        'SCRIPT_NAME comes from spec root_path';
    like $sent[1]{body}, qr/PATH_INFO=\/info/, 'PATH_INFO from path';
}

subtest 'process-start failure negotiates a Pages 500' => sub {
    $TestWrapCGIStartFailure::OPEN_CALLS = 0;

    my $failing_app = TestWrapCGIStartFailure->new(
        script => "$FindBin::Bin/cgi-bin/env.cgi",
    )->to_app;

    my @events;
    $failing_app->({
        type      => 'http',
        method    => 'GET',
        path      => '/info',
        root_path => '/cgi',
        headers   => [['Accept', 'application/json']],
    }, $receive, sub {
        push @events, $_[0];
        return Future->done;
    })->get;

    is $TestWrapCGIStartFailure::OPEN_CALLS, 1,
        'the overridable process starter is called once';
    is [map { $_->{type} } @events],
        ['http.response.start', 'http.response.body'],
        'process-start failure emits one complete HTTP response';
    is $events[0]{status}, 500, 'process-start failure remains 500';
    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    is $headers{'content-type'}, 'application/problem+json',
        'Accept negotiation selects problem JSON';
    is $headers{'cache-control'}, 'no-store', 'process-start failure is not stored';
    my $problem = JSON::MaybeXS::decode_json($events[1]{body});
    is $problem->{status}, 500, 'problem status matches the wire status';
};

done_testing;
