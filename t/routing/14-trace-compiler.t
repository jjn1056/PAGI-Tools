#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);

use PAGI::Routing qw(router route mount middleware);
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

sub run_app {
    my ($app, $request_scope) = @_;
    my @events;
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    $app->($request_scope, \&receive, $send)->get;
    return \@events;
}

sub response_app {
    my ($status, $body) = @_;
    return async sub {
        my ($request_scope, $receive, $send) = @_;
        await Future->wrap($send->({
            type => 'http.response.start',
            status => $status,
            headers => [],
        }));
        await Future->wrap($send->({
            type => 'http.response.body',
            body => $body,
            more => 0,
        }));
    };
}

sub observing_middleware {
    my ($observations) = @_;
    return middleware(sub {
        my ($inner) = @_;
        return async sub {
            my @arguments = @_;
            my $request_scope = $arguments[0];
            my $trace = $request_scope->{'pagi.routing.trace'};
            my $checkpoint = $trace->checkpoint;
            my $returned = $inner->(@arguments);
            await Future->wrap($returned);
            push @$observations, {
                trace      => $trace,
                trace_id   => refaddr($trace),
                scope      => $request_scope,
                snapshot   => $trace->snapshot($checkpoint),
            };
        };
    });
}

subtest 'real compiler publishes root decisions without changing dispatch' => sub {
    my @observations;
    my $child = router(routes => [
        route('/item' => sub { return $_[0]->text('child') }),
    ]);
    my $app = router(
        middleware => [observing_middleware(\@observations)],
        routes => [
            route('/same' => sub { return $_[0]->text('get') },
                methods => 'GET', name => 'get', desc => 'GET candidate'),
            route('/same' => sub { return $_[0]->text('post') },
                methods => 'POST', name => 'post', desc => 'POST candidate'),
            route('/same' => sub { return $_[0]->text('full') },
                methods => '*', name => 'full', desc => 'Later full'),
            mount('/inline', routes => [
                route('/item' => sub { return $_[0]->text('inline') }),
            ]),
            mount('/child', router => $child, name => 'child'),
            route('/raw', raw => response_app(204, '')),
            mount('/opaque' => response_app(200, 'opaque')),
        ],
    )->to_app;

    my $events = run_app($app, scope(
        method => 'DELETE', path => '/same', raw_path => '/same',
    ));
    is($events->[0]{status}, 200,
        'the later FULL declaration still owns the HTTP outcome');
    my $later_full_snapshot = $observations[-1]{snapshot};
    ok(!$later_full_snapshot->routing_declined,
        'a later FULL supersedes discarded partials');
    ok(!$later_full_snapshot->path_matched,
        'successful routing does not publish decline path facts');
    is($later_full_snapshot->allowed_methods, [],
        'discarded partial methods are absent after a later FULL');

    @observations = ();
    $events = run_app($app, scope(
        method => 'DELETE',
        path => '/inline/item',
        raw_path => '/inline/item',
    ));
    is($events, [], 'the inline subtree completes unanswered');
    ok($observations[-1]{snapshot}->routing_declined,
        'the root snapshot follows an inline selected child decline');
    is($observations[-1]{snapshot}->allowed_methods, [qw(GET HEAD)],
        'the inline selected child publishes its local methods once');

    @observations = ();
    $events = run_app($app, scope(
        path => '/child/missing', raw_path => '/child/missing',
    ));
    is($events, [], 'the Router child completes unanswered');
    ok($observations[-1]{snapshot}->routing_declined,
        'the parent snapshot follows its selected Router child summary');
    ok(!$observations[-1]{snapshot}->path_matched,
        'the selected Router child publishes a no-path decline');
};

