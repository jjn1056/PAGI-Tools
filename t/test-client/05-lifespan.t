#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Time::HiRes ();

use PAGI::Test::Client;

# Net against a regression that hangs the suite. Neither the old nor the fixed
# start() should ever exceed a couple of seconds here; this only fires if a
# regression wedges the loop, so it fails loud instead of stalling prove.
sub with_timeout {
    my ($seconds, $code) = @_;
    my @result;
    my $ok = eval {
        local $SIG{ALRM} = sub { die "TEST TIMEOUT after ${seconds}s\n" };
        alarm $seconds;
        @result = $code->();
        alarm 0;
        1;
    };
    my $err = $@;
    alarm 0;
    die $err unless $ok;
    return wantarray ? @result : $result[0];
}

my $startup_called = 0;
my $shutdown_called = 0;

my $lifespan_app = async sub {
    my ($scope, $receive, $send) = @_;

    if ($scope->{type} eq 'lifespan') {
        my $event = await $receive->();

        if ($event->{type} eq 'lifespan.startup') {
            $startup_called = 1;
            $scope->{state}{db} = 'connected';
            await $send->({ type => 'lifespan.startup.complete' });
        }

        $event = await $receive->();
        if ($event->{type} eq 'lifespan.shutdown') {
            $shutdown_called = 1;
            await $send->({ type => 'lifespan.shutdown.complete' });
        }
        return;
    }

    # HTTP
    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [['content-type', 'text/plain']],
    });

    await $send->({
        type => 'http.response.body',
        body => "DB: " . ($scope->{state}{db} // 'none'),
        more => 0,
    });
};

subtest 'lifespan disabled by default' => sub {
    $startup_called = 0;
    my $client = PAGI::Test::Client->new(app => $lifespan_app);
    my $res = $client->get('/');

    ok !$startup_called, 'startup not called when lifespan disabled';
    is $res->text, 'DB: none', 'no state without lifespan';
};

subtest 'lifespan explicit start/stop' => sub {
    $startup_called = 0;
    $shutdown_called = 0;

    my $client = PAGI::Test::Client->new(app => $lifespan_app, lifespan => 1);
    $client->start;

    ok $startup_called, 'startup called';

    my $res = $client->get('/');
    is $res->text, 'DB: connected', 'state available';

    $client->stop;
    ok $shutdown_called, 'shutdown called';
};

subtest 'lifespan run() helper' => sub {
    $startup_called = 0;
    $shutdown_called = 0;

    PAGI::Test::Client->run($lifespan_app, sub {
        my ($client) = @_;
        ok $startup_called, 'startup called in run()';
        my $res = $client->get('/');
        is $res->text, 'DB: connected', 'state in run()';
    });

    ok $shutdown_called, 'shutdown called after run()';
};

subtest 'startup failure surfaces the error instead of silently hanging' => sub {
    # A lifespan handler whose startup fails, written raw.
    my $failing = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();   # lifespan.startup
        await $send->({ type => 'lifespan.startup.failed', message => "database unreachable\n" });
    };
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        return await $failing->($scope, $receive, $send)
            if ($scope->{type} // '') eq 'lifespan';
        return;
    };

    my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);

    my $t0 = Time::HiRes::time();
    my $err = dies { with_timeout(20, sub { $client->start }) };
    my $elapsed = Time::HiRes::time() - $t0;

    ok $err, 'start() dies when startup fails';
    like $err, qr/database unreachable/,
        'the startup failure message is surfaced, not swallowed';
    ok $elapsed < 2,
        sprintf('fails promptly (%.3fs), not a ~5s silent deadline spin', $elapsed);
    ok !$client->{started}, 'client is not marked started after a failed startup';
};

subtest 'startup awaiting real off-loop I/O completes (loop is driven)' => sub {
    unless (eval { require Future::IO::Impl::IOAsync; 1 }) {
        skip_all('Future::IO::Impl::IOAsync required to drive real off-loop I/O');
    }
    require Future::IO;

    my $hook_finished = 0;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        if (($scope->{type} // '') eq 'lifespan') {
            my $event = await $receive->();
            if ($event->{type} eq 'lifespan.startup') {
                await Future::IO->sleep(0.05);   # real off-loop I/O
                $scope->{state}{ready} = 1;
                $hook_finished = 1;
                await $send->({ type => 'lifespan.startup.complete' });
            }
            $event = await $receive->();   # block until shutdown
            await $send->({ type => 'lifespan.shutdown.complete' })
                if $event->{type} eq 'lifespan.shutdown';
            return;
        }
        return;
    };

    my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);

    my $t0 = Time::HiRes::time();
    ok lives { with_timeout(20, sub { $client->start }) },
        'start() returns after a startup that awaits off-loop I/O';
    my $elapsed = Time::HiRes::time() - $t0;

    ok $hook_finished, 'startup hook ran to completion (the loop was driven)';
    ok $client->state->{ready}, 'startup wrote to shared state';
    ok $elapsed < 2,
        sprintf('completes promptly (%.3fs), not a ~5s deadline spin', $elapsed);

    $client->stop;
};

