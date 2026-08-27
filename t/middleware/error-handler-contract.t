#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use IO::Async::Loop;
use Encode qw(decode FB_CROAK LEAVE_SRC);
use Scalar::Util qw(refaddr);

use lib 'lib';

use PAGI::Middleware::ErrorHandler;
use PAGI::Pages ();

my $loop = IO::Async::Loop->new;

sub invoke {
    my ($middleware, $app, $scope) = @_;
    my @events;
    my $future = Future->wrap($middleware->wrap($app)->(
        $scope || { type => 'http', path => '/' },
        sub { Future->done({ type => 'http.disconnect' }) },
        sub {
            my ($event) = @_;
            push @events, $event;
            return Future->done;
        },
    ));
    return ($future, \@events);
}

sub invoke_with_send {
    my ($middleware, $app, $send, $scope) = @_;
    return Future->wrap($middleware->wrap($app)->(
        $scope || { type => 'http', path => '/' },
        sub { Future->done({ type => 'http.disconnect' }) },
        $send,
    ));
}

sub settle {
    my ($future) = @_;
    $loop->await($future->else(sub { Future->done }));
    return $future;
}

sub header_value {
    my ($event, $name) = @_;
    for my $header (@{$event->{headers} || []}) {
        return $header->[1] if lc($header->[0]) eq lc($name);
    }
    return undef;
}

{
    package Local::StatusError;
    use overload q{""} => sub { $_[0]{message} }, fallback => 1;
    sub new {
        my ($class, $status, $message) = @_;
        return bless { status => $status, message => $message }, $class;
    }
    sub status_code { $_[0]{status} }
}

{
    package Local::ThrowingStatusError;
    use overload q{""} => sub { 'original throwing-status exception' }, fallback => 1;
    sub new { bless {}, shift }
    sub status_code { die "status accessor failed\n" }
}

{
    package Local::ThrowingStringError;
    use overload q{""} => sub { die "stringification failed\n" }, fallback => 1;
    sub new { bless {}, shift }
    sub status_code { 500 }
}

{
    package Local::HostileRejectedStatusError;
    use overload q{""} => sub { die "hostile stringification failed\n" }, fallback => 1;
    sub new { bless {}, shift }
    sub status_code { 'not-a-status' }
}

{
    package Local::DetachedResponse;
    sub new { bless {}, shift }
    sub respond {
        my ($self, $send) = @_;
        return (async sub {
            await Future->wrap($send->({
                type    => 'http.response.start',
                status  => 422,
                headers => [['content-type', 'application/detached']],
            }));
            await Future->wrap($send->({
                type => 'http.response.body', body => 'detached', more => 0,
            }));
            return;
        })->();
    }
}

subtest 'public defaults and options are exact and environment-independent' => sub {
    local $ENV{PAGI_ENV} = 'definitely-invalid';
    my $middleware;
    is dies { $middleware = PAGI::Middleware::ErrorHandler->new }, undef,
        'construction does not consult PAGI_ENV';
    is($middleware->{development}, 0, 'development defaults to false');
    is($middleware->{status}, 500, 'status defaults to 500');
    is($middleware->{on_error}, undef, 'on_error defaults to undef');
    is($middleware->{handler}, undef, 'handler defaults to undef');
    for my $option (qw(content_type pages as renderer unknown)) {
        like dies {
            PAGI::Middleware::ErrorHandler->new($option => 'value')
        }, qr/unknown ErrorHandler option '\Q$option\E'/,
            "$option is not a public ErrorHandler option";
    }
    my ($future, $events) = invoke($middleware, async sub {
        die "private details";
    });
    settle($future);

    ok $future->is_done, 'invalid environment does not affect handling';
    like header_value($events->[0], 'content-type'), qr{^text/html},
        'ordinary default negotiates to Pages HTML';
    unlike $events->[1]{body}, qr/private details/,
        'ordinary default remains production-safe';
};

