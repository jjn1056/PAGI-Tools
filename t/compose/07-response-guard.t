use strict;
use warnings;
use Test2::V0;
use Future;
use Scalar::Util qw(blessed refaddr);
use FindBin qw($Bin);
use lib "$Bin/lib";
use ComposeTest qw(scope capture_send);
use PAGI::Compose qw(compose);
use PAGI::Compose::ResponseGuard;
use PAGI::Exception::IncompleteResponse;
use PAGI::Routing qw(route);
use PAGI::Utils qw(as_app_object);

sub run_guard {
    my ($inner, $request_scope) = @_;
    my $app = PAGI::Compose::ResponseGuard->wrap($inner);
    my ($send, $events) = capture_send();
    my $receive = sub { return Future->done };
    Future->wrap($app->($request_scope || scope(), $receive, $send))->get;
    return $events;
}

sub guard_error {
    my ($inner, $request_scope) = @_;
    my $error;
    eval { run_guard($inner, $request_scope); 1 } or $error = $@;
    return $error;
}

subtest 'typed incomplete response validates and exposes lifecycle facts' => sub {
    my $error = PAGI::Exception::IncompleteResponse->new(
        stage   => 'after_start',
        message => 'response stopped early',
    );
    isa_ok($error, ['PAGI::Exception::IncompleteResponse']);
    is($error->stage, 'after_start', 'stage accessor preserves the known stage');
    is($error->message, 'response stopped early',
        'message accessor preserves the scalar message');
    is("$error", 'response stopped early', 'stringification is the message');

    for my $stage (qw(before_start after_start body_before_start awaiting_trailers)) {
        my $accepted = PAGI::Exception::IncompleteResponse->new(
            stage => $stage, message => 0,
        );
        is($accepted->stage, $stage, "$stage is an accepted stage");
        is($accepted->message, 0, 'a defined false scalar message is accepted');
    }

    like(dies {
        PAGI::Exception::IncompleteResponse->new(
            stage => 'unknown', message => 'bad',
        );
    }, qr/unknown incomplete response stage/, 'unknown stages are rejected');
    like(dies {
        PAGI::Exception::IncompleteResponse->new(
            stage => 'before_start', message => [],
        );
    }, qr/message must be a defined scalar/, 'reference messages are rejected');
    like(dies {
        PAGI::Exception::IncompleteResponse->new(message => 'missing stage');
    }, qr/stage is required/, 'missing stage is rejected');
    like(dies {
        PAGI::Exception::IncompleteResponse->new(stage => 'before_start');
    }, qr/message must be a defined scalar/, 'missing message is rejected');
    like(dies {
        PAGI::Exception::IncompleteResponse->new;
    }, qr/stage is required/, 'empty construction is rejected');
};

subtest 'complete HTTP responses pass original events without rewriting' => sub {
    for my $case (
        {
            label => 'explicit false more',
            body  => { type => 'http.response.body', body => 'ok', more => 0 },
        },
        {
            label => 'absent more',
            body  => { type => 'http.response.body', body => 'ok' },
        },
        {
            label => 'terminal sendfile body',
            body  => {
                type => 'http.response.body', file => '/tmp/example',
                offset => 4, length => 12,
            },
        },
    ) {
        my $start = {
            type => 'http.response.start', status => 200, headers => [],
        };
        my $body = $case->{body};
        my $events = run_guard(sub {
            my ($request_scope, $receive, $send) = @_;
            $send->($start)->get;
            return $send->($body);
        });
        is($events, [$start, $body], "$case->{label} completes normally");
        is(refaddr($events->[0]), refaddr($start),
            "$case->{label} start passes by identity");
        is(refaddr($events->[1]), refaddr($body),
            "$case->{label} body passes by identity");
    }
};

