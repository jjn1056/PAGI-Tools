#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use IO::Async::Loop;
use JSON::MaybeXS;

use PAGI::Middleware::JSONBody;
use PAGI::Middleware::FormBody;
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
# JSONBody Middleware Tests
# ===================

subtest 'JSONBody - parses valid JSON' => sub {
    my $json_mw = PAGI::Middleware::JSONBody->new();

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['Content-Type', 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $json_mw->wrap($app);
    my $scope = make_scope(headers => [['Content-Type', 'application/json']]);

    my $json_body = '{"name":"John","age":30}';
    my $body_sent = 0;
    my $receive = async sub {
        return { type => 'http.disconnect' } if $body_sent;
        $body_sent = 1;
        return { type => 'http.request', body => $json_body, more => 0 };
    };

    my @events;
    my $send = async sub  {
        my ($event) = @_; push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    ok exists $captured_scope->{'pagi.parsed_body'}, 'has parsed body';
    is $captured_scope->{'pagi.parsed_body'}{name}, 'John', 'name parsed correctly';
    is $captured_scope->{'pagi.parsed_body'}{age}, 30, 'age parsed correctly';
    is $captured_scope->{'pagi.raw_body'}, $json_body, 'raw body preserved';
};

subtest 'JSONBody - returns 400 for invalid JSON' => sub {
    my $json_mw = PAGI::Middleware::JSONBody->new();

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $json_mw->wrap($app);
    my $scope = make_scope(headers => [['Content-Type', 'application/json']]);

    my $body_sent = 0;
    my $receive = async sub {
        return { type => 'http.disconnect' } if $body_sent;
        $body_sent = 1;
        return { type => 'http.request', body => 'not valid json', more => 0 };
    };

    my @events;
    my $send = async sub  {
        my ($event) = @_; push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    is $events[0]{status}, 400, 'returns 400 for invalid JSON';
};

subtest 'JSONBody - invalid JSON delegates a safe negotiated 400' => sub {
    my $json_mw = PAGI::Middleware::JSONBody->new();
    my $downstream_calls = 0;
    my $app = async sub { $downstream_calls++ };
    my $wrapped = $json_mw->wrap($app);
    my $scope = make_scope(headers => [
        ['Content-Type', 'application/json'],
        ['Accept', 'application/json'],
    ]);

    my $body_sent = 0;
    my $receive = async sub {
        return { type => 'http.disconnect' } if $body_sent++;
        return { type => 'http.request', body => '{ malformed', more => 0 };
    };
    my @events;
    my $send = async sub { push @events, $_[0] };

    {
        no warnings 'redefine';
        local *JSON::MaybeXS::decode_json = sub {
            die "decoder failed at /srv/private/decoder/source.c line 731\n";
        };
        run_async { $wrapped->($scope, $receive, $send) };
    }

    my @starts = response_starts(\@events);
    is scalar(@starts), 1, 'invalid JSON starts exactly one response';
    is $starts[0]{status}, 400, 'invalid JSON remains a 400 response';
    is response_header(\@events, 'Content-Type'), 'application/problem+json',
        '400 response honors the original JSON Accept header';
    my $problem = decode_json(response_body(\@events));
    is $problem->{detail}, 'The request body is not valid JSON.',
        'client receives the stable safe detail';
    unlike response_body(\@events), qr{/srv/private/decoder/source[.]c},
        'decoder filesystem path is not exposed';
    is $downstream_calls, 0, 'invalid JSON does not call downstream';
};

subtest 'JSONBody - returns 413 for large body' => sub {
    my $json_mw = PAGI::Middleware::JSONBody->new(max_size => 100);

    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $json_mw->wrap($app);
    my $scope = make_scope(headers => [['Content-Type', 'application/json']]);

    my $body_sent = 0;
    my $receive = async sub {
        return { type => 'http.disconnect' } if $body_sent;
        $body_sent = 1;
        return { type => 'http.request', body => '{"data":"' . ('x' x 200) . '"}', more => 0 };
    };

    my @events;
    my $send = async sub  {
        my ($event) = @_; push @events, $event };

    run_async { $wrapped->($scope, $receive, $send) };

    is $events[0]{status}, 413, 'returns 413 for large body';
};

subtest 'JSONBody - body limit delegates a negotiated 413' => sub {
    my $json_mw = PAGI::Middleware::JSONBody->new(max_size => 4);
    my $downstream_calls = 0;
    my $wrapped = $json_mw->wrap(async sub { $downstream_calls++ });
    my $scope = make_scope(headers => [
        ['Content-Type', 'application/json'],
        ['Accept', 'application/json'],
    ]);
    my $receive = async sub {
        return { type => 'http.request', body => '{"too":"large"}', more => 0 };
    };
    my @events;
    my $send = async sub { push @events, $_[0] };

    run_async { $wrapped->($scope, $receive, $send) };

    my @starts = response_starts(\@events);
    is scalar(@starts), 1, 'JSON limit starts exactly one response';
    is $starts[0]{status}, 413, 'JSON limit remains a 413 response';
    is response_header(\@events, 'Content-Type'), 'application/problem+json',
        'JSON limit honors the original JSON Accept header';
    is $downstream_calls, 0, 'JSON limit does not call downstream';
};

subtest 'JSONBody - mid-body disconnect fails loudly, not silent EOF' => sub {
    my $json_mw = PAGI::Middleware::JSONBody->new();
    my $downstream_calls = 0;
    my $wrapped = $json_mw->wrap(async sub { $downstream_calls++ });
    my $scope = make_scope(headers => [['Content-Type', 'application/json']]);

    my $sent = 0;
    my $receive = async sub {
        return { type => 'http.request', body => '{"partial":', more => 1 } unless $sent++;
        return { type => 'http.disconnect' };
    };
    my $send = async sub { };

    my $future = $wrapped->($scope, $receive, $send);
    $loop->await($future);

    ok $future->is_failed, 'the app future fails instead of parsing the partial body';
    like scalar($future->failure), qr/Request body incomplete: client disconnected mid-body/,
        'names the truncation';
    is $downstream_calls, 0, 'does not call downstream with a truncated body';
};

subtest 'JSONBody - skips non-JSON content types' => sub {
    my $json_mw = PAGI::Middleware::JSONBody->new();

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $json_mw->wrap($app);
    my $scope = make_scope(headers => [['Content-Type', 'text/plain']]);

    my $receive = async sub { { type => 'http.request', body => 'plain text', more => 0 } };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    ok !exists $captured_scope->{'pagi.parsed_body'}, 'no parsed body for non-JSON';
};

subtest 'JSONBody - handles application/XXX+json' => sub {
    my $json_mw = PAGI::Middleware::JSONBody->new();

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $json_mw->wrap($app);
    my $scope = make_scope(headers => [['Content-Type', 'application/vnd.api+json']]);

    my $body_sent = 0;
    my $receive = async sub {
        return { type => 'http.disconnect' } if $body_sent;
        $body_sent = 1;
        return { type => 'http.request', body => '{"api":"data"}', more => 0 };
    };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    ok exists $captured_scope->{'pagi.parsed_body'}, 'parses +json media types';
    is $captured_scope->{'pagi.parsed_body'}{api}, 'data', 'data parsed correctly';
};

# ===================
# FormBody Middleware Tests
# ===================

subtest 'FormBody - parses URL-encoded form' => sub {
    my $form_mw = PAGI::Middleware::FormBody->new();

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [],
        });
        await $send->({
            type => 'http.response.body',
            body => 'OK',
            more => 0,
        });
    };

    my $wrapped = $form_mw->wrap($app);
    my $scope = make_scope(headers => [['Content-Type', 'application/x-www-form-urlencoded']]);

    my $body_sent = 0;
    my $receive = async sub {
        return { type => 'http.disconnect' } if $body_sent;
        $body_sent = 1;
        return { type => 'http.request', body => 'name=John&age=30&city=New+York', more => 0 };
    };

    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    ok exists $captured_scope->{'pagi.parsed_body'}, 'has parsed body';
    is $captured_scope->{'pagi.parsed_body'}{name}, 'John', 'name parsed';
    is $captured_scope->{'pagi.parsed_body'}{age}, '30', 'age parsed';
    is $captured_scope->{'pagi.parsed_body'}{city}, 'New York', 'space decoded';
};