subtest 'partial compiler frames fold as first-seen siblings' => sub {
    my $get = router(routes => [
        route('/same' => sub { return $_[0]->text('get') }, methods => 'GET'),
    ])->to_app;
    my $post = router(routes => [
        route('/same' => sub { return $_[0]->text('post') }, methods => 'POST'),
    ])->to_app;

    my ($request_scope, $trace) = PAGI::Routing::Trace->_ensure_http_scope(
        scope(method => 'DELETE', path => '/same', raw_path => '/same'),
    );
    my $checkpoint = $trace->checkpoint;
    is(run_app($get, $request_scope), [],
        'the first Router completes unanswered');
    is(run_app($post, $request_scope), [],
        'the second Router completes unanswered');

    my $snapshot = $trace->snapshot($checkpoint);
    ok($snapshot->routing_declined,
        'two independently compiled Routers publish sibling declines');
    ok($snapshot->path_matched,
        'PARTIAL sibling summaries retain their path matches');
    ok(!$snapshot->method_matched,
        'PARTIAL sibling summaries do not claim method acceptance');
    is($snapshot->allowed_methods, [qw(GET HEAD POST)],
        'PARTIAL siblings publish first-seen methods');

    my ($reverse_scope, $reverse_trace) = PAGI::Routing::Trace->_ensure_http_scope(
        scope(method => 'DELETE', path => '/same', raw_path => '/same'),
    );
    my $reverse_checkpoint = $reverse_trace->checkpoint;
    run_app($post, $reverse_scope);
    run_app($get, $reverse_scope);
    is($reverse_trace->snapshot($reverse_checkpoint)->allowed_methods,
        [qw(POST GET HEAD)],
        'sequential sibling methods follow first-seen execution order');
};

subtest 'a mount checkpoint sees one selected child summary' => sub {
    my @mount_snapshots;
    my $checkpointing_mount = middleware(sub {
        my ($inner) = @_;
        return async sub {
            my @arguments = @_;
            my $trace = $arguments[0]{'pagi.routing.trace'};
            my $checkpoint = $trace->checkpoint;
            my $returned = $inner->(@arguments);
            await Future->wrap($returned);
            push @mount_snapshots, $trace->snapshot($checkpoint);
        };
    });
    my $child = router(routes => [
        mount('/nested', routes => [
            route('/item' => sub { return $_[0]->text('item') },
                methods => 'POST'),
        ]),
    ]);
    my $app = router(routes => [
        mount('/child', router => $child, name => 'child',
            middleware => [$checkpointing_mount]),
    ])->to_app;

    my $events = run_app($app, scope(
        method => 'GET',
        path => '/child/nested/item',
        raw_path => '/child/nested/item',
    ));
    is($events, [], 'nested child dispatch completes unanswered');
    is(scalar @mount_snapshots, 1,
        'mount middleware records one completed checkpoint window');
    ok($mount_snapshots[0]->routing_declined,
        'a parent frame begun before the checkpoint follows its child');
    is($mount_snapshots[0]->allowed_methods, ['POST'],
        'the nested child decline is counted exactly once');
};

subtest 'successful sibling frames do not add decline evidence' => sub {
    my $declining = router(routes => [
        route('/same' => sub { return $_[0]->text('get') }, methods => 'GET'),
    ])->to_app;
    my $successful = router(routes => [
        route('/same' => sub { return $_[0]->text('ok') }, methods => '*'),
    ])->to_app;
    my ($request_scope, $trace) = PAGI::Routing::Trace->_ensure_http_scope(
        scope(method => 'DELETE', path => '/same', raw_path => '/same'),
    );
    my $checkpoint = $trace->checkpoint;

    run_app($declining, $request_scope);
    run_app($successful, $request_scope);
    my $snapshot = $trace->snapshot($checkpoint);
    ok($snapshot->routing_declined,
        'the qualifying sibling decline remains visible');
    is($snapshot->allowed_methods, [qw(GET HEAD)],
        'a successful sibling contributes no allowed methods');
};

