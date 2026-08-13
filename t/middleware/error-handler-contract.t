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

subtest 'ordinary defaults are static production HTML' => sub {
    local $ENV{PAGI_ENV} = 'definitely-invalid';
    my $middleware;
    is dies { $middleware = PAGI::Middleware::ErrorHandler->new }, undef,
        'construction does not consult PAGI_ENV';
    my ($future, $events) = invoke($middleware, async sub {
        die "private details";
    });
    settle($future);

    ok $future->is_done, 'invalid environment does not affect handling';
    like header_value($events->[0], 'content-type'), qr{^text/html},
        'ordinary default remains HTML';
    unlike $events->[1]{body}, qr/private details/,
        'ordinary default remains production-safe';
};

subtest 'every built-in representation disables caching' => sub {
    for my $content_type ('text/html', 'text/plain', 'application/json') {
        my ($future, $events) = invoke(
            PAGI::Middleware::ErrorHandler->new(content_type => $content_type),
            async sub { die "built-in failure" },
        );
        settle($future);
        is header_value($events->[0], 'cache-control'), 'no-store',
            "$content_type carries Cache-Control: no-store";
    }
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
        content_type => 'text/html',
        handler      => sub {
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

    is $seeded_status, 500, 'cached response is seeded with the default status';
    is $events->[0]{status}, 409, 'explicit renderer status wins over seed';
    is header_value($events->[0], 'content-type'), 'application/vnd.error+json',
        'custom content type is untouched';
    is header_value($events->[0], 'cache-control'), 'public, max-age=60',
        'custom cache policy is untouched';
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

subtest 'built-in representations emit UTF-8 octets with byte lengths' => sub {
    for my $content_type ('text/plain', 'text/html', 'application/json') {
        my ($future, $events) = invoke(
            PAGI::Middleware::ErrorHandler->new(
                content_type => $content_type,
                development  => 1,
            ),
            async sub { die "snowman \x{2603}\n" },
        );
        settle($future);

        my $body = $events->[1]{body};
        ok !utf8::is_utf8($body), "$content_type body is an octet string";
        is 0 + header_value($events->[0], 'content-length'), length($body),
            "$content_type Content-Length is the emitted byte length";
        my $decoded = decode('UTF-8', $body, FB_CROAK | LEAVE_SRC);
        if ($content_type eq 'application/json') {
            require JSON::MaybeXS;
            my $data = JSON::MaybeXS::decode_json($body);
            is $data->{error}, "snowman \x{2603}\n",
                'JSON contains the wide error exactly once';
        }
        else {
            like $decoded, qr/snowman \x{2603}/,
                "$content_type decodes to the original wide error";
        }
    }
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
        content_type            => 'text/plain',
        _development_resolver   => sub { ++$calls == 1 ? 1 : 0 },
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
        content_type          => 'text/plain',
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
