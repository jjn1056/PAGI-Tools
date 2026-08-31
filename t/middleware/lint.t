#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use IO::Async::Loop;

use PAGI::Middleware::Lint;

my $loop = IO::Async::Loop->new;

sub make_scope {
    my (%opts) = @_;
    return {
        type         => 'http',
        method       => $opts{method} // 'GET',
        path         => $opts{path} // '/',
        scheme       => $opts{scheme} // 'http',
        query_string => $opts{query_string},
        headers      => $opts{headers} // [],
        client       => $opts{client} // ['192.168.1.100', 12345],
    };
}

sub run_async (&) {
    my ($code) = @_;
    $loop->await($code->());
}

# ===================================================================
# (a) Connection-specific header: warn with app context BEFORE
# forwarding; the event is still forwarded either way -- the server
# is the one that actually strips the header.
# ===================================================================

subtest 'connection-specific headers warn with app context, then still forward' => sub {
    my @warnings;
    my $lint = PAGI::Middleware::Lint->new(
        on_warning => sub { push @warnings, shift },
    );

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['connection', 'keep-alive'], ['transfer-encoding', 'chunked']],
        });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $lint->wrap($app);
    my $scope = make_scope();

    my @events;
    run_async { $wrapped->($scope, async sub { {} }, async sub {
        my ($e) = @_; push @events, $e }) };

    ok grep(/connection-specific header 'connection'/, @warnings),
        'warned about the connection header';
    ok grep(/connection-specific header 'transfer-encoding'/, @warnings),
        'warned about the transfer-encoding header';
    is scalar(@events), 2, 'both events still forwarded';
    ok((grep { lc($_->[0]) eq 'connection' } @{$events[0]{headers}}),
        'connection header still present on the forwarded event -- Lint does not strip, the server does');
};

subtest 'connection-specific header warning never rejects, even in strict mode' => sub {
    my @warnings;
    my $lint = PAGI::Middleware::Lint->new(
        strict     => 1,
        on_warning => sub { push @warnings, shift },
    );

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['connection', 'close']],
        });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $lint->wrap($app);
    my $scope = make_scope();

    my @events;
    my $died = 0;
    eval {
        run_async { $wrapped->($scope, async sub { {} }, async sub {
            my ($e) = @_; push @events, $e }) };
    };
    $died = 1 if $@;

    ok !$died, 'strict mode does not reject on the connection-header advisory alone';
    is scalar(@events), 2, 'both events still forwarded in strict mode too';
    ok grep(/connection-specific header/, @warnings), 'still warned in strict mode';
};

# ===================================================================
# (b) Trailers: declared-but-unsent at app return gets a friendly
# diagnostic; an undeclared trailers event gets a warning citing the
# declaration rule.
# ===================================================================

subtest 'trailers declared but never sent -- friendly diagnostic at app return' => sub {
    my @warnings;
    my $lint = PAGI::Middleware::Lint->new(
        on_warning => sub { push @warnings, shift },
    );

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type     => 'http.response.start',
            status   => 200,
            trailers => 1,
            headers  => [],
        });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        # app returns without ever sending http.response.trailers
    };

    my $wrapped = $lint->wrap($app);
    my $scope = make_scope();

    run_async { $wrapped->($scope, async sub { {} }, async sub { {} }) };

    ok grep(/trailers/i, @warnings), 'warned about the unsent declared trailers';
    ok grep(/declar/i, @warnings), 'warning cites the declaration rule';
};

subtest 'http.response.trailers sent without declaring trailers => 1 -- warn citing the rule' => sub {
    my @warnings;
    my $lint = PAGI::Middleware::Lint->new(
        on_warning => sub { push @warnings, shift },
    );

    my @events;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        await $send->({ type => 'http.response.trailers', headers => [['x-checksum', 'abc']] });
    };

    my $wrapped = $lint->wrap($app);
    my $scope = make_scope();

    run_async { $wrapped->($scope, async sub { {} }, async sub {
        my ($e) = @_; push @events, $e }) };

    ok grep(/declar/i, @warnings), 'warning cites the trailers declaration rule';
    is scalar(@events), 3, 'non-strict still forwards the illegal event -- diagnostician, not enforcer';
};

# ===================================================================
# (c) Sends-are-sequential: warn (in both modes) when a second send
# is issued while a previous one is still in flight.
# ===================================================================

subtest 'overlapping in-flight sends warn (non-strict)' => sub {
    my @warnings;
    my $lint = PAGI::Middleware::Lint->new(
        on_warning => sub { push @warnings, shift },
    );

    my @pending;
    my $raw_send = sub {
        my $f = $loop->new_future;
        push @pending, $f;
        return $f;
    };

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $f1 = $send->({ type => 'http.response.start', status => 200, headers => [] });
        my $f2 = $send->({ type => 'http.response.body', body => 'OK', more => 0 }); # not awaited before issuing next
        await Future->wait_all($f1, $f2);
    };

    my $wrapped = $lint->wrap($app);
    my $scope = make_scope();

    my $done = $wrapped->($scope, async sub { {} }, $raw_send);
    $loop->later(sub { $_->done for @pending });
    $loop->await($done);

    ok grep(/in.flight|overlap/i, @warnings), 'warned about the overlapping send';
};

