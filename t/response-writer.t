use strict;
use warnings;
use utf8;

use Future;
use Future::AsyncAwait;
use Scalar::Util qw(weaken);
use Test2::V0;

use PAGI::Request;
use PAGI::Request::BodyStream;
use PAGI::Response::Stream;
use PAGI::Response::Writer;
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
    package T::MinimalTransport;

    sub new { return bless { buffered => $_[1] }, $_[0] }
    sub buffered_amount { return $_[0]{buffered} }
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

{
    package T::PAGI05Connection;

    sub new {
        return bless {
            connected    => 1,
            reason       => undef,
            callbacks    => [],
            notification => 0,
            in_send      => 0,
        }, shift;
    }

    sub is_connected { return $_[0]{connected} ? 1 : 0 }
    sub disconnect_reason { return $_[0]{reason} }

    sub on_disconnect {
        my ($self, $callback) = @_;
        if ($self->{connected}) {
            push @{$self->{callbacks}}, $callback;
        } else {
            $callback->($self->{reason});
        }
        return $self;
    }

    sub transition {
        my ($self, $reason) = @_;
        return $self unless $self->{connected};
        $self->{connected} = 0;
        $self->{reason} = $reason;
        $self->{notification} = 1;
        return $self;
    }

    sub deliver_disconnect {
        my ($self) = @_;
        die "on_disconnect delivered inside send\n" if $self->{in_send};
        return $self unless delete $self->{notification};
        $_->($self->{reason}) for @{$self->{callbacks}};
        return $self;
    }

    sub send_event {
        my ($self, $handler, $event) = @_;
        ++$self->{in_send};
        my ($returned, $ok);
        $ok = eval {
            $returned = $handler->($event);
            1;
        };
        my $error = $@;
        --$self->{in_send};
        die $error unless $ok;
        return $returned;
    }
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
    my $running = $stream->to_app->(
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
    my $running = $stream->to_app->(
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
    })->to_app->(
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
    })->to_app->(http_scope(), quiet_receive(), sub { Future->done });
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

subtest 'a transport with only buffered_amount gets every optional fallback' => sub {
    my $transport_handle = T::MinimalTransport->new(7);
    my $hold = Future->new;
    my $writer;
    my $running = PAGI::Response::Stream->new(sub {
        ($writer) = @_;
        return $hold;
    })->to_app->(
        http_scope('pagi.transport' => $transport_handle),
        quiet_receive(),
        sub { Future->done },
    );

    is($writer->buffered_amount, 7,
        'the one required transport method still delegates');
    is($writer->high_water_mark, undef,
        'missing optional high watermark falls back to undef');
    is($writer->low_water_mark, undef,
        'missing optional low watermark falls back to undef');
    ok($writer->is_writable,
        'missing optional high watermark leaves the Writer writable');
    is($writer->on_high_water(sub { die 'must not run' }), $writer,
        'missing optional high-water callback is a chainable no-op');
    is($writer->on_drain(sub { die 'must not run' }), $writer,
        'missing optional drain callback is a chainable no-op');

    $hold->done;
    $running->get;
};

subtest 'pipe_from pulls only after the prior source and send settle' => sub {
    my $next = Future->new;
    my $source = T::Source->new('one', '', $next, undef);
    my @events;
    my @body_sends = (Future->new, Future->new);
    my $body_index = 0;
    my $running = PAGI::Response::Stream->new(sub {
        return $_[0]->pipe_from($source);
    })->to_app->(
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
    })->to_app->(
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
    })->to_app->(
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
    })->to_app->(
        http_scope(), quiet_receive(),
        sub { push @relay_events, $_[0]; Future->done },
    );
    like(dies { $relay->get }, qr/upload was truncated/,
        'producer can report BodyStream truncation after a sequential relay');
    ok($body->truncated, 'pipe_from preserves BodyStream truncation reporting');
    is(terminal_events(\@relay_events), [], 'reported truncation aborts without terminal success');
};