# ---------------------------------------------------------------------------
# B11: wrong-phase lifespan results fail via the B1 send-sequencing machine,
# and stop() dies on lifespan.shutdown.failed symmetric with how start()
# already dies on lifespan.startup.failed.
# ---------------------------------------------------------------------------

subtest 'B11: lifespan.shutdown.complete sent during the startup phase fails the send' => sub {
    my $send_err;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $event = await $receive->();
        if ($event->{type} eq 'lifespan.startup') {
            eval { await $send->({ type => 'lifespan.shutdown.complete' }); 1 }
                or do { $send_err = $@ };
            await $send->({ type => 'lifespan.startup.complete' });
        }
        $event = await $receive->();
        if ($event->{type} eq 'lifespan.shutdown') {
            await $send->({ type => 'lifespan.shutdown.complete' });
        }
    };

    my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
    ok lives { with_timeout(5, sub { $client->start }) },
        'start() still succeeds -- the app recovers by sending the right result after';

    ok $send_err, 'the wrong-phase send failed';
    like $send_err, qr/phase/i, 'error names the phase mismatch';

    $client->stop;
};

subtest 'B11: stop() dies when the app reports lifespan.shutdown.failed' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $event = await $receive->();
        await $send->({ type => 'lifespan.startup.complete' })
            if $event->{type} eq 'lifespan.startup';
        $event = await $receive->();
        await $send->({ type => 'lifespan.shutdown.failed', message => 'cleanup blew up' })
            if $event->{type} eq 'lifespan.shutdown';
    };

    my $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
    ok lives { with_timeout(5, sub { $client->start }) }, 'start() succeeds';

    my $t0 = Time::HiRes::time();
    my $err = dies { with_timeout(20, sub { $client->stop }) };
    my $elapsed = Time::HiRes::time() - $t0;

    ok $err, 'stop() dies when shutdown fails';
    like $err, qr/cleanup blew up/, 'the shutdown failure message is surfaced';
    ok $elapsed < 2, sprintf('fails promptly (%.3fs), not a ~5s silent deadline spin', $elapsed);
};

subtest 'each request, WebSocket and SSE scope gets a shallow copy of state' => sub {
    # PAGI::Spec::Lifespan, "Lifespan State": top-level keys are private to
    # each copy; values (containers, objects) are shared.
    my @seen;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                if ($event->{type} eq 'lifespan.startup') {
                    $scope->{state}{count} = 0;
                    $scope->{state}{shared} = { count => 0 };
                    await $send->({ type => 'lifespan.startup.complete' });
                }
                elsif ($event->{type} eq 'lifespan.shutdown') {
                    await $send->({ type => 'lifespan.shutdown.complete' });
                    return;
                }
            }
        }
        my $state = $scope->{state};
        push @seen, [$scope->{type}, $state->{count}++, $state->{shared}{count}++];
        if ($scope->{type} eq 'http') {
            await $send->({ type => 'http.response.start', status => 204, headers => [] });
            await $send->({ type => 'http.response.body', body => '' });
        }
        elsif ($scope->{type} eq 'websocket') {
            await $receive->();
            await $send->({ type => 'websocket.accept' });
            await $send->({ type => 'websocket.close', code => 1000 });
        }
        else {
            await $send->({ type => 'sse.start', status => 200, headers => [] });
        }
    };

    PAGI::Test::Client->run($app, sub {
        my ($client) = @_;
        $client->get('/');
        $client->get('/');
        eval { $client->websocket('/', sub { }) };
        eval { $client->sse('/', sub { }) };
        is($client->state->{count}, 0, 'the lifespan state keeps its own top-level keys');
        is($client->state->{shared}{count}, scalar(@seen), 'and sees changes made through shared values');
    });

    is(\@seen, [
        ['http',      0, 0],
        ['http',      0, 1],
        ['websocket', 0, 2],
        ['sse',       0, 3],
    ], 'every scope starts from the lifespan values; only shared containers carry changes');
};

# ---------------------------------------------------------------------------
# lifespan => 'auto': PAGI::Spec::Lifespan's default (auto) server mode. An
# application that declines -- raises on the lifespan scope, or returns
# without signalling startup -- runs without lifespan; only
# lifespan.startup.failed stops startup. lifespan => 1 stays strict.
# ---------------------------------------------------------------------------

# A classic application that knows only http and dies on any other scope,
# as PAGI's raw-protocol examples do.
my $http_only_app = async sub {
    my ($scope, $receive, $send) = @_;
    die "Unsupported scope type: $scope->{type}\n" if $scope->{type} ne 'http';
    await $send->({ type => 'http.response.start', status => 200,
                    headers => [['content-type', 'text/plain']] });
    await $send->({ type => 'http.response.body', body => 'hello', more => 0 });
};