subtest 'every negotiated built-in representation disables caching' => sub {
    my @cases = (
        ['text/html', 'text/html; charset=utf-8'],
        ['text/plain', 'text/plain; charset=utf-8'],
        ['application/problem+json', 'application/problem+json'],
    );
    for my $case (@cases) {
        my ($accept, $content_type) = @$case;
        my ($future, $events) = invoke(
            PAGI::Middleware::ErrorHandler->new,
            async sub { die "built-in failure" },
            {
                type => 'http', path => '/',
                headers => [['Accept' => $accept]],
            },
        );
        settle($future);
        is header_value($events->[0], 'content-type'), $content_type,
            "$accept selects $content_type";
        is header_value($events->[0], 'cache-control'), 'no-store',
            "$accept carries Cache-Control: no-store";
    }
};

subtest 'configured built-in statuses must be complete registered Pages errors' => sub {
    my $middleware;
    is dies {
        $middleware = PAGI::Middleware::ErrorHandler->new(status => 404)
    }, undef, 'registered complete status is accepted';
    my ($future, $events) = invoke($middleware, async sub { die "missing\n" });
    settle($future);
    is $events->[0]{status}, 404, 'configured registered status is emitted';

    for my $status (401, 405, 407, 426, 418, 302, 'malformed', Future->done(500)) {
        like dies {
            PAGI::Middleware::ErrorHandler->new(status => $status)
        }, qr/handler is required/i,
            'incomplete, unknown, non-error, or reference status requires a handler';
    }
};

subtest 'Pages integration adapts the two-argument ErrorHandler seam' => sub {
    my $middleware = PAGI::Middleware::ErrorHandler->new(
        handler => sub {
            my ($context, $error) = @_;
            return PAGI::Pages->internal_server_error(
                $context,
                as => 'json',
            );
        },
    );
    my ($future, $events) = invoke(
        $middleware,
        async sub { die "database failed\n" },
    );
    settle($future);

    ok $future->is_done, 'wrapped Pages renderer completes successfully';
    is scalar(@$events), 2, 'wrapped Pages renderer completes the response';
    is $events->[0]{status}, 500, 'Pages renderer emits the error status';
    is header_value($events->[0], 'content-type'),
        'application/problem+json', 'configured Pages representation is used';
    is $events->[1]{type}, 'http.response.body',
        'Pages renderer emits the response body';
    is $events->[1]{more}, 0, 'Pages renderer emits a terminal body event';
};

subtest 'immediate custom renderer receives and preserves exception status' => sub {
    my $error = Local::StatusError->new(418, 'teapot');
    my ($seen_context, $seen_error, $seeded_status);
    my $middleware = PAGI::Middleware::ErrorHandler->new(
        handler => sub {
            my ($context, $original) = @_;
            ($seen_context, $seen_error) = ($context, $original);
            $seeded_status = $context->response->status;
            return $context->json({ error => 'custom' });
        },
    );
    my ($future, $events) = invoke($middleware, async sub { die $error });
    settle($future);

    ok $future->is_done, 'custom renderer completes';
    is refaddr($seen_error), refaddr($error), 'renderer receives original object';
    isa_ok $seen_context, ['PAGI::Context::HTTP'];
    is $seeded_status, 418, 'cached response is seeded from blessed exception';
    is $events->[0]{status}, 418, 'seeded exception status is emitted';
    is header_value($events->[0], 'content-type'), 'application/json',
        'renderer selects its own content type';
};

subtest 'Future custom renderer owns explicit status and headers' => sub {
    my $seeded_status;
    my $middleware = PAGI::Middleware::ErrorHandler->new(
        status  => 401,
        handler => sub {
            my ($context, $error) = @_;
            $seeded_status = $context->response->status;
            return Future->done($context->text(
                'custom future',
                status       => 409,
                content_type => 'application/vnd.error+json',
                headers      => ['Cache-Control' => 'public, max-age=60'],
            ));
        },
    );
    my ($future, $events) = invoke($middleware, async sub { die "conflict" });
    settle($future);

    is $seeded_status, 401,
        'custom renderer retains a normally incomplete configured status seed';
    is $events->[0]{status}, 409, 'explicit renderer status wins over seed';
    is header_value($events->[0], 'content-type'), 'application/vnd.error+json',
        'custom content type is untouched';
    is header_value($events->[0], 'cache-control'), 'public, max-age=60',
        'custom cache policy is untouched';
};