subtest 'pipe_from propagates a Future-backed next_chunk failure after waiting' => sub {
    my $next = Future->new;
    my $cleanup_calls = 0;
    my @events;
    my $running = PAGI::Response::Stream->new(sub {
        my ($writer) = @_;
        $writer->on_close(sub { ++$cleanup_calls });
        return $writer->pipe_from(T::Source->new($next));
    })->to_app->(
        http_scope(), quiet_receive(),
        sub { push @events, $_[0]; Future->done },
    );

    ok(!$running->is_ready,
        'the Stream waits for a pending Future-backed source result');
    $next->fail("deferred source exploded\n");
    like(dies { $running->get }, qr/deferred source exploded/,
        'a later source Future failure remains the producer failure');
    is($cleanup_calls, 1, 'deferred source failure runs cleanup exactly once');
    is(terminal_events(\@events), [],
        'deferred source failure emits no terminal success');
};

subtest 'disconnect before producer start completes quietly without consuming receive' => sub {
    my $connection = T::PAGI05Connection->new;
    my $start = Future->new;
    my @events;
    my $receive_calls = 0;
    my $producer_calls = 0;
    my $running = PAGI::Response::Stream->new(sub { ++$producer_calls })->to_app->(
        http_scope('pagi.connection' => $connection),
        quiet_receive(\$receive_calls),
        sub {
            my ($event) = @_;
            return $connection->send_event(sub {
                push @events, $event;
                return $start;
            }, $event);
        },
    );

    $connection->transition('before_producer')->deliver_disconnect;
    $start->done;
    $running->get;
    is($producer_calls, 0, 'already-disconnected connection skips producer invocation');
    is($receive_calls, 0, 'Stream never starts a competing receive loop');
    is(terminal_events(\@events), [], 'disconnect outcome emits no terminal success');
};

subtest 'caller cancellation before start settlement never cancels the start send' => sub {
    my $start = Future->new;
    my $start_cancelled = 0;
    my $producer_calls = 0;
    my @events;
    $start->on_cancel(sub { ++$start_cancelled });
    my $running = PAGI::Response::Stream->new(sub { ++$producer_calls })->to_app->(
        http_scope(), quiet_receive(),
        sub {
            push @events, $_[0];
            return $start;
        },
    );

    $running->cancel;
    ok($running->is_cancelled, 'caller sees its observer cancelled');
    is($start_cancelled, 0, 'start send remains server-owned');
    is($producer_calls, 0, 'producer has not started');

    $start->done;
    is($producer_calls, 0, 'retained lifecycle does not start producer after cancellation');
    is([map { $_->{type} } @events], ['http.response.start'],
        'cancelled lifecycle emits no terminal success body');
    is($start_cancelled, 0, 'start settlement path never cancels the send');
};

subtest 'caller cancellation stops unrelated producer work and retains cleanup' => sub {
    my $work = Future->new;
    my $cleanup_wait = Future->new;
    my $work_cancelled = 0;
    my $cleanup_calls = 0;
    my $writer;
    my @events;
    $work->on_cancel(sub { ++$work_cancelled });
    my $running = PAGI::Response::Stream->new(sub {
        ($writer) = @_;
        $writer->on_close(sub { ++$cleanup_calls; return $cleanup_wait });
        return $work;
    })->to_app->(
        http_scope(), quiet_receive(),
        sub { push @events, $_[0]; Future->done },
    );

    $running->cancel;
    is($work_cancelled, 1, 'cancellation is requested from producer-owned work');
    is($cleanup_calls, 1, 'retained lifecycle starts cleanup');
    is(terminal_events(\@events), [], 'cancellation emits no terminal success');

    $cleanup_wait->done;
    $writer->close->get;
    is($cleanup_calls, 1, 'cleanup remains exactly once after lifecycle completion');
};

subtest 'caller cancellation during write awaits the send before cleanup' => sub {
    my $body_send = Future->new;
    my $send_cancelled = 0;
    my $write_cancelled = 0;
    my $cleanup_calls = 0;
    my $write;
    my @events;
    $body_send->on_cancel(sub { ++$send_cancelled });
    my $running = PAGI::Response::Stream->new(sub {
        my ($writer) = @_;
        $writer->on_close(sub { ++$cleanup_calls });
        $write = $writer->write('pending');
        $write->on_cancel(sub { ++$write_cancelled });
        return $write;
    })->to_app->(
        http_scope(), quiet_receive(),
        sub {
            my ($event) = @_;
            push @events, $event;
            return Future->done if $event->{type} eq 'http.response.start';
            return $body_send;
        },
    );

    $running->cancel;
    is($write_cancelled, 1, 'producer-facing write is cancelled promptly');
    is($send_cancelled, 0, 'underlying send is never cancelled');
    is($cleanup_calls, 0, 'cleanup cannot outrun the active send');

    $body_send->done;
    is($send_cancelled, 0, 'send settles through its server-owned path');
    is($cleanup_calls, 1, 'cleanup runs once after send settlement');
    is(terminal_events(\@events), [], 'cancellation sends no false terminal body');
};