subtest 'FormBody - handles URL encoding' => sub {
    my $form_mw = PAGI::Middleware::FormBody->new();

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $form_mw->wrap($app);
    my $scope = make_scope(headers => [['Content-Type', 'application/x-www-form-urlencoded']]);

    my $body_sent = 0;
    my $receive = async sub {
        return { type => 'http.disconnect' } if $body_sent;
        $body_sent = 1;
        return { type => 'http.request', body => 'email=test%40example.com&q=%3Cfoo%3E', more => 0 };
    };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    is $captured_scope->{'pagi.parsed_body'}{email}, 'test@example.com', '@ decoded';
    is $captured_scope->{'pagi.parsed_body'}{q}, '<foo>', 'angle brackets decoded';
};

subtest 'FormBody - handles multiple values for same key' => sub {
    my $form_mw = PAGI::Middleware::FormBody->new();

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $form_mw->wrap($app);
    my $scope = make_scope(headers => [['Content-Type', 'application/x-www-form-urlencoded']]);

    my $body_sent = 0;
    my $receive = async sub {
        return { type => 'http.disconnect' } if $body_sent;
        $body_sent = 1;
        return { type => 'http.request', body => 'color=red&color=green&color=blue', more => 0 };
    };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    is ref($captured_scope->{'pagi.parsed_body'}{color}), 'ARRAY', 'multiple values as array';
    is $captured_scope->{'pagi.parsed_body'}{color}, ['red', 'green', 'blue'], 'all values present';
};

