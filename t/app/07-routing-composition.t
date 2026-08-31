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
use PAGI::Response::Text ();
use PAGI::Routing qw(router route);

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

subtest 'Cascade catches Router-owned HTTP outcomes and propagates failures' => sub {
    my $get_router = router(routes => [
        route('/only' => sub { return PAGI::Response::Text->new('only') },
            methods => 'GET'),
    ])->to_app;
    my $post_router = router(routes => [
        route('/only' => sub { return PAGI::Response::Text->new('post') },
            methods => 'POST'),
    ])->to_app;

    my $after_none = PAGI::App::Cascade->new(apps => [
        $get_router,
        response_app(200, 'after none'),
    ])->to_app;
    my ($none_events, $none_error) = run_app(
        $after_none, scope(path => '/missing'),
    );
    is($none_error, undef, 'a non-final Router 404 is a normal caught response');
    is([response_start($none_events)->{status}, response_body($none_events)],
        [200, 'after none'], 'Cascade advances after a caught Router 404');

    my $after_partial = PAGI::App::Cascade->new(apps => [
        $get_router,
        response_app(200, 'after partial'),
    ])->to_app;
    my ($partial_events, $partial_error) = run_app(
        $after_partial, scope(method => 'PUT', path => '/only'),
    );
    is($partial_error, undef, 'a non-final Router 405 is a normal caught response');
    is([response_start($partial_events)->{status}, response_body($partial_events)],
        [200, 'after partial'], 'Cascade advances after a caught Router 405');

    for my $case (
        ['NONE', $get_router, scope(path => '/missing'), 404, undef],
        ['PARTIAL', $post_router, scope(method => 'PUT', path => '/only'),
            405, 'POST'],
    ) {
        my ($label, $app, $request_scope, $status, $allow) = @$case;
        my ($events, $error) = run_app(
            PAGI::App::Cascade->new(apps => [$app])->to_app,
            $request_scope,
        );
        is($error, undef, "final Router $label completes");
        is(response_start($events)->{status}, $status,
            "final Router owns its $status");
        is(response_header($events, 'Allow'), $allow,
            "final Router $label retains its Allow outcome");
    }

    my $next_runs = 0;
    my $throwing = router(routes => [
        route('/boom' => sub { die "router child exploded\n" }),
    ])->to_app;
    my ($exception_events, $exception_error) = run_app(
        PAGI::App::Cascade->new(apps => [
            $throwing,
            async sub { ++$next_runs; return },
        ])->to_app,
        scope(path => '/boom'),
    );
    like($exception_error, qr/router child exploded/,
        'a selected Router exception propagates unchanged');
    is($exception_events, [], 'the exception emits no synthetic response');
    is($next_runs, 0, 'an exception never advances to the next child');

    my ($silent_events, $silent_error) = run_app(
        PAGI::App::Cascade->new(apps => [
            async sub { return },
            response_app(200, 'unused'),
        ])->to_app,
        scope(path => '/silent'),
    );
    isa_ok($silent_error, ['PAGI::Exception::IncompleteResponse'],
        'silence is an application lifecycle failure rather than decline');
    is($silent_error->stage, 'before_start',
        'silent completion fails before response start');
    is($silent_events, [], 'silent completion emits nothing');
};

subtest 'HTTP Cascade streams accepted apps and suppresses caught apps' => sub {
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
    ], 'accepted response events stream before application completion');
    ok(!$accepted_running->is_ready, 'Cascade awaits the accepted app');
    $accepted_gate->done;
    Future->wrap($accepted_running)->get;
    is(response_body(\@accepted_events), 'firstlast',
        'the accepted terminal chunk reaches the wire');
    is($accepted_next_runs, 0, 'an accepted stream owns the response');

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
    is(\@caught_events, [], 'caught response events remain suppressed');
    is($caught_next_runs, 0, 'the next app waits for caught completion');
    $caught_gate->done;
    Future->wrap($caught_running)->get;
    is($caught_next_runs, 1, 'the next app begins after caught completion');
    is([response_start(\@caught_events)->{status}, response_body(\@caught_events)],
        [200, 'visible'], 'only the accepted next response reaches the wire');

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
    is($body_error->stage, 'body_before_start',
        'body before start reports its exact lifecycle stage');

    my $incomplete_next_runs = 0;
    my ($incomplete_events, $incomplete_error) = run_app(
        PAGI::App::Cascade->new(apps => [
            async sub {
                my ($request_scope, $request_receive, $send) = @_;
                await Future->wrap($send->({
                    type => 'http.response.start', status => 404, headers => [],
                }));
                return;
            },
            async sub { ++$incomplete_next_runs; return },
        ])->to_app,
        scope(path => '/caught-incomplete'),
    );
    isa_ok($incomplete_error, ['PAGI::Exception::IncompleteResponse'],
        'a caught response without a terminal body is a typed failure');
    is($incomplete_error->stage, 'after_start',
        'caught incompletion reports the post-start stage');
    is($incomplete_events, [],
        'the incomplete caught start remains suppressed');
    is($incomplete_next_runs, 0,
        'caught incompletion never advances to the next application');

    my ($post_start_events, $post_start_error) = run_app(
        PAGI::App::Cascade->new(apps => [
            async sub {
                my ($request_scope, $request_receive, $send) = @_;
                await Future->wrap($send->({
                    type => 'http.response.start', status => 200, headers => [],
                }));
                die "stream failed after start\n";
            },
            response_app(200, 'unused'),
        ])->to_app,
        scope(path => '/post-start'),
    );
    like($post_start_error, qr/stream failed after start/,
        'an exception after a forwarded response start propagates');
    is([map { $_->{type} } @$post_start_events], ['http.response.start'],
        'the already-forwarded start is preserved');
};