subtest 'invalid exception status claim reaches custom handler with a safe seed' => sub {
    my $error = Local::StatusError->new(999, 'out-of-range secret');
    my (@reported, @warnings);
    my ($seeded_status, $handler_error);
    my $middleware = PAGI::Middleware::ErrorHandler->new(
        on_error => sub { push @reported, $_[0]; return Future->done },
        handler  => sub {
            my ($context, $received_error) = @_;
            $seeded_status = $context->response->status;
            $handler_error = $received_error;
            return $context->text('safe custom response');
        },
    );

    my ($future, $events);
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        ($future, $events) = invoke($middleware, async sub { die $error });
        settle($future);
    }

    ok $future->is_done, 'out-of-range claim is contained';
    is $seeded_status, 500, 'custom handler receives a safe status seed';
    is refaddr($handler_error), refaddr($error),
        'custom handler receives the original exception object';
    is refaddr($reported[0]), refaddr($error),
        'on_error reports the original exception object';
    is $events->[0]{status}, 500, 'custom response keeps the safe seed by default';
    is $events->[1]{body}, 'safe custom response',
        'custom handler still owns the response body';
    is scalar(@warnings), 1, 'one rejected-claim diagnostic is emitted';
    like $warnings[0],
        qr/rejected exception status_code claim: status 999 is outside 100-599/,
        'diagnostic identifies the out-of-range claim';
};

subtest 'built-in exception status claims are guarded and Pages-valid' => sub {
    my @cases = (
        ['registered 404', Local::StatusError->new(404, 'missing secret'), 404, undef],
        ['unknown 418', Local::StatusError->new(418, 'teapot secret'), 500,
            qr/rejected exception status_code claim: status 418 is not a complete registered Pages error/],
        ['incomplete 401', Local::StatusError->new(401, 'auth secret'), 500,
            qr/rejected exception status_code claim: status 401 is not a complete registered Pages error/],
        ['incomplete 405', Local::StatusError->new(405, 'allow secret'), 500,
            qr/rejected exception status_code claim: status 405 is not a complete registered Pages error/],
        ['incomplete 407', Local::StatusError->new(407, 'proxy secret'), 500,
            qr/rejected exception status_code claim: status 407 is not a complete registered Pages error/],
        ['incomplete 426', Local::StatusError->new(426, 'upgrade secret'), 500,
            qr/rejected exception status_code claim: status 426 is not a complete registered Pages error/],
        ['non-error 302', Local::StatusError->new(302, 'redirect secret'), 500,
            qr/rejected exception status_code claim: status 302 is not a complete registered Pages error/],
        ['malformed scalar', Local::StatusError->new('wat', 'malformed secret'), 500,
            qr/rejected exception status_code claim: nonnumeric scalar result/],
        ['Future value', Local::StatusError->new(Future->done(404), 'future secret'), 500,
            qr/rejected exception status_code claim: reference-valued result/],
        ['failed Future value',
            Local::StatusError->new(Future->fail('status future failed'), 'failed future secret'),
            500, qr/rejected exception status_code claim: reference-valued result/],
        ['throwing accessor', Local::ThrowingStatusError->new, 500,
            qr/rejected exception status_code claim: status_code accessor failed/],
    );

    for my $case (@cases) {
        my ($label, $error, $expected, $diagnostic) = @$case;
        my @reported;
        my @warnings;
        my ($future, $events);
        {
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            ($future, $events) = invoke(
                PAGI::Middleware::ErrorHandler->new(
                    on_error => sub { push @reported, $_[0]; return Future->done },
                ),
                async sub { die $error },
                {
                    type => 'http', path => '/',
                    headers => [['Accept' => 'application/problem+json']],
                },
            );
            settle($future);
        }
        ok $future->is_done, "$label is contained";
        is $events->[0]{status}, $expected, "$label selects safe status $expected";
        is refaddr($reported[0]), refaddr($error),
            "$label reports the original exception object";
        if ($diagnostic) {
            is scalar(@warnings), 1, "$label emits one framework diagnostic";
            like $warnings[0], $diagnostic,
                "$label diagnostic identifies the rejected claim";
        }
        else {
            is \@warnings, [], "$label emits no rejected-claim diagnostic";
        }
        my $problem = JSON::MaybeXS::decode_json($events->[1]{body});
        is $problem->{status}, $expected, "$label problem status matches the wire";
        unlike $problem->{detail}, qr/secret|accessor failed|original throwing-status/,
            "$label production response exposes no exception diagnostics";
    }
};