subtest 'FormBody - body limit delegates a negotiated 413' => sub {
    my $form_mw = PAGI::Middleware::FormBody->new(max_size => 4);
    my $downstream_calls = 0;
    my $wrapped = $form_mw->wrap(async sub { $downstream_calls++ });
    my $scope = make_scope(headers => [
        ['Content-Type', 'application/x-www-form-urlencoded'],
        ['Accept', 'text/plain'],
    ]);
    my $receive = async sub {
        return { type => 'http.request', body => 'name=too-long', more => 0 };
    };
    my @events;
    my $send = async sub { push @events, $_[0] };

    run_async { $wrapped->($scope, $receive, $send) };

    my @starts = response_starts(\@events);
    is scalar(@starts), 1, 'form limit starts exactly one response';
    is $starts[0]{status}, 413, 'form limit remains a 413 response';
    is response_header(\@events, 'Content-Type'), 'text/plain; charset=utf-8',
        'form limit honors the original text Accept header';
    is $downstream_calls, 0, 'form limit does not call downstream';
};

subtest 'FormBody - mid-body disconnect fails loudly, not silent EOF' => sub {
    my $form_mw = PAGI::Middleware::FormBody->new();
    my $downstream_calls = 0;
    my $wrapped = $form_mw->wrap(async sub { $downstream_calls++ });
    my $scope = make_scope(headers => [['Content-Type', 'application/x-www-form-urlencoded']]);

    my $sent = 0;
    my $receive = async sub {
        return { type => 'http.request', body => 'name=Jo', more => 1 } unless $sent++;
        return { type => 'http.disconnect' };
    };
    my $send = async sub { };

    my $future = $wrapped->($scope, $receive, $send);
    $loop->await($future);

    ok $future->is_failed, 'the app future fails instead of parsing the partial body';
    like scalar($future->failure), qr/Request body incomplete: client disconnected mid-body/,
        'names the truncation';
    is $downstream_calls, 0, 'does not call downstream with a truncated body';
};

subtest 'FormBody - skips non-form content types' => sub {
    my $form_mw = PAGI::Middleware::FormBody->new();

    my $captured_scope;
    my $app = async sub  {
        my ($scope, $receive, $send) = @_;
        $captured_scope = $scope;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };

    my $wrapped = $form_mw->wrap($app);
    my $scope = make_scope(headers => [['Content-Type', 'application/json']]);

    my $receive = async sub { { type => 'http.request', body => '{"data":1}', more => 0 } };
    my $send = async sub { };

    run_async { $wrapped->($scope, $receive, $send) };

    ok !exists $captured_scope->{'pagi.parsed_body'}, 'no parsed body for JSON content type';
};

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
            name       => 'JSONBody invalid JSON 400',
            middleware => PAGI::Middleware::JSONBody->new,
            scope      => make_scope(headers => [
                ['Content-Type', 'application/json'],
                ['Accept', 'text/plain'],
            ]),
            body       => '{ malformed',
        },
        {
            name       => 'JSONBody size 413',
            middleware => PAGI::Middleware::JSONBody->new(max_size => 3),
            scope      => make_scope(headers => [
                ['Content-Type', 'application/json'],
                ['Accept', 'text/plain'],
            ]),
            body       => 'oversized',
        },
        {
            name       => 'FormBody size 413',
            middleware => PAGI::Middleware::FormBody->new(max_size => 3),
            scope      => make_scope(headers => [
                ['Content-Type', 'application/x-www-form-urlencoded'],
                ['Accept', 'text/plain'],
            ]),
            body       => 'oversized',
        },
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
