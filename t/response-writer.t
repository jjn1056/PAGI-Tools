use strict;
use warnings;
use utf8;

use Future;
use Future::AsyncAwait;
use Test2::V0;

use PAGI::Request;
use PAGI::Request::BodyStream;
use PAGI::Response::Stream;
use PAGI::Response::Writer;
use PAGI::Test::ConnectionState;
use PAGI::Transport qw(transport);

{
    package T::Transport;

    sub new {
        return bless {
            buffered => 12,
            high     => 10,
            low      => 3,
            high_cb  => undef,
            drain_cb => undef,
        }, shift;
    }
    sub buffered_amount { return $_[0]{buffered} }
    sub high_water_mark { return $_[0]{high} }
    sub low_water_mark { return $_[0]{low} }
    sub on_high_water { $_[0]{high_cb} = $_[1]; return $_[0] }
    sub on_drain { $_[0]{drain_cb} = $_[1]; return $_[0] }
}

{
    package T::Source;

    sub new {
        my ($class, @items) = @_;
        return bless { items => \@items, calls => 0 }, $class;
    }
    sub next_chunk {
        my ($self) = @_;
        ++$self->{calls};
        my $item = shift @{$self->{items}};
        return ref($item) eq 'CODE' ? $item->() : $item;
    }
    sub calls { return $_[0]{calls} }
}

sub http_scope {
    my (%changes) = @_;
    return {
        type    => 'http',
        method  => 'GET',
        headers => [],
        %changes,
    };
}

sub quiet_receive {
    my ($counter) = @_;
    return sub {
        ++$$counter if $counter;
        return Future->done({ type => 'http.request', body => '', more => 0 });
    };
}