subtest 'normal completion releases the private disconnect signal' => sub {
    my $weak_signal;
    {
        my $running = PAGI::Response::Stream->new(sub {
            my ($writer) = @_;
            $weak_signal = $writer->_disconnect_signal;
            weaken($weak_signal);
            return;
        })->to_app->(
            http_scope(), quiet_receive(), sub { Future->done },
        );
        $running->get;
        undef $running;
    }
    is($weak_signal, undef,
        'normal completion leaves no self-cycle through the disconnect observer');
};

subtest 'disconnect cancels unrelated producer work and awaits exactly-once cleanup' => sub {
    my $connection = T::PAGI05Connection->new;
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
    })->to_app->(
        http_scope('pagi.connection' => $connection), quiet_receive(),
        sub {
            my ($event) = @_;
            return $connection->send_event(sub {
                push @events, $event;
                return Future->done;
            }, $event);
        },
    );

    $connection->transition('client_gone');
    is($writer->is_disconnected, 1,
        'synchronous state is visible before deferred callback delivery');
    is($work_cancelled, 0,
        'polling state alone does not impersonate the mandatory callback signal');
    $connection->deliver_disconnect;
    is($work_cancelled, 1, 'disconnect requests cancellation of unrelated producer work');
    is($writer->is_disconnected, 1, 'Writer records the disconnection');
    is($writer->disconnect_reason, 'client_gone', 'Writer retains the connection reason');
    ok(!$running->is_ready, 'runner awaits Future-backed cleanup');
    is(\@cleanup, ['first'], 'cleanup callbacks run sequentially');
    $work->done unless $work->is_ready || $work->is_cancelled;
    $cleanup_wait->done;
    $running->get;
    is(\@cleanup, ['first', 'last'], 'a failed callback does not prevent later cleanup');
    is(scalar @warnings, 1, 'cleanup callback failure is reported once');
    like($warnings[0], qr/cleanup exploded/, 'cleanup warning contains callback failure');
    is(terminal_events(\@events), [], 'disconnect does not emit terminal success');
    $writer->close->get;
    is(\@cleanup, ['first', 'last'], 'cleanup remains exactly once after local close');
};

subtest 'PAGI 0.5 disconnect settles active sends without failing or cancelling Writer work' => sub {
    for my $operation (qw(body terminal)) {
        subtest $operation => sub {
            my $connection = T::PAGI05Connection->new;
            my $pending_send = Future->new;
            my $cleanup_wait = Future->new;
            my $send_cancelled = 0;
            my $cleanup_calls = 0;
            my ($writer, $operation_future, $producer_future);
            my @offered;
            my @accepted;
            $pending_send->on_cancel(sub { ++$send_cancelled });
            $pending_send->on_done(sub {
                push @accepted, $offered[-1] if $connection->is_connected;
            });

            my $running = PAGI::Response::Stream->new(sub {
                ($writer) = @_;
                $writer->on_close(sub {
                    ++$cleanup_calls;
                    return $cleanup_wait if $operation eq 'terminal';
                    return;
                });
                $operation_future = $operation eq 'body'
                    ? $writer->write('pending body')
                    : $writer->close;
                $producer_future = $operation_future;
                return $producer_future;
            })->to_app->(
                http_scope('pagi.connection' => $connection), quiet_receive(),
                sub {
                    my ($event) = @_;
                    return $connection->send_event(sub {
                        push @offered, $event;
                        return Future->done if $event->{type} eq 'http.response.start';
                        return $pending_send;
                    }, $event);
                },
            );

            ok(!$operation_future->is_ready, 'public operation waits for send settlement');
            $connection->transition("pending_$operation")->deliver_disconnect;
            ok(!$operation_future->is_ready,
                'disconnect does not manufacture an operation settlement');
            is($send_cancelled, 0, 'disconnect never cancels the PAGI send Future');
            ok(!$running->is_ready, 'abort waits for the active PAGI send Future');
            is($cleanup_calls, 0, 'cleanup does not outrun the active send');

            $pending_send->done;
            if ($operation eq 'terminal') {
                ok(!$operation_future->is_ready,
                    'terminal operation retains Writer-owned cleanup backpressure');
                ok(!$operation_future->is_cancelled,
                    'producer cancellation does not cancel Writer-owned close cleanup');
                ok(!$running->is_ready,
                    'runner waits for terminal cleanup after send settlement');
                is($cleanup_calls, 1, 'terminal cleanup starts after send settlement');
                $cleanup_wait->done;
            }
            ok($operation_future->is_done,
                'public operation resolves normally with the discarded send');
            ok(lives { $operation_future->get },
                'the discarded send produces no disconnect-derived Writer error');
            ok(lives { $running->get }, 'disconnect remains a quiet connection outcome');
            is($send_cancelled, 0, 'settlement path never cancels the send Future');
            is($cleanup_calls, 1, 'cleanup runs exactly once after send settlement');
            is($writer->is_disconnected, 1, 'Writer exposes transitioned connection state');
            is($writer->disconnect_reason, "pending_$operation",
                'Writer exposes the exact disconnect reason');
            is($writer->bytes_written, 0, 'discarded output does not count as written');
            is(terminal_events(\@accepted), [],
                'a discarded operation records no terminal success');
        };
    }
};