subtest 'overlapping in-flight sends warn even in strict mode (advisory, not fatal)' => sub {
    my @warnings;
    my $lint = PAGI::Middleware::Lint->new(
        strict     => 1,
        on_warning => sub { push @warnings, shift },
    );

    my @pending;
    my $raw_send = sub {
        my $f = $loop->new_future;
        push @pending, $f;
        return $f;
    };

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $f1 = $send->({ type => 'http.response.start', status => 200, headers => [] });
        my $f2 = $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        await Future->wait_all($f1, $f2);
    };

    my $wrapped = $lint->wrap($app);
    my $scope = make_scope();

    my $done = $wrapped->($scope, async sub { {} }, $raw_send);
    $loop->later(sub { $_->done for @pending });

    my $died = 0;
    eval { $loop->await($done) };
    $died = 1 if $@;

    ok !$died, 'strict mode does not reject on the overlap advisory alone';
    ok grep(/in.flight|overlap/i, @warnings), 'still warned in strict mode';
};

# ===================================================================
# (d) Strict mode rejects shared-core sequencing violations without
# forwarding (Future->fail); non-strict warns then still forwards.
# ===================================================================

subtest 'strict mode: sequencing violation rejects without forwarding' => sub {
    my $lint = PAGI::Middleware::Lint->new(strict => 1);

    my @events;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.body', body => 'oops', more => 0 }); # before start
    };

    my $wrapped = $lint->wrap($app);
    my $scope = make_scope();

    my $err_msg = '';
    eval {
        $loop->await(
            $wrapped->($scope, async sub { {} }, async sub {
                my ($e) = @_; push @events, $e })
            ->else(sub {
                my ($failure) = @_;
                $err_msg = $failure;
                return Future->done;
            })
        );
    };
    $err_msg = $@ if $@ && !$err_msg;

    like $err_msg, qr/Lint/, 'strict mode fails with a Lint error';
    is scalar(@events), 0, 'the illegal event never reached the real send -- rejected, not forwarded';
};

subtest 'non-strict mode: sequencing violation warns then still forwards' => sub {
    my @warnings;
    my @events;
    my $lint = PAGI::Middleware::Lint->new(
        on_warning => sub { push @warnings, shift },
    );

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.body', body => 'oops', more => 0 }); # before start
    };

    my $wrapped = $lint->wrap($app);
    my $scope = make_scope();

    run_async { $wrapped->($scope, async sub { {} }, async sub {
        my ($e) = @_; push @events, $e }) };

    ok scalar(@warnings) >= 1, 'warned about the sequencing violation';
    is scalar(@events), 1, 'illegal event still forwarded -- diagnostician, not enforcer';
};

# ===================================================================
# (e) POD truth: the "more"-key-driven terminal-body rule is actually
# implemented, via the shared core, instead of merely claimed.
# ===================================================================

subtest 'body sent after response already complete is still caught (via the shared core)' => sub {
    my @warnings;
    my @events;
    my $lint = PAGI::Middleware::Lint->new(
        on_warning => sub { push @warnings, shift },
    );

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        await $send->({ type => 'http.response.body', body => 'extra', more => 0 }); # illegal: already complete
    };

    my $wrapped = $lint->wrap($app);
    my $scope = make_scope();

    run_async { $wrapped->($scope, async sub { {} }, async sub {
        my ($e) = @_; push @events, $e }) };

    ok grep(/already complete/i, @warnings), 'warned about the send after response complete';
    is scalar(@events), 3, 'still forwarded (non-strict, diagnostician)';
};

# ===================================================================
# (f) Disconnect reclassification: a client that vanished mid-response
# is reported truthfully as a disconnect, never as a missing-await bug,
# and never fails the application Future, in either mode.
# ===================================================================

subtest 'a disconnected client is reported as a disconnect, not a missing await' => sub {
    {
        package AbortedConn6;
        sub new               { return bless {}, shift }
        sub is_connected      { return 0 }
        sub disconnect_reason { return 'client_closed' }
        sub on_disconnect     { return }
    }

    my $scope = { type => 'http', method => 'GET', path => '/x', scheme => 'http',
                  headers => [], 'pagi.connection' => AbortedConn6->new };
    my $send = sub { return Future->done };

    my $app = sub {
        my ($app_scope, $receive, $inner_send) = @_;
        return (async sub {
            await $inner_send->({ type => 'http.response.start',
                                  status => 200, headers => [] });
            await $inner_send->({ type => 'http.response.body',
                                  body => 'partial', more => 1 });
            return;
        })->();
    };

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, join '', @_ };

    my $wrapped = PAGI::Middleware::Lint->new->wrap($app);
    ok(lives {
        Future->wrap($wrapped->($scope, sub { Future->done }, $send))->get;
    }, 'a disconnect does not fail the application Future') or note($@);

    is(scalar(grep { /forget to .await./i } @warnings), 0,
        'no misleading missing-await diagnosis');
    is(scalar(grep { /disconnect/i } @warnings), 1,
        'the disconnect is still reported, with its reason');
    like(join('', @warnings), qr/client_closed/,
        'the report names the disconnect reason');
};

subtest 'strict mode does not fail a disconnected request' => sub {
    my $scope = { type => 'http', method => 'GET', path => '/x', scheme => 'http',
                  headers => [], 'pagi.connection' => AbortedConn6->new };

    my $app = sub {
        my ($app_scope, $receive, $inner_send) = @_;
        return (async sub {
            await $inner_send->({ type => 'http.response.start',
                                  status => 200, headers => [] });
            await $inner_send->({ type => 'http.response.body',
                                  body => 'partial', more => 1 });
            return;
        })->();
    };

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, join '', @_ };

    my $wrapped = PAGI::Middleware::Lint->new(strict => 1)->wrap($app);
    ok(lives {
        Future->wrap($wrapped->($scope, sub { Future->done },
            sub { Future->done }))->get;
    }, 'strict mode does not die for a client that disconnected') or note($@);
    is(scalar(grep { /Lint Error/ } @warnings), 0,
        'no fatal Lint error was raised');
};

done_testing;