subtest 'rejected-status diagnostics are safe and failure-contained' => sub {
    my $hostile = Local::HostileRejectedStatusError->new;
    my @reported;
    my @warnings;
    my ($future, $events);
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        ($future, $events) = invoke(
            PAGI::Middleware::ErrorHandler->new(
                on_error => sub { push @reported, $_[0]; return },
            ),
            sub { die $hostile },
        );
        settle($future);
    }

    ok $future->is_done, 'hostile rejected status is contained';
    is refaddr($reported[0]), refaddr($hostile),
        'hostile original exception reaches the reporter';
    is $events->[0]{status}, 500, 'hostile claim uses the safe response status';
    is scalar(@warnings), 1, 'hostile claim emits one framework diagnostic';
    like $warnings[0], qr/nonnumeric scalar result/,
        'diagnostic identifies the rejection without stringifying the exception';
    unlike $warnings[0], qr/hostile stringification failed/,
        'diagnostic contains no hostile exception stringification data';
    unlike $events->[1]{body}, qr/hostile|stringification|not-a-status/,
        'production response contains neither exception nor claimed status data';

    my $diagnostic_error = bless {}, 'Local::DiagnosticFailure';
    my $original = Local::StatusError->new(418, 'report me');
    @reported = ();
    {
        local $SIG{__WARN__} = sub { die $diagnostic_error };
        ($future, $events) = invoke(
            PAGI::Middleware::ErrorHandler->new(
                on_error => sub { push @reported, $_[0]; return Future->done },
            ),
            async sub { die $original },
        );
        settle($future);
    }

    ok $future->is_done, 'throwing diagnostic sink is contained';
    is refaddr($reported[0]), refaddr($original),
        'diagnostic failure cannot replace the original reporter value';
    is $events->[0]{status}, 500,
        'diagnostic failure cannot alter the safe response status';
    is scalar(grep { $_->{type} eq 'http.response.start' } @$events), 1,
        'diagnostic failure does not cause a second response start';
};

subtest 'throwing exception stringification cannot replace the safe response' => sub {
    my $error = Local::ThrowingStringError->new;
    my @reported;
    my ($future, $events) = invoke(
        PAGI::Middleware::ErrorHandler->new(
            development => 1,
            on_error => sub { push @reported, $_[0]; return },
        ),
        sub { die $error },
        {
            type => 'http', path => '/',
            headers => [['Accept' => 'text/plain']],
        },
    );
    settle($future);

    ok $future->is_done, 'throwing string overload is contained';
    is $events->[0]{status}, 500, 'throwing string overload retains safe status 500';
    is refaddr($reported[0]), refaddr($error), 'reporter receives the original object';
    unlike $events->[1]{body}, qr/stringification failed/,
        'stringification failure is absent from development output';
    like $events->[1]{body}, qr/Internal Server Error/,
        'catalog-safe detail remains available';
};

subtest 'response validation uses the shared response contract' => sub {
    my $middleware = PAGI::Middleware::ErrorHandler->new(
        handler => sub { Local::DetachedResponse->new },
    );
    my ($future, $events) = invoke($middleware, async sub { die "detached" });
    settle($future);

    ok $future->is_done, 'detached response-like value is accepted';
    is $events->[0]{status}, 422, 'detached response controls emitted status';
    is header_value($events->[0], 'content-type'), 'application/detached',
        'detached response headers pass through';
};