subtest "auto: an application that raises on the lifespan scope runs without it" => sub {
    my $client = PAGI::Test::Client->new(app => $http_only_app, lifespan => 'auto');
    ok lives { with_timeout(20, sub { $client->start }) }, 'start() continues past the decline'
        or diag $@;
    is $client->get('/')->text, 'hello', 'requests are served';
    ok lives { with_timeout(20, sub { $client->stop }) },
        'stop() delivers no shutdown to an application that declined' or diag $@;
};

subtest 'auto: an application answering every scope with HTTP events declines' => sub {
    # The lifespan $send stays strict: the http.response.start it refuses
    # fails the application's await, and that raise is the decline.
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200,
                        headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => 'pong', more => 0 });
    };
    my $client = PAGI::Test::Client->new(app => $app, lifespan => 'auto');
    ok lives { with_timeout(20, sub { $client->start }) }, 'start() continues' or diag $@;
    is $client->get('/')->text, 'pong', 'requests are served';
    ok lives { $client->stop }, 'stop() returns' or diag $@;
};

subtest 'auto: an application that returns on the lifespan scope declines' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        return if $scope->{type} eq 'lifespan';
        await $http_only_app->($scope, $receive, $send);
    };
    my $client = PAGI::Test::Client->new(app => $app, lifespan => 'auto');
    ok lives { with_timeout(20, sub { $client->start }) }, 'start() continues' or diag $@;
    is $client->get('/')->text, 'hello', 'requests are served';
    ok lives { $client->stop }, 'stop() returns' or diag $@;
};

subtest 'auto: lifespan.startup.failed still stops startup' => sub {
    # A lifespan handler whose startup fails, written raw.
    my $failing = async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();   # lifespan.startup
        await $send->({ type => 'lifespan.startup.failed', message => "database unreachable\n" });
    };
    my $app = $failing;
    my $client = PAGI::Test::Client->new(app => $app, lifespan => 'auto');
    like dies { with_timeout(20, sub { $client->start }) }, qr/database unreachable/,
        'start() dies with the failure message';
    ok !$client->{started}, 'the client is not started';
};

subtest 'auto: an application that supports lifespan gets all of it' => sub {
    ($startup_called, $shutdown_called) = (0, 0);
    my $client = PAGI::Test::Client->new(app => $lifespan_app, lifespan => 'auto');
    $client->start;
    is $startup_called, 1, 'startup delivered';
    is $client->get('/')->text, 'DB: connected', 'startup state reaches the request';
    $client->stop;
    is $shutdown_called, 1, 'shutdown delivered';
};

subtest 'lifespan => 1 stays strict: a decline is a startup failure' => sub {
    my $client = PAGI::Test::Client->new(app => $http_only_app, lifespan => 1);
    like dies { with_timeout(20, sub { $client->start }) },
        qr/Unsupported scope type: lifespan/, 'start() dies with the raise';
    ok !$client->{started}, 'the client is not started';
};

subtest "lifespan => 'on' is strict; 'off' is refused, not read as true" => sub {
    my $client = PAGI::Test::Client->new(app => $http_only_app, lifespan => 'on');
    like dies { with_timeout(20, sub { $client->start }) },
        qr/Unsupported scope type: lifespan/, "'on' is strict, the server's spelling";
    like dies { PAGI::Test::Client->new(app => $http_only_app, lifespan => 'off') },
        qr/lifespan => 'off' is not off: pass 0/, "'off' croaks naming the fix";
};

subtest 'a decline that arrives after off-loop I/O resolves promptly' => sub {
    unless (eval { require Future::IO::Impl::IOAsync; 1 }) {
        skip_all('Future::IO::Impl::IOAsync required to drive real off-loop I/O');
    }
    require Future::IO;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} eq 'lifespan') {
            await Future::IO->sleep(0.05);   # real off-loop I/O
            die "no lifespan here\n";
        }
        await $http_only_app->($scope, $receive, $send);
    };

    my $client = PAGI::Test::Client->new(app => $app, lifespan => 'auto');
    my $t0 = Time::HiRes::time();
    ok lives { with_timeout(20, sub { $client->start }) }, 'auto: start() continues'
        or diag $@;
    ok Time::HiRes::time() - $t0 < 2, 'auto: promptly, not after the drive timeout';
    is $client->get('/')->text, 'hello', 'auto: requests are served';
    $client->stop;

    $client = PAGI::Test::Client->new(app => $app, lifespan => 1);
    $t0 = Time::HiRes::time();
    like dies { with_timeout(20, sub { $client->start }) }, qr/no lifespan here/,
        "strict: start() dies with the application's raise";
    ok Time::HiRes::time() - $t0 < 2, 'strict: promptly, not after the drive timeout';
};

done_testing;