subtest 'normal incomplete completion throws the exact typed stage' => sub {
    my @cases = (
        {
            label   => 'no response events',
            stage   => 'before_start',
            message => 'HTTP application completed without starting a response',
            app     => sub { return },
        },
        {
            label   => 'response start without terminal body',
            stage   => 'after_start',
            message => 'HTTP application completed after response start without a terminal body',
            app     => sub {
                my ($request_scope, $receive, $send) = @_;
                $send->({
                    type => 'http.response.start', status => 200, headers => [],
                })->get;
                return $send->({
                    type => 'http.response.body', body => 'streaming', more => 1,
                });
            },
        },
    );

    for my $case (@cases) {
        my $error = guard_error($case->{app});
        isa_ok($error, ['PAGI::Exception::IncompleteResponse'], $case->{label});
        is($error->stage, $case->{stage}, "$case->{label} has the exact stage");
        is("$error", $case->{message}, "$case->{label} has the exact message");
    }
};

# PAGI::Spec::Www exempts a request whose client already disconnected from
# both incomplete-response rules ("Application Left a Response Incomplete" and
# "Application Produced No Response"): the request already ended abnormally
# with its own disconnect reason, so it is not an application error. A
# streaming response deliberately omits its terminal event in that case, so
# without this carve-out every abandoned stream fails its application Future.
#
# The discriminator is a defined disconnect_reason, not is_connected: a clean
# completion also flips is_connected, and must still be guarded.
{
    package DisconnectedConn;
    sub new {
        my ($class, %args) = @_;
        return bless { reason => $args{reason} }, $class;
    }
    sub is_connected      { return $_[0]->{reason} ? 0 : 1 }
    sub disconnect_reason { return $_[0]->{reason} }
    sub on_disconnect     { return }
}

sub disconnected_scope {
    my ($reason) = @_;
    my $request_scope = scope();
    $request_scope->{'pagi.connection'}
        = DisconnectedConn->new(reason => $reason);
    return $request_scope;
}

subtest 'a client that disconnected mid-response is not an application error' => sub {
    my $streamed = sub {
        my ($request_scope, $receive, $send) = @_;
        $send->({ type => 'http.response.start', status => 200, headers => [] })->get;
        # Producer stops here because the client vanished; no terminal event.
        return $send->({ type => 'http.response.body', body => 'partial', more => 1 });
    };

    my $events;
    ok(lives { $events = run_guard($streamed, disconnected_scope('client_closed')) },
        'an incomplete stream does not raise once the client has disconnected')
        or note($@);
    is(scalar @$events, 2, 'the events the application did send are still forwarded');

    my $never_started = sub { return };
    ok(lives { run_guard($never_started, disconnected_scope('client_closed')) },
        'a response never started does not raise once the client has disconnected')
        or note($@);

    my $declared_trailers = sub {
        my ($request_scope, $receive, $send) = @_;
        $send->({
            type => 'http.response.start', status => 200, headers => [], trailers => 1,
        })->get;
        return $send->({ type => 'http.response.body', body => 'partial', more => 0 });
    };
    ok(lives { run_guard($declared_trailers, disconnected_scope('write_error')) },
        'undelivered declared trailers do not raise once the client has disconnected')
        or note($@);
};

subtest 'the carve-out is limited to abnormal ends and real protocol faults' => sub {
    my $incomplete = sub {
        my ($request_scope, $receive, $send) = @_;
        $send->({ type => 'http.response.start', status => 200, headers => [] })->get;
        return $send->({ type => 'http.response.body', body => 'partial', more => 1 });
    };

    # A connection object that is still connected must not suppress anything.
    my $error = guard_error($incomplete, disconnected_scope(undef));
    isa_ok($error, ['PAGI::Exception::IncompleteResponse'],
        'a still-connected request still reports an incomplete response');
    is($error->stage, 'after_start', 'and keeps its exact stage');

    # A body before response start is an application protocol fault, not an
    # incompleteness, so a disconnect never excuses it.
    my $body_first = sub {
        my ($request_scope, $receive, $send) = @_;
        return $send->({ type => 'http.response.body', body => 'early', more => 0 });
    };
    my $fault = guard_error($body_first, disconnected_scope('client_closed'));
    isa_ok($fault, ['PAGI::Exception::IncompleteResponse'],
        'a body before start still raises even after a disconnect');
    is($fault->stage, 'body_before_start', 'and keeps the body_before_start stage');
};