subtest 'invalid renderer return has the standard diagnostic' => sub {
    my $middleware = PAGI::Middleware::ErrorHandler->new(
        handler => sub { 'not a response' },
    );
    my ($future, $events) = invoke($middleware, async sub { die "original" });
    settle($future);

    ok $future->is_failed, 'invalid renderer result fails outward';
    like $future->failure, qr/handler did not return a response/,
        'invalid result uses the shared handler diagnostic';
    is scalar(@$events), 0, 'invalid result emits no response';
};

subtest 'renderer exception propagates outward' => sub {
    my $renderer_error = Local::StatusError->new(599, 'renderer exploded');
    my $middleware = PAGI::Middleware::ErrorHandler->new(
        handler => sub { die $renderer_error },
    );
    my ($future, $events) = invoke($middleware, async sub { die "original" });
    settle($future);

    ok $future->is_failed, 'renderer failure is not swallowed';
    is refaddr($future->failure), refaddr($renderer_error),
        'renderer exception object propagates unchanged';
    is scalar(@$events), 0, 'renderer failure emits no response';
};

subtest 'immediate and Future reporting complete before rendering' => sub {
    my @immediate_seen;
    my ($immediate, $immediate_events) = invoke(
        PAGI::Middleware::ErrorHandler->new(
            on_error => sub { push @immediate_seen, $_[0]; return undef },
        ),
        async sub { die "immediate report\n" },
    );
    settle($immediate);
    is \@immediate_seen, ["immediate report\n"],
        'immediate reporter receives the original string';
    is scalar(@$immediate_events), 2, 'immediate reporting still renders';

    my $gate = Future->new;
    my @future_seen;
    my ($future, $events) = invoke(
        PAGI::Middleware::ErrorHandler->new(
            on_error => sub { push @future_seen, $_[0]; return $gate },
        ),
        async sub { die "Future report\n" },
    );
    ok !$future->is_ready, 'handling waits for Future-backed reporting';
    is scalar(@$events), 0, 'rendering waits for reporting settlement';
    $gate->done;
    settle($future);
    is \@future_seen, ["Future report\n"],
        'Future reporter receives the original string';
    is scalar(@$events), 2, 'rendering proceeds after reporting settles';
};

subtest 'reporting failures never prevent rendering' => sub {
    my @reporters = (
        ['synchronous throw' => sub { die "reporter threw\n" }],
        ['failed Future'     => sub { Future->fail("reporter failed\n") }],
    );
    for my $case (@reporters) {
        my ($name, $reporter) = @$case;
        my ($future, $events) = invoke(
            PAGI::Middleware::ErrorHandler->new(on_error => $reporter),
            async sub { die "application failed\n" },
        );
        settle($future);
        ok $future->is_done, "$name is contained";
        is scalar(@$events), 2, "$name does not prevent rendering";
        like $events->[1]{body}, qr/Internal Server Error/,
            "$name does not replace the application failure path";
    }
};

subtest 'post-start reporting settles before original object is rethrown' => sub {
    my $original = Local::StatusError->new(598, 'post-start object');
    my $gate = Future->new;
    my ($reported, $renderer_calls) = (undef, 0);
    my $middleware = PAGI::Middleware::ErrorHandler->new(
        on_error => sub { $reported = $_[0]; return $gate },
        handler  => sub { $renderer_calls++; die "must not render" },
    );
    my ($future, $events) = invoke($middleware, async sub {
        my ($scope, $receive, $send) = @_;
        await Future->wrap($send->({
            type => 'http.response.start', status => 200, headers => [],
        }));
        die $original;
    });

    ok !$future->is_ready, 'post-start failure waits for reporter';
    is scalar(@$events), 1, 'only the application response start was emitted';
    $gate->done;
    settle($future);
    ok $future->is_failed, 'post-start failure propagates after reporting';
    is refaddr($reported), refaddr($original), 'reporter receives original object';
    is refaddr($future->failure), refaddr($original),
        'original exception object is rethrown unchanged';
    is $renderer_calls, 0, 'renderer is never called after response start';
    is scalar(grep { $_->{type} eq 'http.response.start' } @$events), 1,
        'no second response start is emitted';
};

