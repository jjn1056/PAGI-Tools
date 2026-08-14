#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);

use PAGI::Routing qw(router route mount middleware);
use PAGI::Routing::Compiler;
use PAGI::Routing::Trace;

sub scope {
    my (%changes) = @_;
    return {
        type        => 'http',
        method      => 'GET',
        path        => '/',
        root_path   => '',
        raw_path    => '/',
        path_params => {},
        headers     => [],
        %changes,
    };
}

sub receive {
    return Future->done({
        type => 'http.request',
        body => '',
        more => 0,
    });
}

sub run_with_trace {
    my ($app, %scope_changes) = @_;
    my ($request_scope, $trace) = PAGI::Routing::Trace->_ensure_http_scope(
        scope(%scope_changes),
    );
    my $checkpoint = $trace->checkpoint;
    my @events;
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };

    Future->wrap($app->($request_scope, \&receive, $send))->get;
    return (\@events, $trace->snapshot($checkpoint));
}

sub run_catching_with_trace {
    my ($app, %scope_changes) = @_;
    my ($request_scope, $trace) = PAGI::Routing::Trace->_ensure_http_scope(
        scope(%scope_changes),
    );
    my $checkpoint = $trace->checkpoint;
    my @events;
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    my $error = dies {
        Future->wrap($app->($request_scope, \&receive, $send))->get;
    };
    return ($error, \@events, $trace->snapshot($checkpoint));
}