subtest 'pipe_from stops before another pull after a discarded send settles' => sub {
    my $connection = T::PAGI05Connection->new;
    my $pending_send = Future->new;
    my $send_cancelled = 0;
    my $source = T::Source->new('first', 'must not be pulled', undef);
    my ($writer, $pipe);
    my @events;
    $pending_send->on_cancel(sub { ++$send_cancelled });

    my $running = PAGI::Response::Stream->new(sub {
        ($writer) = @_;
        $pipe = $writer->pipe_from($source);
        return $pipe;
    })->to_app->(
        http_scope('pagi.connection' => $connection), quiet_receive(),
        sub {
            my ($event) = @_;
            return $connection->send_event(sub {
                push @events, $event;
                return Future->done if $event->{type} eq 'http.response.start';
                return $pending_send;
            }, $event);
        },
    );

    is($source->calls, 1, 'only the first source item is pulled before send settlement');
    $connection->transition('relay_disconnected')->deliver_disconnect;
    ok(!$running->is_ready, 'relay abort waits for its pending send');
    is($send_cancelled, 0, 'relay disconnect does not cancel the send Future');
    $pending_send->done;
    ok(lives { $pipe->get }, 'pipe_from resolves normally after the discarded send');
    ok(lives { $running->get }, 'relay disconnect completes quietly');
    is($source->calls, 1, 'no source item is pulled after disconnect is observed');
    is($writer->bytes_written, 0, 'discarded relay bytes are not counted');
    is(terminal_events(\@events), [], 'relay disconnect emits no terminal event');
};

subtest 'disconnect after accepted write settlement cancels only later producer work' => sub {
    my $connection = T::PAGI05Connection->new;
    my $body_send = Future->new;
    my $later_work = Future->new;
    my $later_cancelled = 0;
    my ($writer, $write);
    my @events;
    $later_work->on_cancel(sub { ++$later_cancelled });

    my $running = PAGI::Response::Stream->new(async sub {
        ($writer) = @_;
        $write = $writer->write('accepted');
        await $write;
        await $later_work;
    })->to_app->(
        http_scope('pagi.connection' => $connection), quiet_receive(),
        sub {
            my ($event) = @_;
            return $connection->send_event(sub {
                push @events, $event;
                return Future->done if $event->{type} eq 'http.response.start';
                return $body_send;
            }, $event);
        },
    );

    $body_send->done;
    ok($write->is_done, 'connected send settlement resolves the public write');
    is($writer->bytes_written, 8, 'connected settled bytes are counted');
    ok(!$running->is_ready, 'producer continues into unrelated pending work');
    $connection->transition('after_settlement')->deliver_disconnect;
    is($later_cancelled, 1, 'later disconnect cancels only producer-owned work');
    ok(lives { $running->get }, 'later disconnect remains quiet');
    is($writer->bytes_written, 8, 'later disconnect does not retroactively discard bytes');
    is(terminal_events(\@events), [], 'later disconnect suppresses terminal success');
};