subtest 'environment policy is lazy and development details are bounded and safe' => sub {
    my $declining = router(routes => [
        route('/same' => sub { return $_[0]->text('get') },
            methods => 'GET'),
    ])->to_app;

    for my $environment (qw(production test staging)) {
        local $ENV{PAGI_ENV} = $environment;
        my ($request_scope, $trace) = PAGI::Routing::Trace->_ensure_http_scope(
            scope(method => 'POST', path => '/same', raw_path => '/same'),
        );
        my $checkpoint = $trace->checkpoint;
        run_app($declining, $request_scope);
        my $snapshot = $trace->snapshot($checkpoint);
        ok($snapshot->routing_declined,
            "$environment retains compact routing summaries");
        is($snapshot->allowed_methods, [qw(GET HEAD)],
            "$environment retains allowed-method summaries");
        is($snapshot->attempts, [],
            "$environment exposes no development attempts");
        ok(!$snapshot->details_available,
            "$environment reports development details unavailable");
    }

    local $ENV{PAGI_ENV} = 'development';
    my @routes = (
        route('/safe/{id}' => sub { return $_[0]->text('safe') },
            methods => 'GET', name => 'safe', desc => 'Safe candidate'),
    );
    push @routes, map {
        route("/candidate-$_" => sub { return $_[0]->text('unused') },
            methods => 'POST', desc => "Candidate $_")
    } 1 .. 256;
    my $detailed = router(routes => \@routes)->to_app;
    my ($detail_scope, $detail_trace) = PAGI::Routing::Trace->_ensure_http_scope(
        scope(
            method => 'DELETE',
            path => '/safe/SECRET_CAPTURE',
            raw_path => '/safe/SECRET_CAPTURE',
            path_params => { incoming => 'SECRET_PARAMETER' },
            headers => [['cookie', 'SECRET_COOKIE']],
            cookies => { session => 'SECRET_SESSION' },
            body => 'SECRET_BODY',
        ),
    );
    my $detail_checkpoint = $detail_trace->checkpoint;
    run_app($detailed, $detail_scope);
    my $detail_snapshot = $detail_trace->snapshot($detail_checkpoint);
    my $attempts = $detail_snapshot->attempts;
    is(scalar @$attempts, 256,
        'development exposes only the first 256 candidate attempts');
    ok($detail_snapshot->details_available,
        'development reports candidate details available');
    ok($detail_snapshot->truncated,
        'the 257th candidate marks the checkpoint window truncated');
    is([sort keys %{$attempts->[0]}], [sort qw(
        namespace pattern name desc candidate_kind path_matched method_matched
    )], 'attempts contain only approved declaration and Boolean match keys');
    is($attempts->[0], {
        namespace => '/',
        pattern => '/safe/{id}',
        name => '/safe',
        desc => 'Safe candidate',
        candidate_kind => 'route',
        path_matched => 1,
        method_matched => 0,
    }, 'the development record contains declaration metadata without captures');
    my $detail_text = join ' ', map {
        join ' ', map { defined $_ ? $_ : '' } values %$_
    } @$attempts;
    unlike($detail_text,
        qr/SECRET_(?:CAPTURE|PARAMETER|COOKIE|SESSION|BODY)/,
        'attempt details never copy scope headers, cookies, bodies, or captures');

    my $mounted_details = router(routes => [
        mount('/api', name => 'api', routes => [
            route('/items' => sub { return $_[0]->text('items') },
                methods => 'POST', name => 'show'),
        ]),
    ])->to_app;
    my ($mounted_scope, $mounted_trace)
        = PAGI::Routing::Trace->_ensure_http_scope(scope(
            method => 'GET', path => '/api/items', raw_path => '/api/items',
        ));
    my $mounted_checkpoint = $mounted_trace->checkpoint;
    run_app($mounted_details, $mounted_scope);
    my $mounted_attempts
        = $mounted_trace->snapshot($mounted_checkpoint)->attempts;
    is([map { $_->{pattern} } @$mounted_attempts], ['/api', '/items'],
        'mounted attempts expose declaration-local patterns');
    is($mounted_attempts->[1]{name}, '/api/show',
        'mounted attempts retain the effective logical route name');

    {
        local $ENV{PAGI_ENV} = 'invalid-environment';
        my $empty = router(routes => [])->to_app;
        my ($invalid_scope, $invalid_trace)
            = PAGI::Routing::Trace->_ensure_http_scope(scope());
        my $checkpoint = $invalid_trace->checkpoint;
        isa_ok($checkpoint, ['PAGI::Routing::Trace::_Checkpoint'],
            'construction and checkpointing do not resolve PAGI_ENV');
        like(
            dies { run_app($empty, $invalid_scope) },
            qr/Invalid PAGI_ENV 'invalid-environment'/,
            'the first compiler frame begin resolves and rejects PAGI_ENV',
        );
    }
};