subtest 'post-start reporting failure preserves original string' => sub {
    my $middleware = PAGI::Middleware::ErrorHandler->new(
        on_error => sub { Future->fail("secondary failure\n") },
    );
    my ($future, $events) = invoke($middleware, async sub {
        my ($scope, $receive, $send) = @_;
        await Future->wrap($send->({
            type => 'http.response.start', status => 200, headers => [],
        }));
        die "post-start string\n";
    });
    settle($future);

    ok $future->is_failed, 'post-start string propagates';
    is scalar($future->failure), "post-start string\n",
        'reporting failure does not replace original string';
    is scalar(grep { $_->{type} eq 'http.response.start' } @$events), 1,
        'reporting failure still emits no second start';
};

subtest 'outer send failures retain post-start failure semantics' => sub {
    my @cases = (
        ['synchronous', sub { die $_[0] }],
        ['failed Future', sub { Future->fail($_[0]) }],
    );

    for my $case (@cases) {
        my ($label, $fail_send) = @$case;
        my $send_error = bless {}, 'Local::OuterSendFailure';
        my @attempted;
        my @reported;
        my $renderer_calls = 0;
        my $middleware = PAGI::Middleware::ErrorHandler->new(
            on_error => sub { push @reported, $_[0]; return Future->done },
            handler  => sub { $renderer_calls++; die 'must not render' },
        );
        my $future = invoke_with_send(
            $middleware,
            async sub {
                my ($scope, $receive, $send) = @_;
                await Future->wrap($send->({
                    type => 'http.response.start', status => 200, headers => [],
                }));
            },
            sub {
                my ($event) = @_;
                push @attempted, $event;
                return $fail_send->($send_error);
            },
        );
        settle($future);

        ok $future->is_failed, "$label outer send failure propagates";
        is refaddr($future->failure), refaddr($send_error),
            "$label outer send failure identity is preserved";
        is [map { $_->{type} } @attempted], ['http.response.start'],
            "$label outer send makes no retry or replacement attempt";
        is scalar(@reported), 1, "$label outer send failure is reported once";
        is refaddr($reported[0]), refaddr($send_error),
            "$label reporter receives the original send failure";
        is $renderer_calls, 0,
            "$label post-start failure never invokes the renderer";
    }
};

subtest 'last-resort send failures propagate without retry' => sub {
    my @cases = (
        [
            'start failure',
            sub {
                my ($event, $send_error) = @_;
                die $send_error;
            },
            ['http.response.start'],
        ],
        [
            'body failure',
            sub {
                my ($event, $send_error) = @_;
                return Future->done
                    if $event->{type} eq 'http.response.start';
                return Future->fail($send_error);
            },
            ['http.response.start', 'http.response.body'],
        ],
    );

    for my $case (@cases) {
        my ($label, $send_result, $expected_types) = @$case;
        my $original = bless {}, 'Local::OriginalApplicationFailure';
        my $send_error = bless {}, 'Local::LastResortSendFailure';
        my @reported;
        my @attempted;
        my $middleware = PAGI::Middleware::ErrorHandler->new(
            on_error => sub { push @reported, $_[0]; return Future->done },
        );
        my $future;
        {
            no warnings 'redefine';
            local *PAGI::Pages::status = sub { die "private Pages failure\n" };
            $future = invoke_with_send(
                $middleware,
                async sub { die $original },
                sub {
                    my ($event) = @_;
                    push @attempted, $event;
                    return $send_result->($event, $send_error);
                },
            );
            settle($future);
        }

        ok $future->is_failed, "last-resort $label propagates";
        is refaddr($future->failure), refaddr($send_error),
            "last-resort $label preserves send failure identity";
        is [map { $_->{type} } @attempted], $expected_types,
            "last-resort $label makes no retry or second start";
        is scalar(@reported), 1,
            "last-resort $label does not report a replacement error";
        is refaddr($reported[0]), refaddr($original),
            "last-resort $label preserves original application reporting";
    }
};

