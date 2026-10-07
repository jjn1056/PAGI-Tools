use strict;
use warnings;

use Test2::V0;
use Future;
use Future::AsyncAwait;
use FindBin;
use File::Temp qw(tempdir);
use JSON::MaybeXS ();
use Time::HiRes qw(time);

plan skip_all => 'WrapCGI forks and uses non-blocking pipes, unsupported on Windows'
    if $^O eq 'MSWin32';
eval { require IO::Async::Loop; require IO::Async::Timer::Periodic; require Future::IO::Impl::IOAsync; 1 }
    or plan skip_all => 'IO::Async and Future::IO::Impl::IOAsync required';

use PAGI::App::WrapCGI;
use PAGI::Response::JSON ();
use PAGI::Response::Text ();
use PAGI::Test::ConnectionState;

# Real CGI processes, driven through the same Future::IO binding a server
# uses. Every case runs one request against t/cgi-bin/modes.cgi, whose
# behaviour QUERY_STRING selects.

my $loop   = IO::Async::Loop->new;
my $script = "$FindBin::Bin/cgi-bin/modes.cgi";
my $tmp    = tempdir(CLEANUP => 1);

{
    package TestWrapCGIStartFailure;
    use parent -norequire, 'PAGI::App::WrapCGI';
    sub _open_cgi { return }
}

sub scope_for {
    my (%args) = @_;
    return {
        type              => 'http',
        method            => $args{method} // 'GET',
        scheme            => $args{scheme} // 'http',
        http_version      => '1.1',
        path              => $args{path} // '/info',
        raw_path          => $args{raw_path} // ($args{root_path} // '') . ($args{path} // '/info'),
        root_path         => $args{root_path} // '',
        query_string      => $args{query} // 'mode=env',
        headers           => $args{headers} // [],
        server            => ['localhost', 8080],
        client            => ['127.0.0.1', 4242],
        'pagi.connection' => PAGI::Test::ConnectionState->new,
    };
}