subtest 'a controlled validation send failure stays an application failure' => sub {
    my $connection = T::PAGI05Connection->new;
    my $body_send = Future->new;
    my $cleanup_calls = 0;
    my ($write, $writer);
    my @events;
    my $running = PAGI::Response::Stream->new(sub {
        ($writer) = @_;
        $writer->on_close(sub { ++$cleanup_calls });
        $write = $writer->write('invalid event resource');
        return $write;
    })->to_app->(
        http_scope('pagi.connection' => $connection), quiet_receive(),
        sub {
            my ($event) = @_;
            return $connection->send_event(sub {
                push @events, $event;
                return Future->done if $event->{type} eq 'http.response.start';
                return $body_send;
            }, $event);
        },
    );

    $body_send->fail("event resource validation failed\n");
    like(dies { $write->get }, qr/event resource validation failed/,
        'controlled send failure fails the public write');
    like(dies { $running->get }, qr/event resource validation failed/,
        'controlled send failure remains the producer/application failure');
    is($cleanup_calls, 1, 'genuine send failure runs cleanup exactly once');
    is($writer->bytes_written, 0, 'failed send counts no bytes');
    is(terminal_events(\@events), [], 'failed send emits no terminal success');
};

subtest 'disconnect after normal completion is not retroactive' => sub {
    my $connection = T::PAGI05Connection->new;
    my ($writer, $cleanup_calls) = (undef, 0);
    my @events;
    my $running = PAGI::Response::Stream->new(sub {
        ($writer) = @_;
        $writer->on_close(sub { ++$cleanup_calls });
        return $writer->write('complete');
    })->to_app->(
        http_scope('pagi.connection' => $connection), quiet_receive(),
        sub {
            my ($event) = @_;
            return $connection->send_event(sub {
                push @events, $event;
                return Future->done;
            }, $event);
        },
    );
    $running->get;
    is($writer->bytes_written, 8, 'normal connected write is counted');
    is($cleanup_calls, 1, 'normal completion ran cleanup once');
    is(scalar @{terminal_events(\@events)}, 1, 'normal completion sent terminal success');
    $connection->transition('too_late')->deliver_disconnect;
    is(scalar @{terminal_events(\@events)}, 1,
        'later disconnect cannot retract or duplicate completed output');
    is($cleanup_calls, 1, 'later disconnect does not repeat cleanup');
};

subtest 'repeated close joins pending terminal delivery and Stream awaits it' => sub {
    my $terminal_send = Future->new;
    my ($first_close, $second_close);
    my $terminal_calls = 0;
    my $running = PAGI::Response::Stream->new(sub {
        my ($writer) = @_;
        $first_close = $writer->close;
        $second_close = $writer->close;
        return $second_close;
    })->to_app->(
        http_scope(), quiet_receive(),
        sub {
            my ($event) = @_;
            return Future->done if $event->{type} eq 'http.response.start';
            ++$terminal_calls;
            return $terminal_send;
        },
    );

    ok(!$first_close->is_ready, 'first close waits for terminal send settlement');
    ok(!$second_close->is_ready,
        'second close joins rather than bypassing the pending terminal send');
    ok(!$running->is_ready,
        'Stream automatic close joins the producer-initiated terminal send');
    is($terminal_calls, 1, 'joined close calls enqueue one terminal event');

    $terminal_send->done;
    $first_close->get;
    $second_close->get;
    $running->get;
    is($terminal_calls, 1, 'settling joined close does not duplicate terminal output');
};