subtest 'failed-Future custom handler and response send failures propagate' => sub {
    my $original = Local::StatusError->new(500, 'original application error');
    my $handler_error = bless {}, 'Local::HandlerFutureFailure';
    my @reported;
    my @attempted;
    my $handler_calls = 0;
    my $middleware = PAGI::Middleware::ErrorHandler->new(
        on_error => sub { push @reported, $_[0]; return Future->done },
        handler  => sub {
            $handler_calls++;
            return Future->fail($handler_error);
        },
    );
    my $future = invoke_with_send(
        $middleware,
        async sub { die $original },
        sub { push @attempted, $_[0]; return Future->done },
    );
    settle($future);

    ok $future->is_failed, 'failed-Future custom handler propagates';
    is refaddr($future->failure), refaddr($handler_error),
        'failed-Future custom handler preserves failure identity';
    is $handler_calls, 1, 'failed-Future custom handler is invoked once';
    is \@attempted, [], 'failed-Future custom handler emits no response';
    is scalar(@reported), 1, 'custom handler path reports only the application error';
    is refaddr($reported[0]), refaddr($original),
        'custom handler path preserves original application reporting';

    my $send_error = bless {}, 'Local::CustomResponseSendFailure';
    @reported = ();
    @attempted = ();
    $middleware = PAGI::Middleware::ErrorHandler->new(
        on_error => sub { push @reported, $_[0]; return Future->done },
        handler  => sub { Future->done(Local::DetachedResponse->new) },
    );
    $future = invoke_with_send(
        $middleware,
        async sub { die $original },
        sub {
            push @attempted, $_[0];
            return Future->fail($send_error);
        },
    );
    settle($future);

    ok $future->is_failed, 'failed-Future custom response send propagates';
    is refaddr($future->failure), refaddr($send_error),
        'failed-Future custom response send preserves failure identity';
    is [map { $_->{type} } @attempted], ['http.response.start'],
        'failed-Future custom response send makes no retry or second start';
    is scalar(@reported), 1,
        'custom response send path reports only the application error';
    is refaddr($reported[0]), refaddr($original),
        'custom response send path preserves original application reporting';
};

subtest 'built-in representations emit UTF-8 octets with byte lengths' => sub {
    my @cases = (
        ['text/plain', 'text/plain; charset=utf-8'],
        ['text/html', 'text/html; charset=utf-8'],
        ['application/problem+json', 'application/problem+json'],
    );
    for my $case (@cases) {
        my ($accept, $content_type) = @$case;
        my ($future, $events) = invoke(
            PAGI::Middleware::ErrorHandler->new(
                development => 1,
            ),
            async sub { die "snowman \x{2603}\n" },
            {
                type => 'http', path => '/',
                headers => [['Accept' => $accept]],
            },
        );
        settle($future);

        my $body = $events->[1]{body};
        is header_value($events->[0], 'content-type'), $content_type,
            "$accept is negotiated";
        ok !utf8::is_utf8($body), "$accept body is an octet string";
        is 0 + header_value($events->[0], 'content-length'), length($body),
            "$accept Content-Length is the emitted byte length";
        my $decoded = decode('UTF-8', $body, FB_CROAK | LEAVE_SRC);
        if ($accept eq 'application/problem+json') {
            require JSON::MaybeXS;
            my $data = JSON::MaybeXS::decode_json($body);
            is $data->{detail}, "snowman \x{2603}\n",
                'problem JSON contains the wide detail exactly once';
        }
        else {
            like $decoded, qr/snowman \x{2603}/,
                "$accept decodes to the original wide error";
        }
    }
};

