#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use JSON::MaybeXS ();
use IO::Socket::INET;
use POSIX ();

use lib 'lib';

use PAGI::App::Proxy;

# Spawns a one-shot real TCP backend in a forked child: it accepts a single
# connection, captures the raw request bytes it received, writes a canned
# response, then exits. The parent runs the proxy app against it for real
# (no socket mocking), so wire framing -- protocol version, Connection
# header, hop-by-hop stripping -- is observed exactly as a real backend
# would see and send it.
sub run_proxy_against_backend {
    my (%opts) = @_;
    my $response = $opts{response};
    my $client_headers = $opts{client_headers} // [];

    my $listener = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Listen    => 5,
        ReuseAddr => 1,
        Proto     => 'tcp',
    ) or die "can't create backend listener: $!";
    my $port = $listener->sockport;

    pipe(my $from_child, my $to_parent) or die "pipe failed: $!";

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        close $from_child;
        my $client = $listener->accept;
        local $/ = "\r\n\r\n";
        my $request = <$client>;
        print { $to_parent } $request;
        close $to_parent;
        print { $client } $response;
        close $client;
        close $listener;
        POSIX::_exit(0);
    }

    close $to_parent;
    close $listener;

    my $app = PAGI::App::Proxy->new(backend => "http://127.0.0.1:$port")->to_app;
    my @events;
    my $receive = sub { Future->done({ type => 'http.request', body => '', more => 0 }) };
    my $send = sub { push @events, $_[0]; Future->done };

    $app->({
        type         => 'http',
        method       => 'GET',
        path         => '/',
        query_string => '',
        headers      => $client_headers,
    }, $receive, $send)->get;

    my $captured_request = do { local $/; <$from_child> };
    close $from_child;
    waitpid($pid, 0);

    return (\@events, $captured_request);
}

{
    package TestProxyConnectFailure;
    use parent 'PAGI::App::Proxy';

    our @CONNECT_ARGS;

    sub _connect_backend {
        my ($self, @args) = @_;
        @CONNECT_ARGS = @args;
        return;
    }
}

subtest 'backend connection failure negotiates a Pages 502' => sub {
    @TestProxyConnectFailure::CONNECT_ARGS = ();

    my $app = TestProxyConnectFailure->new(
        backend => 'http://127.0.0.1:0',
        timeout => 7,
    )->to_app;

    my @events;
    my $receive = sub {
        Future->done({ type => 'http.request', body => '', more => 0 });
    };
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };

    $app->({
        type         => 'http',
        method       => 'GET',
        path         => '/',
        query_string => '',
        headers      => [['Accept', 'application/json']],
    }, $receive, $send)->get;

    is \@TestProxyConnectFailure::CONNECT_ARGS, ['127.0.0.1', 0, 7],
        'the overridable connector receives the configured backend';
    is [map { $_->{type} } @events],
        ['http.response.start', 'http.response.body'],
        'connection failure emits one complete HTTP response';
    is $events[0]{status}, 502, 'connection failure remains 502';

    my %headers = map { lc($_->[0]) => $_->[1] } @{$events[0]{headers}};
    is $headers{'content-type'}, 'application/problem+json',
        'Accept negotiation selects problem JSON';
    is $headers{'cache-control'}, 'no-store',
        'the generic backend failure is not stored';
    is $headers{vary}, 'Accept', 'negotiation retains Vary: Accept';

    my $problem = JSON::MaybeXS::decode_json($events[1]{body});
    is $problem->{status}, 502, 'problem document status matches the wire status';
    is $problem->{title}, 'Bad Gateway', 'problem document uses the stock title';
};

subtest 'client request headers are dehopped before forwarding' => sub {
    my (undef, $request) = run_proxy_against_backend(
        response => "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok",
        client_headers => [
            ['Connection', 'keep-alive, X-Session'],
            ['X-Session', 'drop-me-too'],
            ['Transfer-Encoding', 'chunked'],
            ['TE', 'trailers'],
            ['Keep-Alive', 'timeout=5'],
            ['Accept', 'text/plain'],
        ],
    );

    my ($request_line, $header_block) = split /\r\n/, $request, 2;
    is $request_line, 'GET / HTTP/1.0',
        'the backend request line is downgraded to HTTP/1.0';

    my @header_lines = split /\r\n/, $header_block;
    is [ grep { /^connection:/i } @header_lines ], ['Connection: close'],
        'exactly one Connection header, added by the proxy, reaches the backend';
    is [ grep { /^(x-session|te|transfer-encoding|keep-alive):/i } @header_lines ], [],
        'hop-by-hop headers and the Connection-named header are dropped';
    is [ grep { /^accept:/i } @header_lines ], ['Accept: text/plain'],
        'ordinary headers are still forwarded';
};

subtest 'backend response headers are dehopped before http.response.start' => sub {
    my ($events) = run_proxy_against_backend(
        response => "HTTP/1.1 200 OK\r\n"
            . "Connection: keep-alive\r\n"
            . "Transfer-Encoding: chunked\r\n"
            . "Keep-Alive: timeout=5\r\n"
            . "Content-Type: text/plain\r\n"
            . "\r\n"
            . "ok",
    );

    is $events->[0]{type}, 'http.response.start', 'response start was sent';
    my %resp_headers = map { lc($_->[0]) => $_->[1] } @{ $events->[0]{headers} };
    ok !exists $resp_headers{connection}, 'Connection is stripped from the response';
    ok !exists $resp_headers{'transfer-encoding'}, 'Transfer-Encoding is stripped from the response';
    ok !exists $resp_headers{'keep-alive'}, 'Keep-Alive is stripped from the response';
    is $resp_headers{'content-type'}, 'text/plain', 'ordinary response headers still pass through';
};

done_testing;