# Run one request; returns (status, headers hashref, body, events).
sub run_cgi {
    my (%args) = @_;
    my $app = ($args{class} // 'PAGI::App::WrapCGI')->new(
        script => $script, %{ $args{options} // {} },
    )->to_app;
    my @chunks = @{ $args{body_chunks} // [] };
    my $receive = async sub {
        return { type => 'http.request', body => '', more => 0 } unless @chunks;
        my $chunk = shift @chunks;
        return { type => 'http.request', body => $chunk, more => @chunks ? 1 : 0 };
    };
    my @events;
    my $send = $args{send} // async sub { push @events, $_[0] };
    my $done = $app->(scope_for(%{ $args{scope} // {} }), $receive, $send);
    $loop->await($done);
    $done->get;    # await only waits: get reports a failure
    my ($start) = grep { $_->{type} eq 'http.response.start' } @events;
    my %headers = map { lc($_->[0]) => $_->[1] } @{ $start->{headers} // [] };
    my $body = join '', map { $_->{body} // '' } grep { $_->{type} eq 'http.response.body' } @events;
    return ($start ? $start->{status} : undef, \%headers, $body, \@events);
}

sub env_of { my ($body) = @_; return { map { /\A([A-Z_]+)=(.*)\z/ ? ($1, $2) : () } split /\n/, $body } }

subtest 'the CGI environment follows RFC 3875' => sub {
    my ($status, undef, $body) = run_cgi(scope => {
        method    => 'POST',
        root_path => '/cgi',
        path      => "/caf\x{e9}",
        raw_path  => '/cgi/caf%C3%A9',
        query     => 'mode=env&x=1',
        scheme    => 'https',
        headers   => [
            ['Accept', 'text/plain'],
            ['X-Multi', 'one'], ['X-Multi', 'two'],
            ['Proxy', 'http://evil.example:8080'],
            ['Content-Type', 'text/plain'],
            ['Content-Length', '0'],
        ],
    });
    is $status, 200, 'the script ran';
    my $env = env_of($body);
    is $env->{GATEWAY_INTERFACE}, '[CGI/1.1]', 'GATEWAY_INTERFACE';
    is $env->{REQUEST_METHOD}, '[POST]', 'REQUEST_METHOD';
    is $env->{SCRIPT_NAME}, '[/cgi]', 'SCRIPT_NAME is the root path';
    is $env->{PATH_INFO}, "[/caf\xc3\xa9]", 'PATH_INFO is the decoded path as bytes';
    is $env->{REQUEST_URI}, '[/cgi/caf%C3%A9?mode=env&x=1]', 'REQUEST_URI is what the client sent';
    is $env->{HTTPS}, '[on]', 'HTTPS for an https request';
    is $env->{HTTP_X_MULTI}, '[one, two]', 'repeated headers are joined';
    is $env->{HTTP_PROXY}, 'unset', 'a Proxy header never becomes HTTP_PROXY (httpoxy)';
    is $env->{CONTENT_TYPE}, '[text/plain]', 'CONTENT_TYPE';
    is $env->{PATH}, 'set', "the server's PATH is passed on";
    is $env->{HOME}, 'unset', "the rest of the server's environment is not";
};

subtest 'a POST body reaches the script' => sub {
    my ($status, undef, $body) = run_cgi(
        scope => { method => 'POST', query => 'mode=echo',
                   headers => [['Content-Length', '11']] },
        body_chunks => ['hello', ' world'],
    );
    is [$status, $body], [200, 'hello world'], 'streamed into stdin and echoed';

    ($status, undef, $body) = run_cgi(
        scope => { method => 'POST', query => 'mode=echo' },      # no Content-Length
        body_chunks => ['chunked', ' body'],
    );
    is [$status, $body], [200, 'chunked body'], 'a body without Content-Length is buffered for CONTENT_LENGTH';
};

subtest 'large output streams with backpressure' => sub {
    my ($status, $headers, $body, $events) = run_cgi(scope => { query => 'mode=big' });
    is $status, 200, 'ok';
    is length($body), 80 * 65536, 'all 5MB arrive';
    ok scalar(grep { $_->{type} eq 'http.response.body' } @$events) > 2, 'in more than one chunk';
};

subtest 'large input and output at once do not deadlock' => sub {
    my $input = 'z' x (1024 * 1024);
    my $started = time;
    my ($status, undef, $body) = run_cgi(
        scope => { method => 'POST', query => 'mode=bigio',
                   headers => [['Content-Length', length $input]] },
        body_chunks => [unpack '(a65536)*', $input],
    );
    is $status, 200, 'ok';
    like $body, qr/read 1048576\n\z/, 'the script read every byte while its output was drained';
    ok time - $started < 20, 'without stalling';
};

subtest 'the event loop keeps running while a script works' => sub {
    my $ticks = 0;
    my $timer = IO::Async::Timer::Periodic->new(interval => 0.05, on_tick => sub { $ticks++ });
    $loop->add($timer);
    $timer->start;
    my $pidfile = "$tmp/slow.pid";
    my $started = time;
    run_cgi(scope => { query => "mode=slow_head&pidfile=$pidfile" }, options => { timeout => 1 });
    my $elapsed = time - $started;
    $timer->stop;
    $loop->remove($timer);
    ok $ticks >= int($elapsed / 0.05) / 2, "the timer ticked $ticks times in ${\ sprintf '%.1f', $elapsed}s";
};

subtest 'timeout before the headers: 504, and the script is killed' => sub {
    my $pidfile = "$tmp/head.pid";
    my $started = time;
    my ($status, $headers, $body) = run_cgi(
        scope => { query => "mode=slow_head&pidfile=$pidfile" }, options => { timeout => 1 });
    is $status, 504, '504';
    is $body, 'CGI script timed out', 'plain text';
    ok time - $started < 5, 'answered at the timeout, not when the script finished';
    my $pid = do { open my $fh, '<', $pidfile or die $!; <$fh> };
    ok !(kill 0, $pid), 'the script is reaped by the time the request completes';
};

subtest 'a script that ignores TERM is killed, and the request waits for it' => sub {
    my $pidfile = "$tmp/stubborn.pid";
    my $started = time;
    my ($status) = run_cgi(
        scope => { query => "mode=stubborn&pidfile=$pidfile" }, options => { timeout => 1 });
    my $took = time - $started;
    is $status, 504, '504 at the timeout';
    ok $took >= 2.5 && $took < 8, sprintf('the request completed after KILL (%.1fs)', $took);
    my $pid = do { open my $fh, '<', $pidfile or die $!; <$fh> };
    ok !(kill 0, $pid), 'and the script is reaped';
};

subtest 'timeout after the body started: the stream is cut off' => sub {
    my $pidfile = "$tmp/body.pid";
    my $app = PAGI::App::WrapCGI->new(script => $script, timeout => 1)->to_app;
    my @events;
    my $done = $app->(scope_for(query => "mode=slow_body&pidfile=$pidfile"),
        async sub { { type => 'http.request', body => '', more => 0 } },
        async sub { push @events, $_[0] });
    $loop->await($done);
    my $outcome = $done->is_failed ? 'failed: ' . ($done->failure)[0] : 'completed';
    is $events[0]{status}, 200, 'the status had already gone out';
    ok !grep({ $_->{type} eq 'http.response.body' && !$_->{more} } @events),
        'no terminal body event: the response does not look complete';
    is $outcome, "failed: CGI script timed out\n", 'the application reports the failure to the server';
    my $pid = do { open my $fh, '<', $pidfile or die $!; <$fh> };
    my $gone = 0;
    for (1 .. 50) { $loop->delay_future(after => 0.1)->get; $gone = 1, last unless kill 0, $pid }
    ok $gone, 'the script process is gone';
};

subtest 'a client that goes away stops the script' => sub {
    my $pidfile = "$tmp/gone.pid";
    my $sent = 0;
    eval {
        run_cgi(scope => { query => "mode=slow_body&pidfile=$pidfile" }, options => { timeout => 20 },
            send => async sub { die "client went away\n" if ++$sent > 1 });
    };
    my $pid = do { open my $fh, '<', $pidfile or die $!; <$fh> };
    my $gone = 0;
    for (1 .. 50) { $loop->delay_future(after => 0.1)->get; $gone = 1, last unless kill 0, $pid }
    ok $gone, 'the script process is gone';
};

subtest 'Status, Location and other script headers' => sub {
    my ($status, $headers, $body) = run_cgi(scope => { query => 'mode=status' });
    is [$status, $headers->{'x-from'}, $body], [404, 'cgi', 'missing'], 'Status sets the status; headers pass through';
    ($status, $headers) = run_cgi(scope => { query => 'mode=location' });
    is [$status, $headers->{location}], [302, 'https://example.com/elsewhere'],
        'a Location without Status is a 302';
};

subtest 'a script that sends no valid response: 500' => sub {
    for my $mode (qw(garbage empty)) {
        my ($status, $headers, $body) = run_cgi(scope => { query => "mode=$mode" });
        is [$status, $headers->{'content-type'}, $body],
            [500, 'text/plain; charset=utf-8', 'CGI script sent no valid response'], $mode;
    }
};

subtest 'a script that cannot start: 500' => sub {
    my ($status, $headers, $body) = run_cgi(class => 'TestWrapCGIStartFailure');
    is [$status, $body], [500, 'CGI script could not be started'], 'plain text';
};

subtest 'refuse replaces every failure and can read the reason' => sub {
    my @reasons;
    my $refuse = sub {
        my ($request) = @_;
        push @reasons, $request->scope->{'pagi.cgi_failure'};
        return PAGI::Response::Text->new('custom', status => 503);
    };
    my ($status, undef, $body) = run_cgi(scope => { query => 'mode=garbage' }, options => { refuse => $refuse });
    is [$status, $body], [503, 'custom'], 'the refusing application answers';
    run_cgi(class => 'TestWrapCGIStartFailure', options => { refuse => $refuse });
    run_cgi(scope => { query => 'mode=slow_head' }, options => { refuse => $refuse, timeout => 1 });
    is \@reasons, ['headers', 'start', 'timeout'], 'pagi.cgi_failure names each failure';

    for my $value (undef, '', 0, 'yes') {
        my $label = defined $value ? "'$value'" : 'undef';
        like dies { PAGI::App::WrapCGI->new(script => $script, refuse => $value) },
            qr/\QWrapCGI 'refuse' must be an application\E/, "$label is refused";
    }
    like dies { PAGI::App::WrapCGI->new }, qr/WrapCGI requires a script/, 'a script is required';
};

done_testing;