sub response_start {
    my ($events) = @_;
    return (grep { ($_->{type} // '') eq 'http.response.start' } @$events)[0];
}

sub response_body {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
}

sub response_header {
    my ($events, $name) = @_;
    my $start = response_start($events);
    return unless $start;
    for my $pair (@{$start->{headers} || []}) {
        return $pair->[1] if lc($pair->[0]) eq lc($name);
    }
    return;
}

sub text_handler {
    return $_[0]->text('matched');
}

subtest 'direct HTTP NONE and PARTIAL complete unanswered with trusted evidence' => sub {
    my $app = router(routes => [
        route('/items' => \&text_handler, methods => 'GET'),
    ])->to_app;

    my ($none_events, $none) = run_with_trace(
        $app,
        method => 'GET',
        path   => '/missing',
    );
    is($none_events, [], 'NONE emits no response');
    ok($none->routing_declined, 'NONE is a trusted decline');
    ok(!$none->path_matched, 'NONE records no complete path candidate');
    ok(!$none->method_matched, 'NONE records no accepted method');
    is($none->allowed_methods, [], 'NONE has no allowed methods');

    my ($partial_events, $partial) = run_with_trace(
        $app,
        method => 'POST',
        path   => '/items',
    );
    is($partial_events, [], 'PARTIAL emits no response');
    ok($partial->routing_declined, 'PARTIAL is a trusted decline');
    ok($partial->path_matched, 'PARTIAL records a complete path candidate');
    ok(!$partial->method_matched, 'PARTIAL records method rejection');
    is($partial->allowed_methods, [qw(GET HEAD)], 'method union survives');
};

subtest 'a later FULL selection supersedes earlier partial evidence' => sub {
    my $app = router(routes => [
        route('/items' => sub { return $_[0]->text('get') }, methods => 'GET'),
        route('/items' => sub { return $_[0]->text('post') }, methods => 'POST'),
    ])->to_app;

    my ($events, $snapshot) = run_with_trace(
        $app,
        method => 'POST',
        path   => '/items',
    );
    is(response_start($events)->{status}, 200, 'later FULL emits its response');
    is(response_body($events), 'post', 'later FULL owns the response body');
    ok(!$snapshot->routing_declined, 'discarded partial does not become a decline');
    is($snapshot->allowed_methods, [], 'discarded partial methods are excluded');
};

subtest 'selected explicit 404 and 405 responses pass through unchanged' => sub {
    my $app = router(routes => [
        route('/explicit-404' => sub {
            return $_[0]->text('application missing', status => 404,
                headers => ['X-Origin' => 'handler']);
        }),
        route('/explicit-405' => sub {
            return $_[0]->text('application method', status => 405,
                headers => ['X-Origin' => 'handler']);
        }),
    ])->to_app;

    my ($not_found, $not_found_snapshot) = run_with_trace(
        $app, path => '/explicit-404',
    );
    is(response_start($not_found)->{status}, 404, 'explicit 404 retains status');
    is(response_body($not_found), 'application missing', 'explicit 404 retains body');
    is(response_header($not_found, 'X-Origin'), 'handler',
        'explicit 404 retains headers');
    ok(!$not_found_snapshot->routing_declined,
        'selected explicit 404 is not a routing decline');

    my ($not_allowed, $not_allowed_snapshot) = run_with_trace(
        $app, path => '/explicit-405',
    );
    is(response_start($not_allowed)->{status}, 405, 'explicit 405 retains status');
    is(response_header($not_allowed, 'Allow'), undef,
        'explicit 405 receives no synthesized Allow');
    is(response_header($not_allowed, 'X-Origin'), 'handler',
        'explicit 405 retains unrelated headers');
    ok(!$not_allowed_snapshot->routing_declined,
        'selected explicit 405 is not a routing decline');
};

subtest 'selected handler Context exposes no routing fallback API' => sub {
    my $context;
    my $app = router(routes => [
        route('/context' => sub {
            $context = $_[0];
            return $context->text('context');
        }),
    ])->to_app;

    my ($events) = run_with_trace($app, path => '/context');
    is(response_start($events)->{status}, 200,
        'matched Context handler completes normally');
    isa_ok($context, 'PAGI::Context');
    ok(!$context->can($_), "handler Context has no $_ method") for qw(
        routing_trace not_found method_not_allowed
    );
};

subtest 'selected silent raw and opaque targets remain successful selections' => sub {
    my $raw_runs = 0;
    my $opaque_runs = 0;
    my $app = router(routes => [
        route('/raw', raw => async sub {
            ++$raw_runs;
            return;
        }),
        mount('/opaque' => async sub {
            ++$opaque_runs;
            return;
        }),
    ])->to_app;

    my ($raw_events, $raw_snapshot) = run_with_trace($app, path => '/raw');
    is($raw_events, [], 'selected silent raw route emits nothing');
    is($raw_runs, 1, 'selected silent raw route runs once');
    ok(!$raw_snapshot->routing_declined,
        'selected silent raw route is success rather than decline');

    my ($opaque_events, $opaque_snapshot) = run_with_trace(
        $app, path => '/opaque/missing',
    );
    is($opaque_events, [], 'selected silent opaque Mount emits nothing');
    is($opaque_runs, 1, 'selected silent opaque Mount runs once');
    ok(!$opaque_snapshot->routing_declined,
        'selected silent opaque Mount is success rather than decline');
};

subtest 'selected normal handlers retain the response return contract' => sub {
    my @cases = (
        ['undef', sub { return undef }],
        ['scalar', sub { return 'not a response' }],
        ['wrong object', sub { return bless {}, 'Local::NotAResponse' }],
        ['Future undef', sub { return Future->done(undef) }],
    );

    for my $case (@cases) {
        my ($label, $handler) = @$case;
        my $app = router(routes => [route('/bad' => $handler)])->to_app;
        my ($error, $events, $snapshot) = run_catching_with_trace(
            $app, path => '/bad',
        );
        like($error, qr/handler did not return a response/,
            "$label selected return is rejected");
        is($events, [], "$label selected return emits no response");
        ok(!$snapshot->routing_declined,
            "$label selected exception is not a routing decline");
    }
};

subtest 'standalone compilation keeps routing component semantics' => sub {
    my $description = router(routes => [
        route('/standalone' => sub { return $_[0]->text('standalone') }),
    ]);
    is(ref(PAGI::Routing::Compiler->compile($description)), 'CODE',
        'Compiler compiles a Router to CODE');
    is(ref($description->to_app), 'CODE', 'Router to_app returns CODE');

    my $standalone = route('/standalone' => sub {
        return $_[0]->text('standalone');
    });
    my $standalone_app = $standalone->to_app;
    my ($full) = run_with_trace($standalone_app, path => '/standalone');
    is(response_body($full), 'standalone', 'standalone Route handles FULL');
    my ($partial, $partial_snapshot) = run_with_trace(
        $standalone_app, method => 'POST', path => '/standalone',
    );
    is($partial, [], 'standalone Route PARTIAL is unanswered');
    ok($partial_snapshot->routing_declined,
        'standalone Route PARTIAL publishes trusted evidence');
    my ($none, $none_snapshot) = run_with_trace(
        $standalone_app, path => '/missing',
    );
    is($none, [], 'standalone Route NONE is unanswered');
    ok($none_snapshot->routing_declined,
        'standalone Route NONE publishes trusted evidence');

    my $standalone_mount = mount('/future', routes => []);
    is(ref($standalone_mount->to_app), 'CODE',
        'standalone Mount to_app returns CODE through one-node compilation');
};

subtest 'each to_app call resolves an independent middleware graph' => sub {
    my $builds = 0;
    my @instances;
    my $descriptor = middleware(sub {
        my ($inner) = @_;
        my $instance = ++$builds;
        return sub {
            push @instances, $instance;
            return $inner->(@_);
        };
    });
    my $description = router(routes => [
        route('/fresh' => sub { return $_[0]->text('fresh') },
            middleware => [$descriptor]),
    ]);

    my $first = $description->to_app;
    my $second = $description->to_app;
    run_with_trace($first, path => '/fresh');
    run_with_trace($first, path => '/fresh');
    run_with_trace($second, path => '/fresh');

    is($builds, 2, 'each compiled graph resolves middleware once');
    is(\@instances, [1, 1, 2], 'compiled graphs retain independent instances');
};

done_testing;