subtest 'raw routes and opaque mounts shield parent evidence' => sub {
    my (@parent_observations, @child_observations);
    my $child_observer = middleware(sub {
        my ($inner) = @_;
        return async sub {
            my @arguments = @_;
            my $request_scope = $arguments[0];
            my $trace = $request_scope->{'pagi.routing.trace'};
            my $checkpoint = $trace->checkpoint;
            push @child_observations, {
                trace => $trace,
                scope => $request_scope,
                receive_id => refaddr($arguments[1]),
                send_id => refaddr($arguments[2]),
                checkpoint => $checkpoint,
            };
            my $returned = $inner->(@arguments);
            await Future->wrap($returned);
            $child_observations[-1]{snapshot}
                = $trace->snapshot($checkpoint);
        };
    });
    my $child_router = router(
        middleware => [$child_observer],
        routes => [
            route('/' => sub { return $_[0]->text('child') }, methods => 'GET'),
            route('/raw' => sub { return $_[0]->text('raw child') }, methods => 'GET'),
        ],
    );
    my $raw_child_app = $child_router->to_app;
    my $shared = { identity => 'preserved' };
    my @channel_ids;
    my $channels = middleware(sub {
        my ($inner) = @_;
        return async sub {
            push @channel_ids, {
                receive_id => refaddr($_[1]),
                send_id => refaddr($_[2]),
                routing => $_[0]{'pagi.routing'},
                unrelated => $_[0]{unrelated},
            };
            my $returned = $inner->(@_);
            await Future->wrap($returned);
        };
    });
    my $parent = router(
        middleware => [observing_middleware(\@parent_observations)],
        routes => [
            mount('/opaque' => $child_router, middleware => [$channels]),
            route('/raw', raw => $raw_child_app,
                methods => '*', middleware => [$channels]),
        ],
    )->to_app;

    for my $case (
        ['opaque', '/opaque'],
        ['raw', '/raw'],
    ) {
        my ($label, $path) = @$case;
        my $request_scope = scope(
            method => 'POST', path => $path, raw_path => $path,
            unrelated => $shared,
        );
        my $events = run_app($parent, $request_scope);
        is($events, [], "$label child completes independently unanswered");
        my $parent_observation = $parent_observations[-1];
        my $child_observation = $child_observations[-1];
        isnt(refaddr($parent_observation->{trace}),
            refaddr($child_observation->{trace}),
            "$label child installs an independent Trace");
        ok(!$parent_observation->{snapshot}->routing_declined,
            "$label parent records a selected non-decline target");
        ok($child_observation->{snapshot}->routing_declined,
            "$label child records its own trusted decline");
        is($channel_ids[-1]{unrelated}, $shared,
            "$label shielding preserves unrelated scope values by identity");
        is($channel_ids[-1]{routing},
            $parent_observation->{scope}{'pagi.routing'},
            "$label shielding preserves reverse-routing metadata identity");
        is([$child_observation->{receive_id}, $child_observation->{send_id}],
            [$channel_ids[-1]{receive_id}, $channel_ids[-1]{send_id}],
            "$label shielding preserves both channel identities");
    }
};

