use strict;
use warnings;
use Test2::V0;
use Future;

use lib 't/lib';
use PAGITest::Connected qw(ws_scope sse_scope send_to);
use PAGI::WebSocket;
use PAGI::SSE;

# PAGI::WebSocket and PAGI::SSE share one internal base. The methods they
# had in identical copies live only there, so the two cannot drift apart.

my $BASE = 'PAGI::HTTPConnection::_Protocol';

my @shared = qw(
    buffered_amount high_water_mark low_water_mark
    on_high_water on_drain is_writable
    connection_state is_closed disconnect_detail
    on_close on_error finished
    try_send_json
    _refusing _answered_by_another _set_state
    _run_late_close_callback _run_close_callbacks _start_close_callbacks
    _keep
    is_connected disconnect_reason
    _answered _ends_without_application _may_not_drive
    _late_close_worker _close_callbacks_worker _trigger_error
);

# Subclasses as an application writes them: new overridden, calling SUPER::.
package Local::WebSocket {
    our @ISA = ('PAGI::WebSocket');
    sub new { my $class = shift; return $class->SUPER::new(@_) }
}
package Local::SSE {
    our @ISA = ('PAGI::SSE');
    sub new { my $class = shift; return $class->SUPER::new(@_) }
}

my %type = ('PAGI::WebSocket' => 'websocket', 'PAGI::SSE' => 'sse');

ok($BASE->isa('PAGI::HTTPConnection'), 'the base is a PAGI::HTTPConnection');

for my $class (sort keys %type) {
    subtest "$class inherits the shared methods from the base" => sub {
        ok($class->isa($BASE), "$class isa $BASE");
        for my $method (@shared) {
            my $from_base = $BASE->can($method);
            ok($from_base, "the base defines $method")
                and ref_is($class->can($method), $from_base, "$class gets $method from the base");
        }
    };
}

my $file = __FILE__;