subtest 'a body before start is reported even when the app ignored the rejection' => sub {
    # The subtest above returns the rejected Future to the guard, so the error
    # that surfaces is the send-time Future->fail -- the post-completion
    # re-raise never runs, and that subtest passes even if the disconnect
    # exemption is moved above it.
    #
    # An application that swallows the rejection is the only case that
    # exercises the re-raise, which ResponseGuard keeps "in case it doesn't
    # await/inspect this". It is therefore also the only case that can catch
    # the exemption overtaking it.
    my $ignores_rejection = sub {
        my ($request_scope, $receive, $send) = @_;
        my $else_done = $send->({
            type => 'http.response.body', body => 'early', more => 0,
        })->else_done();            # swallow it, as a careless app would
        return Future->done;
    };

    my $fault = guard_error($ignores_rejection, disconnected_scope('client_closed'));
    isa_ok($fault, ['PAGI::Exception::IncompleteResponse'],
        'a body before start is reported even when the app ignored the rejection');
    is($fault->stage, 'body_before_start', 'and keeps the body_before_start stage');
};

subtest 'declared trailers are required before completion' => sub {
    my $start = {
        type => 'http.response.start', status => 200, headers => [], trailers => 1,
    };
    my $body = { type => 'http.response.body', body => 'ok', more => 0 };
    my $trailers = { type => 'http.response.trailers', headers => [['x-checksum', 'abc']] };

    my $events = run_guard(sub {
        my ($request_scope, $receive, $send) = @_;
        $send->($start)->get;
        $send->($body)->get;
        return $send->($trailers);
    });
    is($events, [$start, $body, $trailers],
        'start, body, and trailers all pass through when trailers are sent');

    my $error = guard_error(sub {
        my ($request_scope, $receive, $send) = @_;
        $send->($start)->get;
        return $send->($body);
    });
    isa_ok($error, ['PAGI::Exception::IncompleteResponse']);
    is($error->stage, 'awaiting_trailers',
        'declaring trailers and completing without sending them is a typed failure');
    is("$error", 'HTTP application completed after declaring trailers without sending them',
        'the awaiting_trailers stage has its own diagnostic message');
};

subtest 'body before start rejects via a failed Future, not a synchronous die' => sub {
    my $invalid = {
        type => 'http.response.body', body => 'out of order', more => 0,
    };
    my ($send, $events) = capture_send();
    my $captured;
    my $app = PAGI::Compose::ResponseGuard->wrap(sub {
        my ($request_scope, $receive, $guard_send) = @_;
        # Call guard_send but don't await/get its result: proves the call
        # itself does not die synchronously -- it must hand back a rejected
        # Future instead, for contract parity with how the real server
        # rejects an invalid send.
        $captured = $guard_send->($invalid);
        return Future->done;
    });
    # The app itself ignores the failed Future and completes normally, but
    # the guard still preserves reject-without-forwarding overall: it
    # re-raises the same typed exception once the application completes,
    # which is not what this subtest is checking (see the next subtest).
    eval {
        Future->wrap($app->(
            scope(), sub { return Future->done }, $send,
        ))->get;
    };

    isa_ok($captured, ['Future']);
    ok($captured->is_failed, 'guard_send returned an already-failed Future');
    my ($failure) = $captured->failure;
    isa_ok($failure, ['PAGI::Exception::IncompleteResponse']);
    is($failure->stage, 'body_before_start', 'the failed Future carries the typed exception');
    is($events, [], 'the invalid event never reached the outer send');
};