sub terminal_events {
    my ($events) = @_;
    return [grep {
        ($_->{type} // '') eq 'http.response.body' && !($_->{more} // 0)
    } @$events];
}

subtest 'write exposes send backpressure and forbids an overlapping write' => sub {
    my @events;
    my $body_send = Future->new;
    my ($writer, $write_future);
    my $stream = PAGI::Response::Stream->new(sub {
        ($writer) = @_;
        $write_future = $writer->write('abc');
        return $write_future;
    });
    my $running = $stream->respond(
        http_scope(),
        quiet_receive(),
        sub {
            push @events, $_[0];
            return Future->done if $_[0]{type} eq 'http.response.start';
            return $body_send if $_[0]{more};
            return Future->done;
        },
    );

    isa_ok($writer, ['PAGI::Response::Writer']);
    ok(!$write_future->is_ready, 'write stays pending while its send Future is pending');
    ok(!$running->is_ready, 'producer and Stream stay pending on write backpressure');
    is(scalar @events, 2, 'only start and the first chunk have been offered');
    like(dies { $writer->write('overlap') }, qr/outstanding|await.*write/i,
        'a second overlapping write croaks');
    is(scalar @events, 2, 'the overlapping write does not enqueue another event');
    is($writer->bytes_written, 0, 'pending delivery is not counted');

    $body_send->done;
    $write_future->get;
    $running->get;
    is($writer->bytes_written, 3, 'settled connected delivery is counted by bytes');
    is($events[-1], { type => 'http.response.body', body => '', more => 0 },
        'normal producer completion sends the terminal empty body');
};

subtest 'Writer is invocation support, validates bytes/text, and closes locally once' => sub {
    my @events;
    my $hold = Future->new;
    my $writer;
    my $cleanup_calls = 0;
    my $stream = PAGI::Response::Stream->new(sub {
        ($writer) = @_;
        $writer->on_close(sub { ++$cleanup_calls });
        return $hold;
    });
    my $running = $stream->respond(
        http_scope(), quiet_receive(),
        sub { push @events, $_[0]; Future->done },
    );

    ok(!PAGI::Response::Writer->can('new'), 'Writer has no public constructor');
    ok(!$writer->isa('PAGI::Response'), 'Writer is not a Response subclass');
    ok(!$writer->can('to_app'), 'Writer is not an application value');
    is($writer->is_closed, 0, 'Writer starts open');
    is($writer->is_disconnected, undef, 'missing connection capability is tri-state undef');
    is($writer->disconnect_reason, undef, 'missing connection has no disconnect reason');

    my $flagged = 'ascii';
    utf8::upgrade($flagged);
    like(dies { $writer->write($flagged) }, qr/encoded bytes|byte scalar/i,
        'write rejects a UTF-8-flagged character scalar');
    like(dies { $writer->write(undef) }, qr/encoded bytes|defined/i,
        'write rejects undef');
    like(dies { $writer->write([]) }, qr/encoded bytes|scalar/i,
        'write rejects references');

    $writer->write_text("caf\x{e9}")->get;
    is($events[-1], {
        type => 'http.response.body', body => "caf\xC3\xA9", more => 1,
    }, 'write_text strictly UTF-8 encodes characters before writing');
    ok(!utf8::is_utf8($events[-1]{body}), 'write_text emits a byte scalar');
    my $surrogate = chr(0xD800);
    like(dies { $writer->write_text($surrogate) }, qr/(?:UTF-8|surrogate|wide)/i,
        'write_text rejects a lone surrogate');

    my $close = $writer->close;
    $close->get;
    is($writer->is_closed, 1, 'explicit close marks Writer closed');
    is($cleanup_calls, 1, 'explicit close runs cleanup once');
    is(scalar @{terminal_events(\@events)}, 1, 'explicit close sends one terminal event');
    $writer->close->get;
    is($cleanup_calls, 1, 'a second close is an idempotent local no-op');
    is(scalar @{terminal_events(\@events)}, 1, 'a second close sends no event');
    my $after = $writer->write('after');
    ok($after->is_failed, 'write after close returns a failed Future');
    like([$after->failure]->[0], qr/closed/i, 'write-after-close diagnostic names closed state');

    $hold->done;
    $running->get;
    is(scalar @{terminal_events(\@events)}, 1,
        'Stream auto-close does not duplicate an explicit terminal event');
};

subtest 'Writer delegates transport flow control and has deliberate quiet defaults' => sub {
    my $transport_handle = T::Transport->new;
    my $hold = Future->new;
    my $writer;
    my $running = PAGI::Response::Stream->new(sub {
        ($writer) = @_;
        return $hold;
    })->respond(
        http_scope('pagi.transport' => $transport_handle),
        quiet_receive(),
        sub { Future->done },
    );
    my ($high_cb, $drain_cb) = (sub { }, sub { });

    is($writer->buffered_amount, 12, 'buffered_amount delegates to pagi.transport');
    is($writer->high_water_mark, 10, 'high watermark delegates to pagi.transport');
    is($writer->low_water_mark, 3, 'low watermark delegates to pagi.transport');
    ok(!$writer->is_writable, 'is_writable reflects buffer at or above high watermark');
    is($writer->on_high_water($high_cb), $writer, 'on_high_water is chainable');
    is($writer->on_drain($drain_cb), $writer, 'on_drain is chainable');
    is($transport_handle->{high_cb}, $high_cb, 'high-water callback is delegated by identity');
    is($transport_handle->{drain_cb}, $drain_cb, 'drain callback is delegated by identity');
    $hold->done;
    $running->get;

    my $quiet_hold = Future->new;
    my $quiet_writer;
    my $quiet_running = PAGI::Response::Stream->new(sub {
        ($quiet_writer) = @_;
        return $quiet_hold;
    })->respond(http_scope(), quiet_receive(), sub { Future->done });
    is($quiet_writer->buffered_amount, 0, 'absent transport reports zero buffered bytes');
    is($quiet_writer->high_water_mark, undef, 'absent transport has no high watermark');
    is($quiet_writer->low_water_mark, undef, 'absent transport has no low watermark');
    ok($quiet_writer->is_writable, 'absent transport is operationally writable');
    is($quiet_writer->on_high_water(sub { die 'must not run' }), $quiet_writer,
        'absent high-water registration is a quiet chainable no-op');
    is($quiet_writer->on_drain(sub { die 'must not run' }), $quiet_writer,
        'absent drain registration is a quiet chainable no-op');

    my $request = PAGI::Request->new(http_scope(), quiet_receive());
    is(transport($request), undef,
        'optional top-level transport helper remains undef when capability is absent');
    $quiet_hold->done;
    $quiet_running->get;
};

subtest 'pipe_from pulls only after the prior source and send settle' => sub {
    my $next = Future->new;
    my $source = T::Source->new('one', '', $next, undef);
    my @events;
    my @body_sends = (Future->new, Future->new);
    my $body_index = 0;
    my $running = PAGI::Response::Stream->new(sub {
        return $_[0]->pipe_from($source);
    })->respond(
        http_scope(), quiet_receive(),
        sub {
            push @events, $_[0];
            return Future->done if $_[0]{type} eq 'http.response.start';
            return $body_sends[$body_index++] if $_[0]{more};
            return Future->done;
        },
    );

    is($source->calls, 1, 'only the first source chunk is pulled initially');
    is($events[-1]{body}, 'one', 'first source chunk is offered to send');
    ok(!$running->is_ready, 'pipe remains pending on the first send');

    $body_sends[0]->done;
    is($source->calls, 3,
        'after settlement, empty input is skipped and the Future-backed chunk is requested');
    ok(!$next->is_ready, 'Future-backed source chunk remains under source backpressure');
    is($body_index, 1, 'no second body send occurs before the next source Future settles');

    $next->done('two');
    is($events[-1]{body}, 'two', 'Future-backed source chunk is offered after it settles');
    is($source->calls, 3, 'EOF is not requested while the second send is pending');
    $body_sends[1]->done;
    $running->get;
    is($source->calls, 4, 'EOF is requested only after the second send settles');
    is($events[-1], { type => 'http.response.body', body => '', more => 0 },
        'pipe completion closes the Stream normally');
};

subtest 'pipe_from propagates source/send failures and keeps truncation observable' => sub {
    my @source_events;
    my $source_cleanup = 0;
    my $bad_source = T::Source->new(sub { die "source exploded\n" });
    my $source_failure = PAGI::Response::Stream->new(sub {
        my ($writer) = @_;
        $writer->on_close(sub { ++$source_cleanup });
        return $writer->pipe_from($bad_source);
    })->respond(
        http_scope(), quiet_receive(),
        sub { push @source_events, $_[0]; Future->done },
    );
    like(dies { $source_failure->get }, qr/source exploded/,
        'source failure is rethrown after response start');
    is($source_cleanup, 1, 'source failure runs cleanup once');
    is(terminal_events(\@source_events), [], 'source failure sends no false terminal success');

    my $send_cleanup = 0;
    my @send_events;
    my $send_failure = PAGI::Response::Stream->new(sub {
        my ($writer) = @_;
        $writer->on_close(sub { ++$send_cleanup });
        return $writer->pipe_from(T::Source->new('data', undef));
    })->respond(
        http_scope(), quiet_receive(),
        sub {
            my ($event) = @_;
            push @send_events, $event if $event->{type} eq 'http.response.start';
            return Future->fail("send exploded\n") if $event->{type} eq 'http.response.body';
            return Future->done;
        },
    );
    like(dies { $send_failure->get }, qr/send exploded/,
        'send failure is rethrown after cleanup');
    is($send_cleanup, 1, 'send failure runs cleanup once');
    is(terminal_events(\@send_events), [], 'failed delivery is not recorded as terminal success');

    my @request_events = (
        { type => 'http.request', body => 'partial', more => 1 },
        { type => 'http.disconnect' },
    );
    my $body = PAGI::Request::BodyStream->new(
        receive => sub { Future->done(shift @request_events) },
    );
    my @relay_events;
    my $relay = PAGI::Response::Stream->new(async sub {
        my ($writer) = @_;
        await $writer->pipe_from($body);
        die "upload was truncated\n" if $body->truncated;
    })->respond(
        http_scope(), quiet_receive(),
        sub { push @relay_events, $_[0]; Future->done },
    );
    like(dies { $relay->get }, qr/upload was truncated/,
        'producer can report BodyStream truncation after a sequential relay');
    ok($body->truncated, 'pipe_from preserves BodyStream truncation reporting');
    is(terminal_events(\@relay_events), [], 'reported truncation aborts without terminal success');
};

subtest 'disconnect before producer start completes quietly without consuming receive' => sub {
    my $connection = PAGI::Test::ConnectionState->new;
    my $start = Future->new;
    my @events;
    my $receive_calls = 0;
    my $producer_calls = 0;
    my $running = PAGI::Response::Stream->new(sub { ++$producer_calls })->respond(
        http_scope('pagi.connection' => $connection),
        quiet_receive(\$receive_calls),
        sub { push @events, $_[0]; return $start },
    );

    $connection->_mark_disconnected('before_producer');
    $start->done;
    $running->get;
    is($producer_calls, 0, 'already-disconnected connection skips producer invocation');
    is($receive_calls, 0, 'Stream never starts a competing receive loop');
    is(terminal_events(\@events), [], 'disconnect outcome emits no terminal success');
};

subtest 'disconnect cancels unrelated producer work and awaits exactly-once cleanup' => sub {
    my $connection = PAGI::Test::ConnectionState->new;
    my $work = Future->new;
    my $cleanup_wait = Future->new;
    my $work_cancelled = 0;
    my @cleanup;
    my @warnings;
    my @events;
    my $writer;
    $work->on_cancel(sub { ++$work_cancelled });
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $running = PAGI::Response::Stream->new(sub {
        ($writer) = @_;
        $writer->on_close(sub { push @cleanup, 'first'; return $cleanup_wait });
        $writer->on_close(sub { die "cleanup exploded\n" });
        $writer->on_close(sub { push @cleanup, 'last'; return 'immediate' });
        return $work;
    })->respond(
        http_scope('pagi.connection' => $connection), quiet_receive(),
        sub { push @events, $_[0]; Future->done },
    );

    $connection->_mark_disconnected('client_gone');
    is($work_cancelled, 1, 'disconnect requests cancellation of pending producer work');
    is($writer->is_disconnected, 1, 'Writer records the disconnection');
    is($writer->disconnect_reason, 'client_gone', 'Writer retains the connection reason');
    ok(!$running->is_ready, 'runner awaits Future-backed cleanup');
    is(\@cleanup, ['first'], 'cleanup callbacks run sequentially');
    $cleanup_wait->done;
    $running->get;
    is(\@cleanup, ['first', 'last'], 'a failed callback does not prevent later cleanup');
    is(scalar @warnings, 1, 'cleanup callback failure is reported once');
    like($warnings[0], qr/cleanup exploded/, 'cleanup warning contains callback failure');
    is(terminal_events(\@events), [], 'disconnect does not emit terminal success');
    $writer->close->get;
    is(\@cleanup, ['first', 'last'], 'cleanup remains exactly once after local close');
};

subtest 'disconnect fails a pending write Future and cancels its send' => sub {
    my $connection = PAGI::Test::ConnectionState->new;
    my $body_send = Future->new;
    my $send_cancelled = 0;
    my ($writer, $write);
    my @events;
    $body_send->on_cancel(sub { ++$send_cancelled });
    my $running = PAGI::Response::Stream->new(sub {
        ($writer) = @_;
        $write = $writer->write('pending');
        return $write;
    })->respond(
        http_scope('pagi.connection' => $connection), quiet_receive(),
        sub {
            push @events, $_[0];
            return $_[0]{type} eq 'http.response.start' ? Future->done : $body_send;
        },
    );

    $connection->_mark_disconnected('during_send');
    ok($write->is_failed, 'disconnect fails rather than cancels the public write Future');
    like([$write->failure]->[0], qr/disconnect.*during_send/i,
        'pending write failure contains the disconnect reason');
    is($send_cancelled, 1, 'pending send work is cancelled');
    $running->get;
    is($writer->bytes_written, 0, 'disconnected pending delivery is not counted');
    is(terminal_events(\@events), [], 'pending-write disconnect emits no terminal success');
};

subtest 'disconnect immediately after send settlement still fails that write' => sub {
    my $connection = PAGI::Test::ConnectionState->new;
    my $body_send = Future->new;
    my ($writer, $write);
    my @events;
    $body_send->on_done(sub { $connection->_mark_disconnected('after_settlement') });
    my $running = PAGI::Response::Stream->new(sub {
        ($writer) = @_;
        $write = $writer->write('accepted-noop');
        return $write;
    })->respond(
        http_scope('pagi.connection' => $connection), quiet_receive(),
        sub {
            push @events, $_[0];
            return $_[0]{type} eq 'http.response.start' ? Future->done : $body_send;
        },
    );

    $body_send->done;
    ok($write->is_failed, 'post-settlement connection state overrides send success');
    like([$write->failure]->[0], qr/disconnect.*after_settlement/i,
        'post-settlement failure keeps its disconnect reason');
    $running->get;
    is($writer->bytes_written, 0, 'post-disconnect no-op is not counted as accepted bytes');
    is(terminal_events(\@events), [], 'post-settlement disconnect emits no terminal success');
};

subtest 'pre-send disconnect fails write, while disconnect after completion is not retroactive' => sub {
    my $before = PAGI::Test::ConnectionState->new;
    my ($before_writer, $before_write);
    my @before_events;
    my $before_running = PAGI::Response::Stream->new(sub {
        ($before_writer) = @_;
        $before->_mark_disconnected('before_send');
        $before_write = $before_writer->write('never queued');
        return $before_write;
    })->respond(
        http_scope('pagi.connection' => $before), quiet_receive(),
        sub { push @before_events, $_[0]; Future->done },
    );
    ok($before_write->is_failed, 'pre-send disconnect returns a failed write Future');
    like([$before_write->failure]->[0], qr/disconnect.*before_send/i,
        'pre-send diagnostic includes its reason');
    $before_running->get;
    is(scalar @before_events, 1, 'pre-send disconnect does not enqueue a body');

    my $after = PAGI::Test::ConnectionState->new;
    my ($after_writer, $cleanup_calls) = (undef, 0);
    my @after_events;
    my $after_running = PAGI::Response::Stream->new(sub {
        ($after_writer) = @_;
        $after_writer->on_close(sub { ++$cleanup_calls });
        return $after_writer->write('complete');
    })->respond(
        http_scope('pagi.connection' => $after), quiet_receive(),
        sub { push @after_events, $_[0]; Future->done },
    );
    $after_running->get;
    is($after_writer->bytes_written, 8, 'normal connected write is counted');
    is($cleanup_calls, 1, 'normal completion ran cleanup once');
    is(scalar @{terminal_events(\@after_events)}, 1, 'normal completion sent terminal success');
    $after->_mark_disconnected('too_late');
    is(scalar @{terminal_events(\@after_events)}, 1,
        'later disconnect cannot retract or duplicate completed output');
    is($cleanup_calls, 1, 'later disconnect does not repeat cleanup');
};

subtest 'genuine producer and terminal-send errors rethrow after cleanup' => sub {
    my (@warnings, @cleanup, @producer_events);
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $producer_failure = PAGI::Response::Stream->new(sub {
        my ($writer) = @_;
        $writer->on_close(sub { die "cleanup warning\n" });
        $writer->on_close(sub { push @cleanup, 'later'; return Future->done });
        die "producer exploded\n";
    })->respond(
        http_scope(), quiet_receive(),
        sub { push @producer_events, $_[0]; Future->done },
    );
    like(dies { $producer_failure->get }, qr/producer exploded/,
        'genuine producer error remains the primary failure');
    is(\@cleanup, ['later'], 'later cleanup runs after a callback failure');
    is(scalar @warnings, 1, 'callback failure is reported without replacing producer error');
    is(terminal_events(\@producer_events), [], 'producer error emits no terminal success');

    my $terminal_cleanup = 0;
    my @successful_events;
    my $terminal_failure = PAGI::Response::Stream->new(sub {
        $_[0]->on_close(sub { ++$terminal_cleanup });
        return 'done';
    })->respond(
        http_scope(), quiet_receive(),
        sub {
            my ($event) = @_;
            return Future->fail("terminal send exploded\n")
                if $event->{type} eq 'http.response.body' && !$event->{more};
            push @successful_events, $event;
            return Future->done;
        },
    );
    like(dies { $terminal_failure->get }, qr/terminal send exploded/,
        'terminal send failure is rethrown');
    is($terminal_cleanup, 1, 'terminal send failure still runs cleanup exactly once');
    is(terminal_events(\@successful_events), [], 'failed terminal send is not a success event');
};

done_testing;