subtest 'Pages construction failure uses the hardcoded pre-start response' => sub {
    my @reported;
    my $middleware = PAGI::Middleware::ErrorHandler->new(
        on_error => sub { push @reported, $_[0]; return Future->done },
    );
    my ($future, $events);
    {
        no warnings 'redefine';
        local *PAGI::Pages::status = sub { die "private Pages failure\n" };
        ($future, $events) = invoke(
            $middleware,
            async sub { die "original application failure\n" },
            {
                type => 'http', path => '/',
                headers => [['Accept' => 'application/problem+json']],
            },
        );
        settle($future);
    }

    ok $future->is_done, 'Pages construction failure is contained before start';
    is scalar(@$events), 2, 'last resort emits exactly start and body events';
    is $events->[0]{status}, 500, 'last resort status is 500';
    is header_value($events->[0], 'content-type'), 'text/plain; charset=utf-8',
        'last resort has its hardcoded UTF-8 text content type';
    is header_value($events->[0], 'cache-control'), 'no-store',
        'last resort is not cacheable';
    is $events->[1]{body}, "Internal Server Error\n",
        'last resort body is exact and contains no dynamic data';
    is 0 + header_value($events->[0], 'content-length'),
        length($events->[1]{body}), 'last resort byte length is exact';
    is \@reported, ["original application failure\n"],
        'reporting remains about the original application exception';
};

subtest 'missing scope type is HTTP without warnings' => sub {
    my @warnings;
    my ($future, $events);
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        ($future, $events) = invoke(
            PAGI::Middleware::ErrorHandler->new,
            async sub { die "missing type\n" },
            { path => '/' },
        );
        settle($future);
    }
    ok $future->is_done, 'missing type is handled as HTTP';
    is scalar(@$events), 2, 'missing type receives an error response';
    is \@warnings, [], 'missing type emits no warnings';
};

subtest 'private development resolver is not a public option' => sub {
    like dies {
        PAGI::Middleware::ErrorHandler->new(
            _development_resolver => sub { 1 },
        )
    }, qr/unknown ErrorHandler option '_development_resolver'/,
        'ordinary construction rejects the private key';
};

subtest 'Compose failsafe resolves development per handled request' => sub {
    my $calls = 0;
    my $middleware = PAGI::Middleware::ErrorHandler->_new_compose_failsafe(
        _development_resolver => sub { ++$calls == 1 ? 1 : 0 },
    );
    my ($first, $first_events) = invoke(
        $middleware, async sub { die "first private detail\n" },
    );
    settle($first);
    my ($second, $second_events) = invoke(
        $middleware, async sub { die "second private detail\n" },
    );
    settle($second);

    is $calls, 2, 'resolver runs once for each handled request';
    like $first_events->[1]{body}, qr/first private detail/,
        'first request uses resolved development mode';
    unlike $second_events->[1]{body}, qr/second private detail/,
        'second request uses newly resolved production mode';
    like $second_events->[1]{body}, qr/Internal Server Error/,
        'production resolution uses the safe built-in message';
};

subtest 'Compose resolver failure is reported and rendered safely' => sub {
    my @reported;
    my $middleware = PAGI::Middleware::ErrorHandler->_new_compose_failsafe(
        _development_resolver => sub { die "invalid environment\n" },
        on_error              => sub { push @reported, $_[0]; Future->done },
    );
    my ($future, $events) = invoke(
        $middleware, async sub { die "database password exposed\n" },
    );
    settle($future);

    ok $future->is_done, 'resolver failure cannot escape the failsafe';
    is scalar(@reported), 2, 'application and resolver failures are reported';
    is $reported[0], "database password exposed\n",
        'original application failure is reported first';
    is $reported[1], "invalid environment\n",
        'resolver failure is separately reported';
    unlike $events->[1]{body}, qr/database password|invalid environment/,
        'resolver failure falls back to production-safe output';
    like $events->[1]{body}, qr/Internal Server Error/,
        'safe production response is still rendered';
};

done_testing;
