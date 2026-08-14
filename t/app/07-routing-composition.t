#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);

use lib 'lib';

use PAGI::App::Cascade;
use PAGI::App::URLMap;
use PAGI::Compose qw(compose);
use PAGI::Exception::IncompleteResponse;
use PAGI::Middleware::Routing::NotFound;
use PAGI::Routing qw(router route middleware);
use PAGI::Routing::Trace;

sub scope {
    my (%changes) = @_;
    return {
        type         => 'http',
        method       => 'GET',
        path         => '/',
        root_path    => '',
        query_string => '',
        headers      => [],
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

sub response_app {
    my ($status, $body, %options) = @_;
    return async sub {
        my ($request_scope, $request_receive, $send) = @_;
        await Future->wrap($send->({
            type    => 'http.response.start',
            status  => $status,
            headers => $options{headers} || [],
        }));
        await Future->wrap($send->({
            type => 'http.response.body',
            body => $body,
            more => 0,
        }));
        return;
    };
}

sub run_app {
    my ($app, $request_scope) = @_;
    my @events;
    my @warnings;
    my $error;
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $ok = eval {
            Future->wrap($app->(
                $request_scope || scope(),
                \&receive,
                $send,
            ))->get;
            1;
        };
        $error = $@ unless $ok;
    }
    return (\@events, $error, \@warnings);
}

sub response_start {
    my ($events) = @_;
    return (grep {
        ($_->{type} // '') eq 'http.response.start'
    } @$events)[0];
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
    for my $header (@{$start->{headers} || []}) {
        next unless ref($header) eq 'ARRAY';
        return $header->[1] if lc($header->[0] // '') eq lc($name);
    }
    return;
}

sub attempt_descriptions {
    my ($snapshot) = @_;
    return [map { $_->{desc} }
        grep { defined $_->{desc} } @{$snapshot->attempts}];
}

subtest 'Cascade distinguishes trusted declines, caught responses, and failures' => sub {
    my $declining = router(routes => [
        route('/only' => sub { return $_[0]->text('only') }),
    ])->to_app;
    my $advancing = PAGI::App::Cascade->new(apps => [
        $declining,
        response_app(200, 'second'),
    ])->to_app;
    my ($advanced, $advance_error) = run_app(
        $advancing,
        scope(path => '/missing'),
    );
    is($advance_error, undef, 'a non-final trusted decline completes normally');
    my $advanced_start = response_start($advanced);
    is($advanced_start ? $advanced_start->{status} : undef, 200,
        'a non-final naked Router decline advances');
    is(response_body($advanced), 'second', 'the next child owns the response');

    my $final_decline = PAGI::App::Cascade->new(apps => [$declining])->to_app;
    my ($traced_scope, $trace) = PAGI::Routing::Trace->_ensure_http_scope(
        scope(path => '/missing'),
    );
    my $checkpoint = $trace->checkpoint;
    my ($unanswered, $decline_error) = run_app($final_decline, $traced_scope);
    my $decline_snapshot = $trace->snapshot($checkpoint);
    is($decline_error, undef, 'a final trusted decline completes normally');
    is($unanswered, [], 'a final Router decline remains unanswered');
    ok($decline_snapshot->routing_declined,
        'the final decline evidence remains visible');

    local $ENV{PAGI_ENV} = 'production';
    my ($rendered, $render_error, $render_warnings) = run_app(
        compose(app => PAGI::App::Cascade->new(
            apps => [$declining],
        ))->to_app,
        scope(path => '/missing'),
    );
    is($render_error, undef, 'outer Compose handles the final trusted decline');
    is($render_warnings, [], 'a trusted decline does not enter error handling');
    is(response_start($rendered)->{status}, 404,
        'outer Routing::NotFound renders the final decline');

    for my $case (
        ['non-final silent child', [async sub { return }, response_app(200, 'unused')]],
        ['final silent child', [async sub { return }]],
        ['empty app list', []],
    ) {
        my ($label, $apps) = @$case;
        my $later_runs = 0;
        if ($label eq 'non-final silent child') {
            $apps->[1] = async sub { ++$later_runs; return };
        }
        my (undef, $error) = run_app(
            PAGI::App::Cascade->new(apps => $apps)->to_app,
            scope(path => '/silent'),
        );
        isa_ok($error, ['PAGI::Exception::IncompleteResponse'],
            "$label is a typed lifecycle failure");
        is($error && ref($error) ? $error->stage : undef, 'before_start',
            "$label fails before start");
        is($later_runs, 0, "$label does not invent a decline")
            if $label eq 'non-final silent child';
    }

    for my $status (404, 405) {
        my $app = PAGI::App::Cascade->new(apps => [
            response_app(
                $status,
                "explicit $status",
                headers => [['x-origin', 'final']],
            ),
        ])->to_app;
        my ($events, $error) = run_app($app, scope(path => '/explicit'));
        is($error, undef, "final explicit $status completes");
        is(response_start($events)->{status}, $status,
            "final caught-status $status passes unchanged");
        is(response_header($events, 'X-Origin'), 'final',
            "final explicit $status retains headers");
        is(response_body($events), "explicit $status",
            "final explicit $status retains its body");
    }

    my $next_runs = 0;
    my $throwing_router = router(routes => [
        route('/boom' => sub { die "router child exploded\n" }),
    ])->to_app;
    my $exceptional = PAGI::App::Cascade->new(apps => [
        $throwing_router,
        async sub { ++$next_runs; return },
    ])->to_app;
    my ($exception_scope, $exception_trace)
        = PAGI::Routing::Trace->_ensure_http_scope(scope(path => '/boom'));
    my $exception_checkpoint = $exception_trace->checkpoint;
    my ($exception_events, $exception_error)
        = run_app($exceptional, $exception_scope);
    like($exception_error, qr/router child exploded/,
        'a child exception propagates unchanged');
    is($exception_events, [], 'the exception emits no synthetic response');
    is($next_runs, 0, 'an exception never advances to the next child');
    ok(!$exception_trace->snapshot($exception_checkpoint)->routing_declined,
        'an exception never becomes a routing decline');
};

subtest 'sibling Router declines union through a real Cascade' => sub {
    local $ENV{PAGI_ENV} = 'production';
    my $get = router(routes => [
        route('/items' => sub { return $_[0]->text('get') },
            methods => 'GET', desc => 'get sibling'),
    ])->to_app;
    my $post = router(routes => [
        route('/items' => sub { return $_[0]->text('post') },
            methods => 'POST', desc => 'post sibling'),
    ])->to_app;
    my $final = router(routes => [
        route('/elsewhere' => sub { return $_[0]->text('elsewhere') },
            desc => 'final sibling'),
    ])->to_app;

    my $app = compose(app => PAGI::App::Cascade->new(apps => [
        $get, $post, $final,
    ]))->to_app;
    my ($events, $error, $warnings) = run_app(
        $app,
        scope(method => 'PUT', path => '/items'),
    );
    is($error, undef, 'the sibling union is rendered normally');
    is($warnings, [], 'sibling declines do not enter error handling');
    is(response_start($events)->{status}, 405,
        'outer MethodNotAllowed sees the sibling partials');
    is(response_header($events, 'Allow'), 'GET, HEAD, POST',
        'allowed methods are unioned in first-execution order');

    local $ENV{PAGI_ENV} = 'development';
    my $outer_snapshot;
    my $caught_explicit = router(routes => [
        route('/items' => sub {
            return $_[0]->text('caught explicit', status => 404);
        }, methods => '*', desc => 'caught explicit'),
    ])->to_app;
    my $with_caught = compose(
        app => PAGI::App::Cascade->new(apps => [
            $get, $caught_explicit, $post, $final,
        ]),
        middleware => [
            middleware('Routing::MethodNotAllowed', handler => sub {
                my ($context, $snapshot) = @_;
                $outer_snapshot = $snapshot;
                return $context->text('outer method policy');
            }),
        ],
    )->to_app;
    my ($caught_events, $caught_error) = run_app(
        $with_caught,
        scope(method => 'PUT', path => '/items'),
    );
    is($caught_error, undef, 'a caught explicit child advances normally');
    is(response_start($caught_events)->{status}, 405,
        'the later sibling declines still render 405');
    is(response_header($caught_events, 'Allow'), 'GET, HEAD, POST',
        'the caught explicit child contributes no method evidence');
    is(attempt_descriptions($outer_snapshot), [
        'get sibling', 'post sibling', 'final sibling',
    ], 'the caught explicit child contributes no routing trace window');

    my ($child_snapshot, $application_snapshot);
    my $child_router = router(routes => [
        route('/child-only' => sub { return $_[0]->text('child') },
            desc => 'child local decline'),
    ])->to_app;
    my $child_policy = PAGI::Middleware::Routing::NotFound->new(
        handler => sub {
            my ($context, $snapshot) = @_;
            $child_snapshot = $snapshot;
            return $context->text('child not found', status => 404);
        },
    )->wrap($child_router);
    my $outer_final = router(routes => [
        route('/outer-only' => sub { return $_[0]->text('outer') },
            desc => 'outer final decline'),
    ])->to_app;
    my $discarded_child = compose(
        app => PAGI::App::Cascade->new(apps => [
            $child_policy,
            $outer_final,
        ]),
        middleware => [
            middleware('Routing::NotFound', handler => sub {
                my ($context, $snapshot) = @_;
                $application_snapshot = $snapshot;
                return $context->text('application not found', status => 404);
            }),
        ],
    )->to_app;
    my ($discarded_events, $discarded_error) = run_app(
        $discarded_child,
        scope(path => '/missing'),
    );
    is($discarded_error, undef, 'child and application fallbacks complete');
    is(response_body($discarded_events), 'application not found',
        'Cascade catches the child fallback and reaches the outer policy');
    ok($child_snapshot->routing_declined,
        'the earlier child-local snapshot retains its decline');
    is(attempt_descriptions($child_snapshot), ['child local decline'],
        'the child-local snapshot retains its own attempt');
    ok($application_snapshot->routing_declined,
        'the final child decline remains available to the outer policy');
    is(attempt_descriptions($application_snapshot), ['outer final decline'],
        'the later outer snapshot excludes only the caught child window');
};

subtest 'child checkpoints survive a later Cascade discard disposition' => sub {
    local $ENV{PAGI_ENV} = 'development';

    for my $case (
        ['equal-sequence checkpoint', 0],
        ['checkpoint after earlier records', 1],
    ) {
        my ($label, $record_before_checkpoint) = @$case;
        my $warmup = router(routes => [
            route('/warm' => sub { return $_[0]->text('warm') },
                desc => 'warmup decline'),
        ])->to_app;
        my $local_router = router(routes => [
            route('/local' => sub { return $_[0]->text('local') },
                desc => 'child local decline'),
        ])->to_app;
        my $child_policy = PAGI::Middleware::Routing::NotFound->new
            ->wrap($local_router);

        my ($saved_trace, $saved_checkpoint);
        my $child = async sub {
            my ($request_scope, $request_receive, $send) = @_;
            if ($record_before_checkpoint) {
                my $warmup_result = $warmup->(
                    $request_scope,
                    $request_receive,
                    $send,
                );
                await Future->wrap($warmup_result);
            }
            $saved_trace = $request_scope->{'pagi.routing.trace'};
            $saved_checkpoint = $saved_trace->checkpoint;
            my $child_result = $child_policy->(
                $request_scope,
                $request_receive,
                $send,
            );
            await Future->wrap($child_result);
            return;
        };

        my $cascade = PAGI::App::Cascade->new(apps => [
            $child,
            response_app(200, 'accepted'),
        ])->to_app;
        my ($request_scope, $trace) = PAGI::Routing::Trace->_ensure_http_scope(
            scope(path => '/missing'),
        );
        my $outer_checkpoint = $trace->checkpoint;
        my ($events, $error) = run_app($cascade, $request_scope);

        is($error, undef, "$label completes through the second child");
        is(response_start($events)->{status}, 200,
            "$label caught child response stays discarded");

        my $child_snapshot = $saved_trace->snapshot($saved_checkpoint);
        ok($child_snapshot->routing_declined,
            "$label retains its child-local decline when materialized later");
        is(attempt_descriptions($child_snapshot), ['child local decline'],
            "$label retains only evidence after its local checkpoint");

        my $outer_snapshot = $trace->snapshot($outer_checkpoint);
        ok(!$outer_snapshot->routing_declined,
            "$label remains excluded from the enclosing checkpoint");
        is(attempt_descriptions($outer_snapshot), [],
            "$label contributes no discarded attempts to the enclosing view");
    }
};

subtest 'HTTP Cascade streams accepted children and suppresses caught children' => sub {
    my $accepted_gate = Future->new;
    my $accepted_next_runs = 0;
    my $accepted = async sub {
        my ($request_scope, $request_receive, $send) = @_;
        await Future->wrap($send->({
            type => 'http.response.start', status => 200, headers => [],
        }));
        await Future->wrap($send->({
            type => 'http.response.body', body => 'first', more => 1,
        }));
        await $accepted_gate;
        await Future->wrap($send->({
            type => 'http.response.body', body => 'last', more => 0,
        }));
        return;
    };
    my $accepted_cascade = PAGI::App::Cascade->new(apps => [
        $accepted,
        async sub { ++$accepted_next_runs; return },
    ])->to_app;
    my @accepted_events;
    my $accepted_running = $accepted_cascade->(
        scope(path => '/stream'),
        \&receive,
        sub { push @accepted_events, $_[0]; return Future->done },
    );
    is([map { $_->{type} } @accepted_events], [
        'http.response.start', 'http.response.body',
    ], 'accepted start and first chunk are forwarded before completion');
    is($accepted_events[1]{body}, 'first',
        'the first streaming chunk is forwarded immediately');
    ok(!$accepted_running->is_ready, 'Cascade awaits the accepted child');
    $accepted_gate->done;
    Future->wrap($accepted_running)->get;
    is(response_body(\@accepted_events), 'firstlast',
        'the accepted terminal chunk is forwarded');
    is($accepted_next_runs, 0, 'an accepted stream owns the response');

    my $duplicate_next_runs = 0;
    my $duplicate_start = PAGI::App::Cascade->new(apps => [
        async sub {
            my ($request_scope, $request_receive, $send) = @_;
            await Future->wrap($send->({
                type => 'http.response.start', status => 200, headers => [],
            }));
            await Future->wrap($send->({
                type => 'http.response.start', status => 404, headers => [],
            }));
            await Future->wrap($send->({
                type => 'http.response.body', body => 'owner', more => 0,
            }));
            return;
        },
        async sub { ++$duplicate_next_runs; return },
    ])->to_app;
    my ($duplicate_events, $duplicate_error) = run_app(
        $duplicate_start,
        scope(path => '/duplicate-start'),
    );
    is($duplicate_error, undef,
        'an accepted child remains the response owner after a second start');
    is([map { $_->{status} }
        grep { ($_->{type} // '') eq 'http.response.start' }
        @$duplicate_events], [200, 404],
        'later starts are forwarded without changing the first disposition');
    is(response_body($duplicate_events), 'owner',
        'the accepted child terminal body remains forwarded');
    is($duplicate_next_runs, 0,
        'a later catch-status start cannot advance after wire output escaped');

    my $caught_gate = Future->new;
    my $caught_next_runs = 0;
    my $caught = async sub {
        my ($request_scope, $request_receive, $send) = @_;
        await Future->wrap($send->({
            type => 'http.response.start', status => 404, headers => [],
        }));
        await Future->wrap($send->({
            type => 'http.response.body', body => 'hidden', more => 1,
        }));
        await $caught_gate;
        await Future->wrap($send->({
            type => 'http.response.body', body => 'also hidden', more => 0,
        }));
        return;
    };
    my $caught_cascade = PAGI::App::Cascade->new(apps => [
        $caught,
        async sub {
            my ($request_scope, $request_receive, $send) = @_;
            ++$caught_next_runs;
            await Future->wrap($send->({
                type => 'http.response.start', status => 200, headers => [],
            }));
            await Future->wrap($send->({
                type => 'http.response.body', body => 'visible', more => 0,
            }));
            return;
        },
    ])->to_app;
    my @caught_events;
    my $caught_running = $caught_cascade->(
        scope(path => '/caught'),
        \&receive,
        sub { push @caught_events, $_[0]; return Future->done },
    );
    is(\@caught_events, [], 'caught start and chunks are suppressed');
    is($caught_next_runs, 0, 'the next child waits for caught completion');
    ok(!$caught_running->is_ready, 'Cascade awaits the caught child');
    $caught_gate->done;
    Future->wrap($caught_running)->get;
    is($caught_next_runs, 1, 'the next child begins after caught completion');
    is(response_start(\@caught_events)->{status}, 200,
        'only the next child start reaches the wire');
    is(response_body(\@caught_events), 'visible',
        'no caught body reaches the wire');

    my (undef, $body_error) = run_app(
        PAGI::App::Cascade->new(apps => [async sub {
            my ($request_scope, $request_receive, $send) = @_;
            await Future->wrap($send->({
                type => 'http.response.body', body => 'invalid', more => 0,
            }));
            return;
        }])->to_app,
        scope(path => '/body-first'),
    );
    isa_ok($body_error, ['PAGI::Exception::IncompleteResponse'],
        'body before start is a typed failure');
    is($body_error && ref($body_error) ? $body_error->stage : undef,
        'body_before_start',
        'body before start reports the exact lifecycle stage');

    local $ENV{PAGI_ENV} = 'development';
    my $incomplete_next_runs = 0;
    my $incomplete_router = router(routes => [
        route('/incomplete', raw => async sub {
            my ($request_scope, $request_receive, $send) = @_;
            await Future->wrap($send->({
                type => 'http.response.start', status => 404, headers => [],
            }));
            return;
        }, desc => 'caught incomplete child'),
    ])->to_app;
    my $incomplete_cascade = PAGI::App::Cascade->new(apps => [
        $incomplete_router,
        async sub { ++$incomplete_next_runs; return },
    ])->to_app;
    my ($incomplete_scope, $incomplete_trace)
        = PAGI::Routing::Trace->_ensure_http_scope(
            scope(path => '/incomplete'),
        );
    my $incomplete_checkpoint = $incomplete_trace->checkpoint;
    my ($incomplete_events, $incomplete_error)
        = run_app($incomplete_cascade, $incomplete_scope);
    isa_ok($incomplete_error, ['PAGI::Exception::IncompleteResponse'],
        'a caught incomplete response is a typed failure');
    is($incomplete_error->stage, 'after_start',
        'caught incompletion reports the post-start stage');
    is($incomplete_events, [], 'the incomplete caught start stays suppressed');
    is($incomplete_next_runs, 0,
        'caught incompletion does not advance to the next child');
    is(
        attempt_descriptions(
            $incomplete_trace->snapshot($incomplete_checkpoint),
        ),
        ['caught incomplete child'],
        'an incomplete caught child trace window is not discarded',
    );

    my $post_start = PAGI::App::Cascade->new(apps => [
        async sub {
            my ($request_scope, $request_receive, $send) = @_;
            await Future->wrap($send->({
                type => 'http.response.start', status => 200, headers => [],
            }));
            die "stream failed after start\n";
        },
        response_app(200, 'unused'),
    ])->to_app;
    my ($post_events, $post_error) = run_app(
        $post_start,
        scope(path => '/post-start'),
    );
    like($post_error, qr/stream failed after start/,
        'an exception after a forwarded start propagates');
    is([map { $_->{type} } @$post_events], ['http.response.start'],
        'the already-forwarded start is not withdrawn or replaced');
};

subtest 'non-HTTP Cascade behavior remains the legacy buffered snapshot' => sub {
    my @cases = (
        ['websocket', { type => 'websocket.accept' }],
        ['sse', { type => 'sse.start', status => 200 }],
        ['lifespan', { type => 'lifespan.startup.complete' }],
        ['example.extension', { type => 'example.event', value => 'one' }],
    );

    for my $case (@cases) {
        my ($type, $event) = @$case;
        my $gate = Future->new;
        my $same_named = bless {}, 'Local::NonHTTPTraceValue';
        my $seen_scope;
        my $later_runs = 0;
        my $first = async sub {
            my ($request_scope, $request_receive, $send) = @_;
            $seen_scope = $request_scope;
            await Future->wrap($send->($event));
            await $gate;
            return;
        };
        my $cascade = PAGI::App::Cascade->new(apps => [
            $first,
            async sub { ++$later_runs; return },
            async sub { ++$later_runs; return },
        ])->to_app;
        my $request_scope = {
            type                 => $type,
            path                 => '/',
            'pagi.routing.trace' => $same_named,
        };
        my @events;
        my $running = $cascade->(
            $request_scope,
            sub { Future->done },
            sub { push @events, $_[0]; return Future->done },
        );
        is(\@events, [], "$type first-child events remain buffered");
        ok(!$running->is_ready, "$type waits for first-child completion");
        is($later_runs, 0, "$type does not invoke a later child while pending");
        is(refaddr($seen_scope), refaddr($request_scope),
            "$type receives the original scope object");
        is(refaddr($seen_scope->{'pagi.routing.trace'}), refaddr($same_named),
            "$type preserves same-named scope data by identity");
        $gate->done;
        Future->wrap($running)->get;
        is(\@events, [$event], "$type replays buffered events after completion");
        is($later_runs, 0, "$type returns without invoking later children");

        my ($empty_events, $empty_error) = run_app(
            PAGI::App::Cascade->new(apps => [])->to_app,
            $request_scope,
        );
        is($empty_error, undef, "$type empty Cascade completes normally");
        is($empty_events, [], "$type empty Cascade remains silent");
    }
};

subtest 'URLMap targets are opaque HTTP application boundaries' => sub {
    my ($parent_scope, $parent_trace) = PAGI::Routing::Trace->_ensure_http_scope(
        scope(
            path      => '/api/missing',
            root_path => '/outer',
            state     => { request_id => 7 },
        ),
    );
    my $parent_checkpoint = $parent_trace->checkpoint;
    my $naked_router = router(routes => [
        route('/exists' => sub { return $_[0]->text('exists') }),
    ])->to_app;
    my $direct_mount = PAGI::App::URLMap->new;
    $direct_mount->mount('/api' => $naked_router);
    my ($direct_events, $direct_error) = run_app(
        $direct_mount->to_app,
        $parent_scope,
    );
    is($direct_error, undef, 'a naked child Router decline completes opaquely');
    is($direct_events, [], 'the naked child Router remains unanswered directly');
    is(refaddr($parent_scope->{'pagi.routing.trace'}), refaddr($parent_trace),
        'URLMap does not replace the incoming parent trace');
    ok(!$parent_trace->snapshot($parent_checkpoint)->routing_declined,
        'the naked child publishes no records into the parent trace');

    my @mounted_scopes;
    my $unrelated = {};
    my $scope_map = PAGI::App::URLMap->new(
        default => async sub {
            push @mounted_scopes, ['default', $_[0]];
            return;
        },
    );
    $scope_map->mount('/api' => async sub {
        push @mounted_scopes, ['mount', $_[0]];
        return;
    });
    run_app($scope_map->to_app, {
        %$parent_scope,
        path      => '/api/users',
        root_path => '/outer',
        unrelated => $unrelated,
    });
    run_app($scope_map->to_app, {
        %$parent_scope,
        path      => '/elsewhere',
        root_path => '/outer',
        unrelated => $unrelated,
    });
    is($mounted_scopes[0][1]{path}, '/users', 'mount path rewriting is retained');
    is($mounted_scopes[0][1]{root_path}, '/outer/api',
        'mount root_path rewriting is retained');
    is(refaddr($mounted_scopes[0][1]{unrelated}), refaddr($unrelated),
        'mount shallow cloning preserves unrelated values');
    ok(!exists $mounted_scopes[0][1]{'pagi.routing.trace'},
        'selected HTTP mount removes the parent trace');
    is($mounted_scopes[1][1]{path}, '/elsewhere',
        'default preserves the selected path');
    is(refaddr($mounted_scopes[1][1]{unrelated}), refaddr($unrelated),
        'default shallow cloning preserves unrelated values');
    ok(!exists $mounted_scopes[1][1]{'pagi.routing.trace'},
        'selected HTTP default removes the parent trace');

    for my $location (qw(mount default)) {
        my $map = PAGI::App::URLMap->new(
            default => $location eq 'default' ? $naked_router : response_app(200, 'unused'),
        );
        $map->mount('/api' => $location eq 'mount'
            ? $naked_router
            : response_app(200, 'unused'));
        my $path = $location eq 'mount' ? '/api/missing' : '/missing';
        local $ENV{PAGI_ENV} = 'production';
        my ($opaque_events, $opaque_error, $opaque_warnings) = run_app(
            compose(app => $map)->to_app,
            scope(path => $path),
        );
        is($opaque_error, undef, "outer Compose contains naked $location incompletion");
        is(response_start($opaque_events)->{status}, 500,
            "naked Router in selected $location is opaque, not outer 404");
        like($opaque_warnings->[0], qr/completed without starting a response/,
            "naked $location is diagnosed as incomplete application output");

        my $child_compose = compose(app => router(routes => [
            route('/exists' => sub { return $_[0]->text('exists') }),
        ]))->to_app;
        my $composed_map = PAGI::App::URLMap->new(
            default => $location eq 'default'
                ? $child_compose
                : response_app(200, 'unused'),
        );
        $composed_map->mount('/api' => $location eq 'mount'
            ? $child_compose
            : response_app(200, 'unused'));
        my ($child_events, $child_error, $child_warnings) = run_app(
            compose(app => $composed_map)->to_app,
            scope(path => $path),
        );
        is($child_error, undef, "child Compose in $location completes");
        is($child_warnings, [], "child Compose in $location does not warn");
        is(response_start($child_events)->{status}, 404,
            "child Compose owns the $location Router 404");
    }

    my $same_named = bless {}, 'Local::URLMapNonHTTPValue';
    my @non_http_seen;
    my $non_http_map = PAGI::App::URLMap->new(
        default => async sub {
            push @non_http_seen, $_[0]{'pagi.routing.trace'};
            return;
        },
    );
    $non_http_map->mount('/api' => async sub {
        push @non_http_seen, $_[0]{'pagi.routing.trace'};
        return;
    });
    run_app($non_http_map->to_app, {
        type => 'websocket', path => '/api/socket',
        'pagi.routing.trace' => $same_named,
    });
    run_app($non_http_map->to_app, {
        type => 'sse', path => '/other',
        'pagi.routing.trace' => $same_named,
    });
    is([map { refaddr($_) } @non_http_seen],
        [refaddr($same_named), refaddr($same_named)],
        'non-HTTP mount and default preserve same-named values by identity');
};

done_testing;
