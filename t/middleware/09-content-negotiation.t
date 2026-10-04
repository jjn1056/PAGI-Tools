#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use IO::Async::Loop;
use JSON::MaybeXS;

use PAGI::Middleware::ContentNegotiation;
use PAGI::Response::JSON ();

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

sub negotiate {
    my ($mw, $accept) = @_;
    my (@events, @seen);
    my $wrapped = $mw->wrap(async sub {
        my ($scope, $receive, $send) = @_;
        push @seen, $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    });
    run_async { $wrapped->(make_scope(method => 'GET', headers => [['Accept', $accept]]),
        async sub { {} }, async sub { push @events, $_[0] }) };
    return (\@events, \@seen);
}

subtest 'ContentNegotiation refuses an unmatched request with plain text by default' => sub {
    for my $accept ('application/json', 'image/png', '*/*;q=0') {
        my ($events, $seen) = negotiate(
            PAGI::Middleware::ContentNegotiation->new(supported_types => ['application/xml']), $accept);
        my @starts = response_starts($events);
        is scalar(@starts), 1, "$accept: one response";
        is $starts[0]{status}, 406, "$accept: 406";
        is response_header($events, 'Content-Type'), 'text/plain; charset=utf-8',
            "$accept: plain text whatever the Accept";
        is response_body($events), 'Not Acceptable. Supported types: application/xml',
            "$accept: lists the supported types";
        is scalar(@$seen), 0, "$accept: the wrapped application does not run";
    }
};

subtest 'ContentNegotiation refuse replaces the refusal' => sub {
    my ($events, $seen) = negotiate(PAGI::Middleware::ContentNegotiation->new(
        supported_types => ['application/json'],
        refuse => PAGI::Response::JSON->new({ detail => 'JSON only' }, status => 406)), 'text/csv');
    is decode_json(response_body($events)), { detail => 'JSON only' }, 'the refusing Response answers';
    is scalar(@$seen), 0, 'the wrapped application does not run';

    for my $value (undef, '', 'yes') {
        my $label = defined $value ? "'$value'" : 'undef';
        like dies { PAGI::Middleware::ContentNegotiation->new(
                supported_types => ['application/json'], refuse => $value) },
            qr/\QContentNegotiation 'refuse' must be an application, or 0 to let the application decide\E/,
            "$label is refused";
    }
};

subtest 'ContentNegotiation refuse => 0 lets the application decide' => sub {
    my ($events, $seen) = negotiate(PAGI::Middleware::ContentNegotiation->new(
        supported_types => ['application/json', 'text/html'], refuse => 0), 'application/xml');
    is scalar(@$seen), 1, 'the wrapped application runs';
    is $seen->[0]{'pagi.preferred_content_type'}, undef, 'with no preferred type: nothing matched';
    ok exists $seen->[0]{'pagi.accepted_types'}, 'and the parsed Accept list';
    is((response_starts($events))[0]{status}, 200, "and the application's own response");
};

subtest 'ContentNegotiation strict and default_type were removed' => sub {
    like dies { PAGI::Middleware::ContentNegotiation->new(supported_types => ['a/b'], strict => 1) },
        qr/\QContentNegotiation 'strict' was removed\E/, 'strict dies with its replacement';
    like dies { PAGI::Middleware::ContentNegotiation->new(supported_types => ['a/b'], default_type => 'a/b') },
        qr/\QContentNegotiation 'default_type' was removed\E/, 'default_type dies with its replacement';
};

subtest 'body-policy rejections await concrete response emission' => sub {
    my @cases = (
        {
            name       => 'ContentNegotiation strict 406',
            middleware => PAGI::Middleware::ContentNegotiation->new(
                supported_types => ['application/xml'],
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
