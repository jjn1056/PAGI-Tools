#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use IO::Async::Loop;
use JSON::MaybeXS;

use PAGI::Middleware::ContentNegotiation;

my $loop = IO::Async::Loop->new;

# Helper to create HTTP scope
sub make_scope {
    my (%opts) = @_;
    return {
        type    => 'http',
        method  => $opts{method} // 'POST',
        path    => '/',
        headers => $opts{headers} // [],
    };
}

# Helper to run async tests
sub run_async (&) {
    my ($code) = @_;
    $loop->await($code->());
}

sub response_starts {
    my ($events) = @_;
    return grep { ($_->{type} // '') eq 'http.response.start' } @$events;
}

sub response_header {
    my ($events, $name) = @_;
    my ($start) = response_starts($events);
    my $wanted = lc $name;
    my ($header) = grep { lc($_->[0]) eq $wanted } @{$start->{headers} // []};
    return $header ? $header->[1] : undef;
}

sub response_body {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
}

sub assert_body_policy_settlement {
    my ($wrapped, $scope, $receive, $label) = @_;
    my ($start_gate, $body_gate) = (Future->new, Future->new);
    my @events;
    my $running = $wrapped->(
        $scope,
        $receive,
        sub {
            push @events, $_[0];
            return @events == 1 ? $start_gate : $body_gate;
        },
    );

    is scalar(@events), 1, "$label emits only response start before settlement";
    ok !$running->is_ready, "$label waits for response-start settlement";
    $start_gate->done;
    is scalar(@events), 2, "$label emits one body after response-start settlement";
    ok !$running->is_ready, "$label waits for terminal-body settlement";
    $body_gate->done;
    is dies { $loop->await($running) }, undef,
        "$label completes after the terminal send settles";
    ok !$start_gate->is_cancelled && !$body_gate->is_cancelled,
        "$label does not cancel server-owned send Futures";
}

# ===================
# ContentNegotiation Middleware Tests
# ===================

subtest 'ContentNegotiation - selects preferred type' => sub {
    my $content_neg = PAGI::Middleware::ContentNegotiation->new(
        supported_types => ['application/json', 'text/html', 'text/plain'],
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $content_neg->wrap($app);
    my $scope = make_scope(
        method  => 'GET',
        headers => [['Accept', 'text/html, application/json;q=0.9']]
    );

    my $receive = async sub { {} };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    is $captured_scope->{'pagi.preferred_content_type'}, 'text/html', 'selects highest q value';
};

subtest 'ContentNegotiation - shares exact exclusions and accepted scope shape' => sub {
    my $content_neg = PAGI::Middleware::ContentNegotiation->new(
        supported_types => ['application/json', 'text/html'],
    );

    my $captured_scope;
    my $app = async sub { $captured_scope = $_[0] };
    my $wrapped = $content_neg->wrap($app);
    my $scope = make_scope(
        method  => 'GET',
        headers => [[
            'Accept',
            'application/json;q=0, */*;q=0.5, text/html;q=0.5',
        ]],
    );

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is $captured_scope->{'pagi.preferred_content_type'}, 'text/html',
        'exact q=0 exclusion is not revived by the positive wildcard';
    is $captured_scope->{'pagi.accepted_types'}, [
        { type => 'text/html', q => 0.5 },
        { type => '*/*', q => 0.5 },
        { type => 'application/json', q => 0 },
    ], 'accepted types retain the public hash shape in shared preference order';
};

subtest 'ContentNegotiation - combines repeated Accept fields' => sub {
    my $content_neg = PAGI::Middleware::ContentNegotiation->new(
        supported_types => ['text/html', 'text/plain'],
    );

    my $captured_scope;
    my $wrapped = $content_neg->wrap(async sub { $captured_scope = $_[0] });
    my $scope = make_scope(
        method  => 'GET',
        headers => [
            ['Accept', 'text/html;q=0'],
            ['Accept', 'text/plain'],
        ],
    );

    run_async { $wrapped->($scope, async sub { {} }, async sub { }) };

    is $captured_scope->{'pagi.preferred_content_type'}, 'text/plain',
        'a later acceptable field participates in selection';
    is $captured_scope->{'pagi.accepted_types'}, [
        { type => 'text/plain', q => 1 },
        { type => 'text/html', q => 0 },
    ], 'accepted metadata contains every repeated field in preference order';
};

subtest 'ContentNegotiation - handles wildcard' => sub {
    my $content_neg = PAGI::Middleware::ContentNegotiation->new(
        supported_types => ['application/json', 'text/html'],
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $content_neg->wrap($app);
    my $scope = make_scope(
        method  => 'GET',
        headers => [['Accept', '*/*']]
    );

    my $receive = async sub { {} };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    is $captured_scope->{'pagi.preferred_content_type'}, 'application/json', 'wildcard matches first supported';
};

subtest 'ContentNegotiation - handles type wildcard' => sub {
    my $content_neg = PAGI::Middleware::ContentNegotiation->new(
        supported_types => ['application/json', 'text/html'],
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $content_neg->wrap($app);
    my $scope = make_scope(
        method  => 'GET',
        headers => [['Accept', 'text/*']]
    );

    my $receive = async sub { {} };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    is $captured_scope->{'pagi.preferred_content_type'}, 'text/html', 'text/* matches text/html';
};

subtest 'ContentNegotiation - uses default when no match' => sub {
    my $content_neg = PAGI::Middleware::ContentNegotiation->new(
        supported_types => ['application/json', 'text/html'],
        default_type    => 'text/plain',
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $content_neg->wrap($app);
    my $scope = make_scope(
        method  => 'GET',
        headers => [['Accept', 'application/xml']]  # Not supported
    );

    my $receive = async sub { {} };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    is $captured_scope->{'pagi.preferred_content_type'}, 'text/plain', 'uses default type';
};

subtest 'ContentNegotiation - strict mode returns 406' => sub {
    my $content_neg = PAGI::Middleware::ContentNegotiation->new(
        supported_types => ['application/json', 'text/html'],
        strict          => 1,
    );

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $content_neg->wrap($app);
    my $scope = make_scope(
        method  => 'GET',
        headers => [['Accept', 'application/xml']]  # Not supported
    );

    my @events;
    my $receive = async sub { {} };
    my $send = async sub  {
        my ($event) = @_; push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    is $events[0]{status}, 406, 'returns 406 Not Acceptable in strict mode';
};

subtest 'ContentNegotiation - strict failures respond once through Pages' => sub {
    my @cases = (
        {
            name         => 'JSON alias selects problem JSON',
            accept       => 'application/json',
            content_type => 'application/problem+json',
        },
        {
            name         => 'unsupported image uses the configured default',
            accept       => 'image/png',
            content_type => 'text/html; charset=utf-8',
        },
        {
            name         => 'excluded wildcard reaches one strict response',
            accept       => '*/*;q=0',
            content_type => 'text/html; charset=utf-8',
        },
    );

    for my $case (@cases) {
        subtest $case->{name} => sub {
            my $content_neg = PAGI::Middleware::ContentNegotiation->new(
                supported_types => ['application/xml'],
                strict          => 1,
            );
            my $downstream_calls = 0;
            my $wrapped = $content_neg->wrap(async sub { $downstream_calls++ });
            my $scope = make_scope(
                method  => 'GET',
                headers => [['Accept', $case->{accept}]],
            );
            my @events;
            my $send = async sub { push @events, $_[0] };

            run_async { $wrapped->($scope, async sub { {} }, $send) };

            my @starts = response_starts(\@events);
            is scalar(@starts), 1, 'emits exactly one response start';
            is $starts[0]{status}, 406, 'the single response is 406';
            is response_header(\@events, 'Content-Type'), $case->{content_type},
                'Pages selects the expected representation';
            is $downstream_calls, 0, 'does not call downstream';
            if ($case->{accept} eq 'application/json') {
                my $problem = decode_json(response_body(\@events));
                is $problem->{detail},
                    'Not Acceptable. Supported types: application/xml',
                    '406 retains the safe supported-type detail';
            }
        };
    }
};

subtest 'body-policy rejections await concrete response emission' => sub {
    my @cases = (
        {
            name       => 'ContentNegotiation strict 406',
            middleware => PAGI::Middleware::ContentNegotiation->new(
                supported_types => ['application/xml'],
                strict          => 1,
            ),
            scope => make_scope(
                method  => 'GET',
                headers => [['Accept', 'image/png']],
            ),
        },
    );

    for my $case (@cases) {
        my $sent_body = 0;
        my $receive = sub {
            return Future->done({ type => 'http.disconnect' })
                if $sent_body++ || !exists $case->{body};
            return Future->done({
                type => 'http.request', body => $case->{body}, more => 0,
            });
        };
        my $wrapped = $case->{middleware}->wrap(async sub {
            die "$case->{name} rejection reached downstream";
        });
        assert_body_policy_settlement(
            $wrapped, $case->{scope}, $receive, $case->{name},
        );
    }
};

subtest 'ContentNegotiation - handles no Accept header' => sub {
    my $content_neg = PAGI::Middleware::ContentNegotiation->new(
        supported_types => ['application/json', 'text/html'],
    );

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $content_neg->wrap($app);
    my $scope = make_scope(method => 'GET', headers => []);

    my $receive = async sub { {} };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    is $captured_scope->{'pagi.preferred_content_type'}, 'application/json', 'uses first supported when no Accept';
};

done_testing;