subtest 'cancelling the first close view cannot bypass its pending terminal send' => sub {
    my $terminal_send = Future->new;
    my $send_cancelled = 0;
    my $cleanup_calls = 0;
    my $first_close;
    $terminal_send->on_cancel(sub { ++$send_cancelled });

    my $running = PAGI::Response::Stream->new(sub {
        my ($writer) = @_;
        $writer->on_close(sub { ++$cleanup_calls });
        $first_close = $writer->close;
        $first_close->cancel;
        return $first_close;
    })->to_app->(
        http_scope(), quiet_receive(),
        sub {
            my ($event) = @_;
            return Future->done if $event->{type} eq 'http.response.start';
            return $terminal_send;
        },
    );

    ok($first_close->is_cancelled, 'application cancellation settles only its close view');
    is($send_cancelled, 0, 'application cancellation never cancels the PAGI send');
    ok(!$running->is_ready, 'Stream abort still joins the active terminal send');
    is($cleanup_calls, 0, 'cleanup cannot outrun the active terminal send');

    $terminal_send->done;
    like(dies { $running->get }, qr/Stream producer Future was cancelled/,
        'producer cancellation is reported only after terminal settlement');
    is($send_cancelled, 0, 'terminal settlement path never cancels the PAGI send');
    is($cleanup_calls, 1, 'terminal settlement runs cleanup exactly once');
};

subtest 'repeated close joins pending cleanup and Stream awaits it' => sub {
    my $cleanup_wait = Future->new;
    my ($first_close, $second_close);
    my @cleanup;
    my $running = PAGI::Response::Stream->new(sub {
        my ($writer) = @_;
        $writer->on_close(sub {
            push @cleanup, 'pending';
            return $cleanup_wait;
        });
        $writer->on_close(sub { push @cleanup, 'later' });
        $first_close = $writer->close;
        $second_close = $writer->close;
        return $second_close;
    })->to_app->(
        http_scope(), quiet_receive(), sub { Future->done },
    );

    ok(!$first_close->is_ready, 'first close waits for Future-backed cleanup');
    ok(!$second_close->is_ready,
        'second close joins rather than bypassing pending cleanup');
    ok(!$running->is_ready,
        'Stream automatic close joins producer-initiated cleanup');
    is(\@cleanup, ['pending'], 'cleanup remains sequential while the first callback waits');

    $cleanup_wait->done;
    $first_close->get;
    $second_close->get;
    $running->get;
    is(\@cleanup, ['pending', 'later'], 'joined close finishes after all cleanup callbacks');
};

subtest 'a pending terminal send that later fails remains primary after cleanup' => sub {
    my $terminal_send = Future->new;
    my $cleanup_calls = 0;
    my $running = PAGI::Response::Stream->new(sub {
        $_[0]->on_close(sub { ++$cleanup_calls });
        return 'producer done';
    })->to_app->(
        http_scope(), quiet_receive(),
        sub {
            my ($event) = @_;
            return Future->done if $event->{type} eq 'http.response.start';
            return $terminal_send;
        },
    );

    ok(!$running->is_ready, 'Stream waits for a pending terminal send');
    $terminal_send->fail("deferred terminal send exploded\n");
    like(dies { $running->get }, qr/deferred terminal send exploded/,
        'a later terminal send failure remains the primary error');
    is($cleanup_calls, 1, 'later terminal send failure runs cleanup exactly once');
};

subtest 'Future-backed failing cleanup warns and continues later callbacks' => sub {
    my $cleanup_wait = Future->new;
    my @cleanup;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $running = PAGI::Response::Stream->new(sub {
        my ($writer) = @_;
        $writer->on_close(sub {
            push @cleanup, 'pending';
            return $cleanup_wait;
        });
        $writer->on_close(sub { push @cleanup, 'later'; return 'immediate' });
        return 'producer done';
    })->to_app->(
        http_scope(), quiet_receive(), sub { Future->done },
    );

    ok(!$running->is_ready, 'normal close waits for Future-backed cleanup');
    is(\@cleanup, ['pending'], 'later cleanup does not prefetch');
    $cleanup_wait->fail("deferred cleanup exploded\n");
    $running->get;
    is(\@cleanup, ['pending', 'later'],
        'a Future-backed callback failure does not prevent the next callback');
    is(scalar @warnings, 1, 'Future-backed callback failure is reported once');
    like($warnings[0], qr/deferred cleanup exploded/,
        'cleanup warning preserves the Future failure');
};

subtest 'genuine producer and terminal-send errors rethrow after cleanup' => sub {
    my (@warnings, @cleanup, @producer_events);
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $producer_failure = PAGI::Response::Stream->new(sub {
        my ($writer) = @_;
        $writer->on_close(sub { die "cleanup warning\n" });
        $writer->on_close(sub { push @cleanup, 'later'; return Future->done });
        die "producer exploded\n";
    })->to_app->(
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
    })->to_app->(
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