subtest 'body before start is rejected without reaching the outer send' => sub {
    my $invalid = {
        type => 'http.response.body', body => 'out of order', more => 0,
    };
    my ($send, $events) = capture_send();
    my $app = PAGI::Compose::ResponseGuard->wrap(sub {
        my ($request_scope, $receive, $guard_send) = @_;
        return $guard_send->($invalid);
    });
    my $error;
    eval {
        Future->wrap($app->(
            scope(), sub { return Future->done }, $send,
        ))->get;
        1;
    } or $error = $@;

    is($events, [], 'invalid body event is not forwarded');
    isa_ok($error, ['PAGI::Exception::IncompleteResponse']);
    is($error->stage, 'body_before_start', 'the exact guard stage is thrown');
    is("$error", 'HTTP application sent a response body before response start',
        'the typed exception retains the exact diagnostic');
};

{
    package Local::GuardInnerError;
    use overload q{""} => sub { return 'inner application failed' }, fallback => 1;
    sub new { return bless {}, $_[0] }
}

subtest 'inner exceptions are never replaced by lifecycle validation' => sub {
    for my $case ({ label => 'before response start' }, { label => 'after response start' }) {
        my $inner_error;
        my $app = sub {
            my $error = Local::GuardInnerError->new;
            $inner_error = $error;
            if ($case->{label} eq 'after response start') {
                my ($request_scope, $receive, $send) = @_;
                $send->({
                    type => 'http.response.start', status => 200, headers => [],
                })->get;
            }
            die $error;
        };
        my $caught = guard_error($app);
        is(refaddr($caught), refaddr($inner_error),
            "$case->{label} preserves the exact exception object");
        ok(!blessed($caught) || !$caught->isa('PAGI::Exception::IncompleteResponse'),
            "$case->{label} is not replaced by guard validation");
    }
};

subtest 'non-HTTP scopes pass all channels through by identity' => sub {
    my @seen;
    my $inner = sub {
        @seen = map { refaddr($_) } @_;
        return;
    };
    my $app = PAGI::Compose::ResponseGuard->wrap($inner);
    my $extension_scope = scope(type => 'example.extension');
    my $receive = sub { return Future->done };
    my $send = sub { return Future->done };
    Future->wrap($app->($extension_scope, $receive, $send))->get;
    is(\@seen, [map { refaddr($_) } ($extension_scope, $receive, $send)],
        'scope receive and send identities are unchanged');
};

subtest 'compiled Compose response-guard state is lexical under interleaving' => sub {
    my (%send_for, %done_for);
    my $app = compose(routes => [route('/{id}' => as_app_object(sub {
        my ($request_scope, $receive, $send) = @_;
        my $id = $request_scope->{path};
        $send_for{$id} = $send;
        $done_for{$id} = Future->new;
        return $done_for{$id};
    }))])->to_app;
    my ($transport_one, $events_one) = capture_send();
    my ($transport_two, $events_two) = capture_send();
    my $one = $app->(
        scope(path => '/one'), sub { return Future->done }, $transport_one,
    );
    my $two = $app->(
        scope(path => '/two'), sub { return Future->done }, $transport_two,
    );

    $send_for{'/one'}->({
        type => 'http.response.start', status => 200, headers => [],
    })->get;
    $send_for{'/one'}->({
        type => 'http.response.body', body => 'one', more => 0,
    })->get;
    $done_for{'/one'}->done;
    $one->get;

    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $done_for{'/two'}->done;
        $two->get;
    }
    is($events_one, [
        { type => 'http.response.start', status => 200, headers => [] },
        { type => 'http.response.body', body => 'one', more => 0 },
    ], 'first request completes with its own observed lifecycle');
    is($events_two->[0]{status}, 500,
        'silent second request receives its own safe 500');
    is(scalar(grep { ($_->{type} // '') eq 'http.response.start' } @$events_two),
        1, 'second request receives exactly one independent response start');
    is(scalar @warnings, 1, 'only the silent request is reported');
    like($warnings[0], qr/completed without starting a response/,
        'second request retains its independent before-start stage');
};

done_testing;
