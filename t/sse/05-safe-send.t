#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use lib 't/lib';
use PAGI::SSE;
use PAGITest::Connected qw(sse_scope);

subtest 'try_send returns true on success' => sub {
    my $send = sub { Future->done };
    my $sse = PAGI::SSE->new(sse_scope(), sub {}, $send);
    $sse->start->get;

    my $result = $sse->try_send("Hello")->get;
    ok($result, 'try_send returns true on success');
};

subtest 'try_send returns false when closed' => sub {
    my $scope = sse_scope();
    my $sse = PAGI::SSE->new($scope, sub {}, sub { Future->done });
    $scope->{'pagi.connection'}->_mark_disconnected('client_closed');

    my $result = $sse->try_send("Hello")->get;
    ok(!$result, 'try_send returns false when closed');
};

subtest 'try_send returns false on send error' => sub {
    my $scope = sse_scope();
    my $connection = $scope->{'pagi.connection'};
    # The stream starts; the peer is then lost, which the server records on
    # the connection before failing the send.
    my $send = sub {
        return Future->done if $_[0]{type} eq 'sse.start';
        $connection->_mark_disconnected('client_closed');
        return Future->fail("Connection lost");
    };
    my $sse = PAGI::SSE->new($scope, sub {}, $send);
    $sse->start->get;

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $result = $sse->try_send("Hello")->get;
    ok(!$result, 'try_send returns false on error');
    ok($sse->is_closed, 'connection marked as closed after the connection recorded the loss');
    is \@warnings, [], 'with no on_error, the false return is the only signal';
};

subtest 'try_send_json works' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $sse = PAGI::SSE->new(sse_scope(), sub {}, $send);
    $sse->start->get;

    my $result = $sse->try_send_json({ foo => 'bar' })->get;
    ok($result, 'try_send_json returns true');
    like($sent[1]{data}, qr/"foo"/, 'JSON was sent');
};

subtest 'try_send_event works' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $sse = PAGI::SSE->new(sse_scope(), sub {}, $send);
    $sse->start->get;

    my $result = $sse->try_send_event(
        data  => 'test',
        event => 'ping',
    )->get;

    ok($result, 'try_send_event returns true');
    is($sent[1]{event}, 'ping', 'event name sent');
};

subtest 'try_send_comment succeeds with a direct comment event' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };
    my $sse = PAGI::SSE->new(sse_scope(), sub {}, $send);
    $sse->start->get;

    ok($sse->try_send_comment('alive')->get,
        'try_send_comment returns true on success');
    is($sent[1], { type => 'sse.comment', comment => 'alive' },
        'try_send_comment emits the direct comment protocol event');
};

subtest 'on_error fires when try_send fails' => sub {
    my $send = sub {
        $_[0]{type} eq 'sse.start' ? Future->done : Future->fail("Connection lost");
    };
    my $sse = PAGI::SSE->new(sse_scope(), sub {}, $send);
    $sse->start->get;

    my ($fired_sse, $fired_err);
    $sse->on_error(sub {
        ($fired_sse, $fired_err) = @_;
    });

    $sse->try_send("Hello")->get;

    ok $fired_sse == $sse,        'on_error callback received $sse as first arg';
    like $fired_err, qr/Connection lost/, 'on_error callback received error';
};

subtest 'exception in on_error callback does not prevent others' => sub {
    my $send = sub {
        $_[0]{type} eq 'sse.start' ? Future->done : Future->fail("oops");
    };
    my $sse = PAGI::SSE->new(sse_scope(), sub {}, $send);
    $sse->start->get;

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $second_ran = 0;
    $sse->on_error(sub { die "first callback exploded\n" });
    $sse->on_error(sub { $second_ran = 1 });

    $sse->try_send("Hello")->get;

    ok $second_ran, 'second on_error callback ran despite first dying';
    ok scalar @warnings, 'exception in first on_error was warned';
    like $warnings[0], qr/first callback exploded/, 'warning contains error text';
};

subtest 'async on_error callback is awaited' => sub {
    my $send = sub {
        $_[0]{type} eq 'sse.start' ? Future->done : Future->fail("network error");
    };
    my $sse = PAGI::SSE->new(sse_scope(), sub {}, $send);
    $sse->start->get;

    my @fired;
    $sse->on_error(async sub { push @fired, 'async-ran' });

    $sse->try_send("Hello")->get;

    is \@fired, ['async-ran'], 'async on_error callback was awaited';
};

subtest 'async on_error exception does not prevent other callbacks' => sub {
    my $send = sub {
        $_[0]{type} eq 'sse.start' ? Future->done : Future->fail("network");
    };
    my $sse = PAGI::SSE->new(sse_scope(), sub {}, $send);
    $sse->start->get;

    my @fired;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    $sse->on_error(async sub { die "async error handler exploded\n" });
    $sse->on_error(sub { push @fired, 'second' });

    $sse->try_send("Hello")->get;

    is \@fired, ['second'], 'second on_error ran despite async first dying';
    ok scalar @warnings, 'async exception in on_error was warned';
    like $warnings[0], qr/async error handler exploded/, 'warning contains error text';
};

subtest 'no on_error registered prints nothing' => sub {
    my $send = sub {
        $_[0]{type} eq 'sse.start' ? Future->done : Future->fail("send failure");
    };
    my $sse = PAGI::SSE->new(sse_scope(), sub {}, $send);
    $sse->start->get;

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $ok = $sse->try_send("Hello")->get;

    ok !$ok, 'the failure is reported by the return value';
    is \@warnings, [], 'a routine send failure is not warned';
};

done_testing;