subtest 'the private selected-child link is consumed once inside dispatch' => sub {
    my @short_observations;
    my $short_child = router(
        middleware => [middleware(sub {
            my ($inner) = @_;
            return async sub {
                my ($request_scope, $receive, $send) = @_;
                await Future->wrap($send->({
                    type => 'http.response.start', status => 204, headers => [],
                }));
                await Future->wrap($send->({
                    type => 'http.response.body', body => '', more => 0,
                }));
            };
        })],
        routes => [
            route('/item' => sub { return $_[0]->text('must not run') }),
        ],
    );
    my $short_parent = router(
        middleware => [observing_middleware(\@short_observations)],
        routes => [
            mount('/child', router => $short_child, name => 'child'),
        ],
    )->to_app;
    my $events = run_app($short_parent, scope(
        path => '/child/missing', raw_path => '/child/missing',
    ));
    is($events->[0]{status}, 204,
        'child Router middleware may still short-circuit its dispatcher');
    ok(!$short_observations[-1]{snapshot}->routing_declined,
        'an unconsumed selected-child link completes as non-decline evidence');

    my $private_key = "\0PAGI::Routing::Trace::parent";
    my (@copy_observations, $original_retained_link, $copy_consumed_link,
        $copy_preserved_unknown);
    my $copying_child = router(
        middleware => [middleware(sub {
            my ($inner) = @_;
            return async sub {
                my ($request_scope, $receive, $send) = @_;
                my $copied_scope = { %$request_scope };
                $copy_preserved_unknown
                    = refaddr($copied_scope->{preserved_unknown})
                    == refaddr($request_scope->{preserved_unknown});
                my $returned = $inner->($copied_scope, $receive, $send);
                await Future->wrap($returned);
                $original_retained_link
                    = exists $request_scope->{$private_key};
                $copy_consumed_link
                    = !exists $copied_scope->{$private_key};
            };
        })],
        routes => [
            route('/item' => sub { return $_[0]->text('post') },
                methods => 'POST'),
        ],
    );
    my $copying_parent = router(
        middleware => [observing_middleware(\@copy_observations)],
        routes => [
            mount('/child', router => $copying_child, name => 'child'),
        ],
    )->to_app;
    my $copy_events = run_app($copying_parent, scope(
        method => 'GET',
        path => '/child/item',
        raw_path => '/child/item',
        preserved_unknown => { identity => 'unchanged' },
    ));
    is($copy_events, [],
        'scope-copying child middleware preserves unanswered completion');
    ok($original_retained_link,
        'the parent-owned scope still contains the preserved unknown link key');
    ok($copy_consumed_link,
        'the child dispatcher consumes the link from the forwarded scope copy');
    ok($copy_preserved_unknown,
        'the shallow scope copy preserves unrelated unknown values by identity');
    ok($copy_observations[-1]{snapshot}->routing_declined,
        'parent completion follows the link consumed through a scope copy');
    is($copy_observations[-1]{snapshot}->allowed_methods, ['POST'],
        'the copied-scope child decline folds into the parent summary');

    my $handler_saw_private_key;
    my $reusing_child = router(
        middleware => [middleware(sub {
            my ($inner) = @_;
            return async sub {
                my @arguments = @_;
                my $link = $arguments[0]{$private_key};
                my $first = $inner->(@arguments);
                await Future->wrap($first);
                $arguments[0]{$private_key} = $link;
                my $second = $inner->(@arguments);
                await Future->wrap($second);
            };
        })],
        routes => [
            route('/item' => sub {
                $handler_saw_private_key = exists $_[0]->scope->{$private_key};
                return $_[0]->text('item');
            }),
        ],
    );
    my $reusing_parent = router(routes => [
        mount('/child', router => $reusing_child, name => 'child'),
    ])->to_app;
    my ($reusing_scope, $reusing_trace)
        = PAGI::Routing::Trace->_ensure_http_scope(scope(
            path => '/child/item', raw_path => '/child/item',
        ));
    my $checkpoint = $reusing_trace->checkpoint;
    like(
        dies { run_app($reusing_parent, $reusing_scope) },
        qr/routing parent link has already been consumed/,
        'reusing one selected-child link for a second dispatch croaks',
    );
    ok(!$handler_saw_private_key,
        'the child dispatcher removes the private link before Context creation');
    ok(!$reusing_trace->snapshot($checkpoint)->routing_declined,
        'a child-link reuse exception does not fabricate decline evidence');
};

done_testing;