subtest 'non-HTTP Cascade buffers only its first application' => sub {
    for my $case (
        ['websocket', { type => 'websocket.accept' }],
        ['sse', { type => 'sse.start', status => 200 }],
        ['lifespan', { type => 'lifespan.startup.complete' }],
        ['example.extension', { type => 'example.event', value => 'one' }],
    ) {
        my ($type, $event) = @$case;
        my $gate = Future->new;
        my $same_named = bless {}, 'Local::NonHTTPRoutingValue';
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
        ])->to_app;
        my $request_scope = {
            type           => $type,
            path           => '/',
            'pagi.routing' => $same_named,
        };
        my @events;
        my $running = $cascade->(
            $request_scope,
            sub { Future->done },
            sub { push @events, $_[0]; return Future->done },
        );
        is(\@events, [], "$type events remain buffered while pending");
        ok(!$running->is_ready, "$type waits for first-app completion");
        is($later_runs, 0, "$type never runs a later app while pending");
        is(refaddr($seen_scope), refaddr($request_scope),
            "$type receives the original scope object");
        is(refaddr($seen_scope->{'pagi.routing'}), refaddr($same_named),
            "$type preserves same-named data by identity");
        $gate->done;
        Future->wrap($running)->get;
        is(\@events, [$event], "$type replays buffered events after completion");
        is($later_runs, 0, "$type returns without running later apps");

        my ($empty_events, $empty_error) = run_app(
            PAGI::App::Cascade->new(apps => [])->to_app,
            $request_scope,
        );
        is($empty_error, undef, "$type empty Cascade completes normally");
        is($empty_events, [], "$type empty Cascade remains silent");
    }
};

subtest 'URLMap keeps Router applications opaque but complete' => sub {
    my @selected_scopes;
    my $child = router(routes => [
        route('/exists' => sub {
            push @selected_scopes, $_[0]->scope;
            return PAGI::Response::Text->new('exists');
        }),
    ]);
    my $map = PAGI::App::URLMap->new(default => $child);
    $map->mount('/api' => $child);

    my ($matched, $matched_error) = run_app(
        $map->to_app,
        scope(path => '/api/exists', root_path => '/outer'),
    );
    is($matched_error, undef, 'a selected Router application completes');
    is(response_body($matched), 'exists', 'the child route responds');
    is([$selected_scopes[0]{path}, $selected_scopes[0]{root_path}],
        ['/exists', '/outer/api'], 'URLMap rewrites path and root_path');

    my ($mounted_missing, $mounted_error) = run_app(
        $map->to_app, scope(path => '/api/missing'),
    );
    is($mounted_error, undef, 'a mounted Router NONE is a complete outcome');
    is(response_start($mounted_missing)->{status}, 404,
        'the mounted child owns its negotiated 404');

    my ($default_missing, $default_error) = run_app(
        $map->to_app, scope(path => '/missing'),
    );
    is($default_error, undef, 'a default Router NONE is a complete outcome');
    is(response_start($default_missing)->{status}, 404,
        'the default child owns its negotiated 404');

    my $unrelated = {};
    my $selected_metadata = {
        version => 1,
        frames  => [{ logical_namespace => '/outer' }],
    };
    my @opaque_seen;
    my $opaque = PAGI::App::URLMap->new(
        default => async sub {
            push @opaque_seen, $_[0];
            return;
        },
    );
    $opaque->mount('/api' => async sub {
        push @opaque_seen, $_[0];
        return;
    });
    run_app($opaque->to_app, {
        type => 'http', method => 'GET', path => '/api/x',
        root_path => '/outer', unrelated => $unrelated,
        'pagi.routing' => $selected_metadata,
    });
    run_app($opaque->to_app, {
        type => 'http', method => 'GET', path => '/elsewhere',
        root_path => '/outer', unrelated => $unrelated,
        'pagi.routing' => $selected_metadata,
    });
    is([$opaque_seen[0]{path}, $opaque_seen[0]{root_path}],
        ['/x', '/outer/api'], 'opaque mount scope rewriting remains exact');
    is($opaque_seen[1]{path}, '/elsewhere',
        'opaque default preserves the request path');
    is([map { refaddr($_->{unrelated}) } @opaque_seen],
        [refaddr($unrelated), refaddr($unrelated)],
        'shallow delegated scopes preserve unrelated values');
    is([map { refaddr($_->{'pagi.routing'}) } @opaque_seen],
        [refaddr($selected_metadata), refaddr($selected_metadata)],
        'mount and default preserve selected routing metadata by identity');

    for my $type (qw(websocket sse)) {
        my ($events, $error) = run_app(
            PAGI::App::URLMap->new->to_app,
            { type => $type, path => '/unmapped' },
        );
        like($error, qr/\AURLMap has no default for scope type '\Q$type\E'/,
            "$type exhaustion without a default croaks clearly");
        is($events, [], "$type exhaustion emits no HTTP events");
    }
};

done_testing;