for my $class (sort keys %type) {
    my $type = $type{$class};
    my $subclass = 'Local::' . ($class =~ s/^PAGI:://r);

    for my $caller ($class, $subclass) {
        subtest "$caller->new: argument errors name $caller and the caller's line" => sub {
            my ($error, $line);

            $line = __LINE__; $error = dies { $caller->new };
            is($error, "$caller requires scope hashref at $file line $line.\n",
                'without a scope');

            $line = __LINE__; $error = dies { $caller->new({ type => $type }) };
            is($error, "$caller requires receive coderef at $file line $line.\n",
                'without receive');

            $line = __LINE__; $error = dies { $caller->new({ type => $type }, sub {}) };
            is($error, "$caller requires send coderef at $file line $line.\n",
                'without send');

            $line = __LINE__; $error = dies { $caller->new({ type => 'http' }, sub {}, sub {}) };
            is($error, "$caller requires scope type '$type', got 'http' at $file line $line.\n",
                'with another scope type');

            like(dies { $caller->new({ type => $type, headers => [] }, sub {}, sub {}) },
                qr/^\Q$caller\E requires pagi\.connection capabilities /,
                'without pagi.connection');
        };
    }

    subtest "$subclass is built through the base" => sub {
        my $scope = $type eq 'sse' ? sse_scope() : ws_scope();
        my $helper = $subclass->new($scope, sub { Future->new }, sub { Future->done });
        isa_ok($helper, [$subclass, $class, $BASE]);
        is($helper->connection_state, $type eq 'sse' ? 'pending' : 'connecting',
            'starts in its protocol\'s first state');
    };
}

# Each class refines one shared method of the base: SSE's ownership check
# also drops a saved keepalive, and WebSocket releases its message callbacks
# with the others.
subtest 'the ownership check and the callback release are the base\'s' => sub {
    my %own = (
        _require_ownership => 'PAGI::SSE',
        _release_callbacks => 'PAGI::WebSocket',
    );
    for my $method (sort keys %own) {
        my $from_base = $BASE->can($method);
        ok($from_base, "the base defines $method") or next;
        for my $class (sort keys %type) {
            if ($class eq $own{$method}) {
                ok($class->can($method) != $from_base, "$class refines $method");
            }
            else {
                ref_is($class->can($method), $from_base, "$class gets $method from the base");
            }
        }
    }
};

# A helper of $class that answered: accepted (WebSocket) or started (SSE).
# Its sends are recorded in the returned array; with failing_sends, every
# message send fails with "send failed\n".
sub answered_helper {
    my ($class, %opt) = @_;
    my $is_sse = $class->isa('PAGI::SSE');
    my $scope = $is_sse ? sse_scope() : ws_scope();
    my @sent;
    my $record = send_to($scope, \@sent);
    my $send = sub {
        my ($event) = @_;
        my $sent = $record->($event);
        return $opt{failing_sends} && $event->{type} =~ /\.send$/
            ? Future->fail("send failed\n") : $sent;
    };
    my $helper = $class->new($scope, sub { Future->new }, $send);
    ($is_sse ? $helper->start : $helper->accept)->get;
    return ($helper, \@sent);
}

# The two callback shapes: on_close gets ($code, $reason, $detail) on
# WebSocket and ($sse, $reason, $detail) on SSE; on_error gets ($error) on
# WebSocket and ($sse, $error) on SSE.
for my $class (sort keys %type) {
    my $is_ws = $type{$class} eq 'websocket';

    subtest "$class on_close callbacks get their arguments, live and late" => sub {
        my ($helper) = answered_helper($class);
        my $connection = $helper->{scope}{'pagi.connection'};
        my (@live, @late);
        $helper->on_close(sub { @live = @_; return });
        $connection->_set_peer_close(4001, 'going away') if $is_ws;
        $connection->_mark_disconnected('client_closed', 'reset by peer');
        $helper->on_close(sub { @late = @_; return });

        my $expected = $is_ws
            ? [4001, 'going away', 'reset by peer']
            : [exact_ref($helper), 'client_closed', 'reset by peer'];
        is(\@live, $expected, 'a callback registered before the end');
        is(\@late, $expected, 'a callback registered after the end');
    };

    subtest "$class on_error callbacks get their arguments" => sub {
        my ($helper) = answered_helper($class, failing_sends => 1);
        my @args;
        $helper->on_error(sub { @args = @_; return });
        is($helper->try_send_json({})->get, 0, 'the failed send returns false');
        is(\@args, $is_ws ? ["send failed\n"] : [exact_ref($helper), "send failed\n"],
            'the callback gets the error');
    };

    my $subclass = 'Local::' . ($class =~ s/^PAGI:://r);
    subtest "a dying on_error callback of $subclass warns in $class\'s name" => sub {
        my ($helper) = answered_helper($subclass, failing_sends => 1);
        $helper->on_error(sub { die "callback died\n" });
        my $warnings = warnings { $helper->try_send_json({})->get };
        is($warnings, ["$class on_error callback error: callback died\n"], 'the warning');
    };
}

subtest 'PAGI::WebSocket try_send_* before accept return false and send nothing' => sub {
    my $scope = ws_scope();
    my @sent;
    my $ws = PAGI::WebSocket->new($scope, sub { Future->new }, send_to($scope, \@sent));
    is($ws->try_send_text('x')->get, 0, 'try_send_text');
    is($ws->try_send_bytes('x')->get, 0, 'try_send_bytes');
    is($ws->try_send_json({})->get, 0, 'try_send_json');
    is(\@sent, [], 'nothing was sent');
    is($ws->connection_state, 'connecting', 'the socket is still unanswered');
};

subtest 'PAGI::SSE try_send before start starts the stream and sends' => sub {
    my $scope = sse_scope();
    my @sent;
    my $sse = PAGI::SSE->new($scope, sub { Future->new }, send_to($scope, \@sent));
    is($sse->try_send('x')->get, 1, 'try_send returns true');
    is(\@sent, [{ type => 'sse.start', status => 200 }, { type => 'sse.send', data => 'x' }],
        'the stream was started, then the data sent');
};

my %try_sends = (
    'PAGI::WebSocket' => {
        try_send_text  => sub { $_[0]->try_send_text('x') },
        try_send_bytes => sub { $_[0]->try_send_bytes('x') },
        try_send_json  => sub { $_[0]->try_send_json({}) },
    },
    'PAGI::SSE' => {
        try_send         => sub { $_[0]->try_send('x') },
        try_send_json    => sub { $_[0]->try_send_json({}) },
        try_send_event   => sub { $_[0]->try_send_event(data => 'x') },
        try_send_comment => sub { $_[0]->try_send_comment('x') },
    },
);

for my $class (sort keys %type) {
    subtest "$class: a second helper's try_send_* return false and send nothing" => sub {
        my ($first) = answered_helper($class);
        my $scope = $first->{scope};
        my @sent;
        my $second = $class->new($scope, sub { Future->new }, send_to($scope, \@sent));
        for my $name (sort keys %{ $try_sends{$class} }) {
            is($try_sends{$class}{$name}->($second)->get, 0, $name);
        }
        is(\@sent, [], 'the second helper sent nothing');
    };
}

# A refused ownership check names the caller's line, from user code and from
# a subclass.
for my $class (sort keys %type) {
    my $subclass = 'Local::' . ($class =~ s/^PAGI:://r);
    for my $caller ($class, $subclass) {
        subtest "$caller: a send refused to a second helper names the caller's line" => sub {
            my ($first) = answered_helper($caller);
            my $scope = $first->{scope};
            my $second = $caller->new($scope, sub { Future->new }, sub { Future->done });
            my $method = $class eq 'PAGI::SSE' ? 'send' : 'send_text';
            my $line = __LINE__; my $error = dies { $second->$method('x')->get };
            is($error,
                "this connection was answered by another helper; use that one at $file line $line.\n",
                $method);
        };
    }
}

# SSE's deferred keepalive: saved before sse.start, armed right after it.
# A refused ownership check drops it; a successful one keeps it.
subtest 'PAGI::SSE: a keepalive saved before start is armed after sse.start' => sub {
    my $scope = sse_scope();
    my @sent;
    my $sse = PAGI::SSE->new($scope, sub { Future->new }, send_to($scope, \@sent));
    $sse->keepalive(10)->get;
    is(\@sent, [], 'nothing is sent before the stream starts');
    $sse->start->get;
    is(\@sent, [
        { type => 'sse.start', status => 200 },
        { type => 'sse.keepalive', interval => 10, comment => '' },
    ], 'sse.start, then the saved keepalive');
};

subtest 'PAGI::SSE: a refused ownership check drops the saved keepalive and raises' => sub {
    my $scope = sse_scope();
    my @sent;
    my $second = PAGI::SSE->new($scope, sub { Future->new }, send_to($scope, \@sent));
    $second->keepalive(10)->get;
    ok($second->{_pending_keepalive}, 'the keepalive is saved while no helper has answered');

    my $first = PAGI::SSE->new($scope, sub { Future->new }, send_to($scope, []));
    $first->start->get;
    like(dies { $second->start->get },
        qr/^this connection was answered by another helper; use that one /,
        'the second helper may not start');
    ok(!exists $second->{_pending_keepalive}, 'its saved keepalive is gone');
    is(\@sent, [], 'it sent nothing');
};

subtest 'PAGI::WebSocket releases its message callbacks once it closes' => sub {
    my ($ws) = answered_helper('PAGI::WebSocket');
    $ws->on_message(sub { return });
    $ws->close->get;
    ok($ws->is_closed, 'the socket is closed');
    is($ws->{_on_message}, [], 'no message callback is held');
};

done_testing;
