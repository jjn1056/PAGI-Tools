use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);
use bytes ();
use FindBin qw($Bin);
use lib "$Bin/lib";
use ComposeTest qw(scope run_scope capture_send);
use PAGI::Compose qw(compose);
use PAGI::Response::Empty ();
use PAGI::Response::Text ();
use PAGI::Routing qw(route middleware router);

sub response_header {
    my ($events, $name) = @_;
    my ($start) = grep { ($_->{type} // '') eq 'http.response.start' } @$events;
    for my $pair (@{$start->{headers} // []}) {
        return $pair->[1] if lc($pair->[0]) eq lc($name);
    }
    return;
}

sub response_bodies {
    my ($events) = @_;
    return [grep { ($_->{type} // '') eq 'http.response.body' } @$events];
}

sub deriving_body_length {
    return sub {
        my ($inner) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            my @events;
            my $buffering_send = sub {
                push @events, $_[0];
                return Future->done;
            };
            await Future->wrap($inner->($scope, $receive, $buffering_send));

            my $length = 0;
            for my $event (@events) {
                next unless ($event->{type} // '') eq 'http.response.body';
                $length += bytes::length($event->{body})
                    if defined $event->{body};
                $length += $event->{length}
                    if exists $event->{file} && defined $event->{length};
            }
            for my $event (@events) {
                if (($event->{type} // '') eq 'http.response.start') {
                    $event = {
                        %$event,
                        headers => [
                            @{$event->{headers} || []},
                            ['X-Body-Length' => $length],
                        ],
                    };
                }
                await Future->wrap($send->($event));
            }
            return;
        };
    };
}

subtest 'application middleware derives HEAD headers from the full body' => sub {
    my @observed_bodies;
    my $observer = sub {
        my ($inner) = @_;
        return async sub {
            my ($request_scope, $receive, $send) = @_;
            my $observing_send = sub {
                my ($event) = @_;
                push @observed_bodies, $event->{body}
                    if ($event->{type} // '') eq 'http.response.body';
                return $send->($event);
            };
            await Future->wrap(
                $inner->($request_scope, $receive, $observing_send),
            );
            return;
        };
    };
    my $raw = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'representation', more => 0 });
    };
    my $app = compose(
        app => $raw,
        middleware => [$observer, middleware('ContentLength')],
    )->to_app;
    my $get = run_scope($app, scope(method => 'GET'));
    @observed_bodies = ();
    my $head = run_scope($app, scope(method => 'HEAD'));
    is(response_header($get, 'Content-Length'), 14, 'GET length is calculated');
    is(response_header($head, 'Content-Length'), 14, 'HEAD retains GET-equivalent length');
    is(response_bodies($head), [
        { type => 'http.response.body', body => '', more => 0 },
    ], 'wire receives one empty terminal body');
    is(\@observed_bodies, ['representation'],
        'author middleware sees unsuppressed HEAD representation bytes');
};

subtest 'Router middleware derives identical GET and HEAD representation metadata' => sub {
    my $routing = router(
        routes => [
            route('/representation', raw => async sub {
                my ($scope, $receive, $send) = @_;
                await $send->({
                    type => 'http.response.start', status => 200, headers => [],
                });
                await $send->({
                    type => 'http.response.body', body => 'representation', more => 0,
                });
            }),
        ],
        middleware => [deriving_body_length()],
    );
    my $app = compose(app => $routing)->to_app;
    my $get = run_scope($app, scope(method => 'GET', path => '/representation'));
    my $head = run_scope($app, scope(method => 'HEAD', path => '/representation'));
    is(response_header($get, 'X-Body-Length'), 14,
        'Router middleware derives the GET representation length');
    is(response_header($head, 'X-Body-Length'), 14,
        'HEAD retains the same Router-derived representation length');
    is(response_bodies($head), [
        { type => 'http.response.body', body => '', more => 0 },
    ], 'HEAD emits one empty terminal wire body');
};

subtest 'Router outcomes and root errors retain derived headers under HEAD' => sub {
    local $ENV{PAGI_ENV} = 'production';
    my @cases = (
        [
            'Router 404',
            compose(routes => [
                route('/known' => sub {
                    return PAGI::Response::Text->new('known');
                }),
            ])->to_app,
            scope(method => 'GET', path => '/missing'),
            scope(method => 'HEAD', path => '/missing'),
        ],
        [
            'Router 405',
            compose(routes => [
                route('/known' => sub {
                    return PAGI::Response::Text->new('known');
                }, methods => 'POST'),
            ])->to_app,
            scope(method => 'GET', path => '/known'),
            scope(method => 'HEAD', path => '/known'),
        ],
        [
            'root ErrorHandler',
            compose(app => sub { die "HEAD error\n" })->to_app,
            scope(method => 'GET'),
            scope(method => 'HEAD'),
        ],
    );

    for my $case (@cases) {
        my ($label, $app, $get_scope, $head_scope) = @$case;
        my ($get, $head);
        {
            local $SIG{__WARN__} = sub { return };
            $get = run_scope($app, $get_scope);
            $head = run_scope($app, $head_scope);
        }
        my $get_length = response_header($get, 'Content-Length');
        like($get_length, qr/\A(?:0|[1-9][0-9]*)\z/,
            "$label GET carries a valid representation length");
        is(response_header($head, 'Content-Length'), $get_length,
            "$label HEAD retains the equivalent GET representation length");
        is(response_bodies($head), [
            { type => 'http.response.body', body => '', more => 0 },
        ], "$label HEAD emits one empty terminal wire body");
    }
};

subtest 'sendfile length is available before HEAD wire suppression' => sub {
    my $routing = router(
        routes => [
            route('/file', raw => async sub {
                my ($scope, $receive, $send) = @_;
                await $send->({
                    type => 'http.response.start', status => 200, headers => [],
                });
                await $send->({
                    type => 'http.response.body', file => '/tmp/example',
                    offset => 4, length => 37,
                });
            }),
        ],
        middleware => [deriving_body_length()],
    );
    my $app = compose(app => $routing)->to_app;
    my $get = run_scope($app, scope(method => 'GET', path => '/file'));
    my $head = run_scope($app, scope(method => 'HEAD', path => '/file'));
    is(response_header($get, 'X-Body-Length'), 37,
        'GET middleware derives length from sendfile metadata');
    is(response_header($head, 'X-Body-Length'), 37,
        'HEAD retains sendfile-derived metadata');
    is(response_bodies($get), [{
        type => 'http.response.body', file => '/tmp/example',
        offset => 4, length => 37,
    }], 'GET keeps the sendfile terminal body');
    is(response_bodies($head), [
        { type => 'http.response.body', body => '', more => 0 },
    ], 'HEAD replaces sendfile with one empty terminal wire body');
};

subtest 'an explicit HEAD route can avoid its expensive GET sibling' => sub {
    my @called;
    my $app = compose(routes => [
        route('/resource' => sub {
            push @called, ['head', $_[0]->method];
            return PAGI::Response::Empty->new(
                headers => ['x-source' => 'head'],
            );
        }, methods => 'HEAD'),
        route('/resource' => sub {
            push @called, ['get', $_[0]->method];
            return PAGI::Response::Text->new('expensive representation');
        }, methods => 'GET'),
    ])->to_app;
    my $events = run_scope($app, scope(method => 'HEAD', path => '/resource'));
    is(\@called, [['head', 'HEAD']], 'declaration-ordered explicit HEAD runs alone');
    is(response_header($events, 'x-source'), 'head', 'custom HEAD metadata survives');
    is(response_bodies($events), [
        { type => 'http.response.body', body => '', more => 0 },
    ], 'outer boundary remains terminal');
};

subtest 'Compose HEAD boundary is idempotent with a Router direct boundary' => sub {
    my $child = router(
        routes => [
            route('/item', raw => async sub {
                my ($scope, $receive, $send) = @_;
                await $send->({ type => 'http.response.start', status => 200, headers => [] });
                await $send->({
                    type => 'http.response.body', body => 'child representation', more => 0,
                });
            }),
        ],
        middleware => [middleware('ContentLength')],
    );
    my $app = compose(
        app => $child,
        middleware => [middleware('ContentLength')],
    )->to_app;
    my $events = run_scope($app, scope(method => 'HEAD', path => '/item'));
    is(response_header($events, 'Content-Length'), 20,
        'both middleware layers see the complete child representation');
    is(response_bodies($events), [
        { type => 'http.response.body', body => '', more => 0 },
    ], 'nested Router boundary recognizes the existing Compose owner');
};

subtest 'byte stream file terminal trailers and late bodies are suppressed' => sub {
    my $start = {
        type => 'http.response.start', status => 206,
        headers => [['content-length', 37]],
    };
    my $app = compose(app => async sub {
        my ($scope, $receive, $send) = @_;
        await $send->($start);
        await $send->({ type => 'http.response.body', body => 'one', more => 1 });
        await $send->({
            type => 'http.response.body', file => 'must-not-reach-transport',
            offset => 4, length => 37,
        });
        await $send->({
            type => 'http.response.trailers', headers => [['x-end', 'drop']],
        });
        await $send->({ type => 'http.response.body', body => 'late', more => 0 });
    })->to_app;
    my $events = run_scope($app, scope(method => 'HEAD'));
    is($events, [
        $start,
        { type => 'http.response.body', body => '', more => 0 },
    ], 'transport receives metadata and one empty terminal event only');
    is(refaddr($events->[0]), refaddr($start), 'response start passes by identity');
    ok(!(grep { exists $_->{file} } @$events), 'transport never observes a file key');
};

subtest 'absent more is a terminal body event' => sub {
    my $app = compose(app => async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'terminal' });
    })->to_app;
    my $events = run_scope($app, scope(method => 'HEAD'));
    is(response_bodies($events), [
        { type => 'http.response.body', body => '', more => 0 },
    ], 'missing more is replaced as terminal');
};

subtest 'explicit PAGI::Middleware::Head still rewrites method to GET' => sub {
    my @methods;
    my $app = compose(
        app => sub {
            my ($scope, $receive, $send) = @_;
            push @methods, $scope->{method};
            $send->({ type => 'http.response.start', status => 200, headers => [] })->get;
            return $send->({ type => 'http.response.body', body => 'legacy' });
        },
        middleware => [middleware('Head')],
    )->to_app;
    my $events = run_scope($app, scope(method => 'HEAD'));
    is(\@methods, ['GET'], 'legacy middleware keeps its documented rewrite');
    is(response_bodies($events), [
        { type => 'http.response.body', body => '', more => 0 },
    ], 'Compose outer boundary still protects the wire');
};

subtest 'HEAD terminal state is request-local under interleaving' => sub {
    my (%send_for, %done_for);
    my $composition = compose(app => sub {
        my ($scope, $receive, $send) = @_;
        my $id = $scope->{path};
        $send_for{$id} = $send;
        $done_for{$id} = Future->new;
        return $done_for{$id};
    });
    my $app = $composition->to_app;
    my ($transport_one, $events_one) = capture_send();
    my ($transport_two, $events_two) = capture_send();
    my $one = $app->(scope(method => 'HEAD', path => '/one'), sub { Future->done }, $transport_one);
    my $two = $app->(scope(method => 'HEAD', path => '/two'), sub { Future->done }, $transport_two);

    $send_for{'/one'}->({
        type => 'http.response.start', status => 200, headers => [],
    })->get;
    $send_for{'/two'}->({
        type => 'http.response.start', status => 200, headers => [],
    })->get;
    $send_for{'/one'}->({ type => 'http.response.body', body => 'one' })->get;
    $send_for{'/two'}->({ type => 'http.response.body', body => 'two' })->get;
    is($events_one, [
        { type => 'http.response.start', status => 200, headers => [] },
        { type => 'http.response.body', body => '', more => 0 },
    ], 'first request terminates');
    is($events_two, [
        { type => 'http.response.start', status => 200, headers => [] },
        { type => 'http.response.body', body => '', more => 0 },
    ], 'second request has independent terminal state');
    $done_for{'/one'}->done;
    $done_for{'/two'}->done;
    $one->get;
    $two->get;
};

subtest 'separate compiled apps own independent HEAD boundaries' => sub {
    my $composition = compose(app => sub {
        my ($scope, $receive, $send) = @_;
        $send->({ type => 'http.response.start', status => 200, headers => [] })->get;
        return $send->({ type => 'http.response.body', body => 'representation' });
    });
    my $first = run_scope($composition->to_app, scope(method => 'HEAD'));
    my $second = run_scope($composition->to_app, scope(method => 'HEAD'));
    is(response_bodies($first), [
        { type => 'http.response.body', body => '', more => 0 },
    ], 'first compiled app owns one terminal event');
    is(response_bodies($second), [
        { type => 'http.response.body', body => '', more => 0 },
    ], 'second compiled app owns an independent terminal event');
};

done_testing;
