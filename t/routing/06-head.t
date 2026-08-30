#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);

use PAGI::Response;
use PAGI::Response::Text ();
use PAGI::Response::Stream ();
use PAGI::Routing qw(router route mount middleware);
use PAGI::Utils qw(as_app);

sub scope {
    my (%changes) = @_;
    return {
        type    => 'http',
        method  => 'GET',
        path    => '/',
        headers => [],
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
    my ($app, %scope_changes) = @_;
    my @events;
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };

    $app->(scope(%scope_changes), \&receive, $send)->get;
    return \@events;
}

sub response_start {
    my ($events) = @_;
    return (grep { ($_->{type} // '') eq 'http.response.start' } @$events)[0];
}

sub response_status {
    my ($events) = @_;
    my $start = response_start($events);
    return defined($start) ? $start->{status} : undef;
}

sub response_header {
    my ($events, $name) = @_;
    my $start = response_start($events);
    return unless $start;
    for my $pair (@{$start->{headers} // []}) {
        return $pair->[1] if lc($pair->[0]) eq lc($name);
    }
    return;
}

sub response_bodies {
    my ($events) = @_;
    return [grep { ($_->{type} // '') eq 'http.response.body' } @$events];
}

subtest 'automatic HEAD keeps request metadata and GET-equivalent response metadata' => sub {
    my @seen_methods;
    my $app = router(routes => [
        route('/representation' => sub {
            my ($request) = @_;
            push @seen_methods, $request->method;
            return PAGI::Response::Text->new('representation', status => 203);
        }),
    ])->to_app;

    my $get = run_app($app, method => 'GET', path => '/representation');
    my $head = run_app($app, method => 'HEAD', path => '/representation');

    is(\@seen_methods, [qw(GET HEAD)], 'the shared handler sees the original request method');
    is(response_start($get)->{status}, 203, 'GET receives the handler status');
    is(response_start($head)->{status}, 203, 'HEAD preserves the handler status');
    is(response_header($get, 'Content-Type'), 'text/plain; charset=utf-8', 'GET receives the representation type');
    is(response_header($head, 'Content-Type'), 'text/plain; charset=utf-8', 'HEAD preserves the representation type');
    is(response_header($get, 'Content-Length'), 14, 'GET reports the representation length');
    is(response_header($head, 'Content-Length'), 14, 'HEAD preserves the representation length');
    is(response_bodies($get), [{ type => 'http.response.body', body => 'representation', more => 0 }],
        'GET emits the representation body');
    is(response_bodies($head), [{ type => 'http.response.body', body => '', more => 0 }],
        'HEAD emits one empty terminal body');
};

subtest 'HEAD selection retains declaration order and constraint fallthrough' => sub {
    my @invoked;
    my $expensive_get_calls = 0;
    my @cases = (
        [
            'explicit HEAD before GET wins',
            [
                route('/choice' => sub {
                    push @invoked, ['explicit', $_[0]->method];
                    return PAGI::Response::Text->new('explicit');
                }, methods => 'HEAD'),
                route('/choice' => sub {
                    ++$expensive_get_calls;
                    push @invoked, ['automatic', $_[0]->method];
                    return PAGI::Response::Text->new('automatic');
                }, methods => 'GET'),
            ],
            'explicit',
        ],
        [
            'GET before explicit HEAD wins through automatic HEAD',
            [
                route('/choice' => sub {
                    push @invoked, ['automatic', $_[0]->method];
                    return PAGI::Response::Text->new('automatic');
                }, methods => 'GET'),
                route('/choice' => sub {
                    push @invoked, ['explicit', $_[0]->method];
                    return PAGI::Response::Text->new('explicit');
                }, methods => 'HEAD'),
            ],
            'automatic',
        ],
        [
            'a rejected explicit HEAD constraint falls through to automatic HEAD',
            [
                route('/choice/{id}' => sub {
                    push @invoked, ['must-not-run', $_[0]->method];
                    return PAGI::Response::Text->new('must-not-run');
                },
                    methods => 'HEAD', constraints => { id => sub { return 0 } }),
                route('/choice/{id}' => sub {
                    push @invoked, ['fallback', $_[0]->method];
                    return PAGI::Response::Text->new('fallback');
                }, methods => 'GET'),
            ],
            'fallback',
            '/choice/42',
        ],
    );

    for my $case (@cases) {
        my ($label, $routes, $selected, $path) = @$case;
        @invoked = ();
        my $app = router(routes => $routes)->to_app;
        my $events = run_app($app, method => 'HEAD', path => ($path // '/choice'));

        is(\@invoked, [[$selected, 'HEAD']], $label);
        is(response_header($events, 'Content-Length'), length($selected),
            "$label preserves the selected representation length");
        is(response_bodies($events), [{ type => 'http.response.body', body => '', more => 0 }],
            "$label still receives HEAD wire suppression");
    }
    is($expensive_get_calls, 0,
        'an explicit HEAD route before GET avoids the expensive GET handler');
};

subtest 'Stream HEAD runs the GET producer while an earlier explicit HEAD avoids it' => sub {
    my $producer_calls = 0;
    my $stream = PAGI::Response::Stream->new(async sub {
        my ($writer) = @_;
        ++$producer_calls;
        await $writer->write('one');
        await $writer->write('two');
    }, headers => ['X-Stream' => 'yes']);
    my $automatic = router(routes => [
        route('/stream' => $stream, methods => 'GET'),
    ])->to_app;

    my $get = run_app($automatic, method => 'GET', path => '/stream');
    my $head = run_app($automatic, method => 'HEAD', path => '/stream');
    is($producer_calls, 2,
        'ordinary GET and automatic HEAD each invoke and await the Stream producer');
    is(response_bodies($get), [
        { type => 'http.response.body', body => 'one', more => 1 },
        { type => 'http.response.body', body => 'two', more => 1 },
        { type => 'http.response.body', body => '', more => 0 },
    ], 'GET receives the complete streamed representation');
    is(response_bodies($head), [
        { type => 'http.response.body', body => '', more => 0 },
    ], 'HeadBoundary suppresses every Stream byte but retains terminal completion');
    is(response_header($head, 'X-Stream'), response_header($get, 'X-Stream'),
        'Stream HEAD retains GET-equivalent response metadata');

    my $explicit = router(routes => [
        route('/stream' => PAGI::Response::Text->new('lightweight'), methods => 'HEAD'),
        route('/stream' => $stream, methods => 'GET'),
    ])->to_app;
    my $before = $producer_calls;
    my $explicit_head = run_app($explicit, method => 'HEAD', path => '/stream');
    is($producer_calls, $before,
        'an earlier explicit HEAD route avoids the expensive GET Stream producer');
    is(response_header($explicit_head, 'Content-Length'), 11,
        'explicit HEAD uses its lightweight representation metadata');
    is(response_bodies($explicit_head), [
        { type => 'http.response.body', body => '', more => 0 },
    ], 'explicit HEAD remains suppressed at the outer boundary');
};

subtest 'automatic HEAD stays pending for a controlled Stream producer' => sub {
    my $producer_wait = Future->new;
    my $producer_calls = 0;
    my $app = router(routes => [
        route('/slow-stream' => PAGI::Response::Stream->new(sub {
            ++$producer_calls;
            return $producer_wait;
        }), methods => 'GET'),
    ])->to_app;
    my @events;

    my $running = $app->(
        scope(method => 'HEAD', path => '/slow-stream'),
        \&receive,
        sub { push @events, $_[0]; Future->done },
    );

    is($producer_calls, 1, 'automatic HEAD invokes the selected Stream producer');
    ok(!$running->is_ready,
        'automatic HEAD remains pending while the Stream producer is pending');
    is(response_bodies(\@events), [],
        'HEAD emits no terminal event before producer completion');

    $producer_wait->done('producer complete');
    $running->get;
    is(response_bodies(\@events), [
        { type => 'http.response.body', body => '', more => 0 },
    ], 'HEAD emits one suppressed terminal body after producer completion');
};

subtest 'the outer HEAD boundary lets router middleware observe the full representation' => sub {
    my $raw = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type' => 'text/plain']],
        });
        await $send->({
            type => 'http.response.body',
            body => 'middleware-visible',
        });
    };
    my $app = router(
        routes => [route('/buffered' => as_app($raw))],
        middleware => [middleware('ContentLength')],
    )->to_app;

    my $get = run_app($app, method => 'GET', path => '/buffered');
    my $head = run_app($app, method => 'HEAD', path => '/buffered');

    is(response_header($get, 'Content-Length'), 18, 'router middleware calculates the GET representation length');
    is(response_header($head, 'Content-Length'), 18, 'router middleware calculates the same HEAD representation length');
    is(response_bodies($get), [{ type => 'http.response.body', body => 'middleware-visible' }],
        'GET retains the native representation');
    is(response_bodies($head), [{ type => 'http.response.body', body => '', more => 0 }],
        'suppression happens only after router middleware finishes');
};

subtest 'one outer HEAD owner covers separately compiled child routers' => sub {
    my @cases = (
        [
            'parent router middleware',
            sub {
                my ($child) = @_;
                return router(
                    routes => [mount('/api', app => $child)],
                    middleware => [middleware('ContentLength')],
                )->to_app;
            },
            '/api/item',
            '/item',
        ],
        [
            'application mount middleware',
            sub {
                my ($child) = @_;
                return router(routes => [
                    mount('/api', app => $child,
                        middleware => [middleware('ContentLength')]),
                ])->to_app;
            },
            '/api/item',
            '/item',
        ],
        [
            'Route middleware',
            sub {
                my ($child) = @_;
                return router(routes => [
                    route('/item' => $child,
                        middleware => [middleware('ContentLength')]),
                ])->to_app;
            },
            '/item',
            '/item',
        ],
    );

    for my $case (@cases) {
        my ($label, $build_parent, $request_path, $child_path) = @$case;
        my $child = router(routes => [
            route($child_path => as_app(async sub {
                my ($scope, $receive, $send) = @_;
                await $send->({
                    type    => 'http.response.start',
                    status  => 200,
                    headers => [['content-type' => 'text/plain']],
                });
                await $send->({
                    type => 'http.response.body',
                    body => 'child representation',
                    more => 0,
                });
            })),
        ]);
        my $app = $build_parent->($child);

        my $get = run_app($app, method => 'GET', path => $request_path);
        my $head = run_app($app, method => 'HEAD', path => $request_path);

        is(response_header($get, 'Content-Length'), 20,
            "$label derives GET metadata from the full child body");
        is(response_header($head, 'Content-Length'), 20,
            "$label derives identical HEAD metadata before outer suppression");
        is(response_bodies($head), [
            { type => 'http.response.body', body => '', more => 0 },
        ], "$label still emits only the outer empty HEAD body");
    }
};

subtest 'HEAD streaming suppression waits for an explicit terminal body' => sub {
    my $start = {
        type    => 'http.response.start',
        status  => 200,
        headers => [['x-stream' => 'explicit']],
    };
    my $app = router(routes => [
        route('/stream' => as_app(async sub {
            my ($scope, $receive, $send) = @_;
            await $send->($start);
            await $send->({ type => 'http.response.body', body => 'one', more => 1 });
            await $send->({ type => 'http.response.body', body => 'two', more => 1 });
            await $send->({ type => 'http.response.body', body => 'three', more => 0 });
            await $send->({ type => 'http.response.trailers', headers => [['x-sum' => 'six']] });
            await $send->({ type => 'http.response.body', body => 'late', more => 0 });
        })),
    ])->to_app;

    my $events = run_app($app, method => 'HEAD', path => '/stream');

    is($events, [
        $start,
        { type => 'http.response.body', body => '', more => 0 },
    ], 'nonterminal bodies, trailers, and bodies after the first terminal event are dropped');
    is(refaddr($events->[0]), refaddr($start), 'the start event is forwarded by identity');
};

subtest 'HEAD streaming suppression treats absent more as terminal' => sub {
    my $start = {
        type    => 'http.response.start',
        status  => 206,
        headers => [['x-stream' => 'implicit']],
    };
    my $app = router(routes => [
        route('/stream' => as_app(async sub {
            my ($scope, $receive, $send) = @_;
            await $send->($start);
            await $send->({ type => 'http.response.body', body => 'one', more => 1 });
            await $send->({ type => 'http.response.body', body => 'terminal' });
            await $send->({ type => 'http.response.trailers', headers => [['x-sum' => 'done']] });
        })),
    ])->to_app;

    my $events = run_app($app, method => 'HEAD', path => '/stream');

    is($events, [
        $start,
        { type => 'http.response.body', body => '', more => 0 },
    ], 'an absent more flag produces the one replacement terminal body');
};

subtest 'HEAD suppression consumes terminal sendfile descriptors before transport' => sub {
    my $missing = 't/routing/this-file-must-not-exist';
    my $file_open_attempts = 0;
    my @events;
    my $app = router(routes => [
        route('/file' => as_app(async sub {
            my ($scope, $receive, $send) = @_;
            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [['content-length' => 37]],
            });
            await $send->({
                type   => 'http.response.body',
                file   => $missing,
                offset => 4,
                length => 37,
            });
        })),
    ])->to_app;
    my $transport = sub {
        my ($event) = @_;
        if (exists $event->{file}) {
            ++$file_open_attempts;
            open my $fh, '<', $event->{file}
                or die "transport could not open leaked file descriptor: $!";
            close $fh;
        }
        push @events, $event;
        return Future->done;
    };

    my $error = dies {
        $app->(scope(method => 'HEAD', path => '/file'), \&receive, $transport)->get;
    };

    is($error, undef, 'the nonexistent file never reaches transport file handling');
    is($file_open_attempts, 0, 'transport makes no file-open attempt');
    is(\@events, [
        {
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-length' => 37]],
        },
        { type => 'http.response.body', body => '', more => 0 },
    ], 'no file, offset, or length keys reach the wire');
};

subtest 'Router-generated HEAD outcomes preserve GET-equivalent metadata and suppress payloads' => sub {
    my $app = router(
        middleware => [middleware('ContentLength')],
        routes => [
            route('/post' => sub { return PAGI::Response::Text->new('post') }, methods => 'POST'),
        ],
    )->to_app;

    my $not_found_get = run_app($app, method => 'GET', path => '/missing');
    my $not_found = run_app($app, method => 'HEAD', path => '/missing');
    is(response_status($not_found), 404, 'HEAD preserves generated 404 status');
    is(response_header($not_found, 'Content-Type'),
        response_header($not_found_get, 'Content-Type'),
        'HEAD preserves the GET 404 representation type');
    is(response_header($not_found, 'Content-Length'),
        response_header($not_found_get, 'Content-Length'),
        'Router middleware calculates the same generated 404 length before suppression');
    my $not_found_get_bodies = response_bodies($not_found_get);
    ok(@$not_found_get_bodies
            && length($not_found_get_bodies->[0]{body} // '') > 0,
        'the GET 404 retains its negotiated representation');
    is(response_bodies($not_found), [{ type => 'http.response.body', body => '', more => 0 }],
        'the one outer HEAD boundary suppresses the generated 404 body');

    my $not_allowed_get = run_app($app, method => 'GET', path => '/post');
    my $not_allowed = run_app($app, method => 'HEAD', path => '/post');
    is(response_status($not_allowed), 405, 'HEAD preserves generated 405 status');
    is(response_header($not_allowed, 'Allow'), 'POST',
        'HEAD preserves generated authoritative Allow');
    is(response_header($not_allowed, 'Content-Type'),
        response_header($not_allowed_get, 'Content-Type'),
        'HEAD preserves the GET 405 representation type');
    is(response_header($not_allowed, 'Content-Length'),
        response_header($not_allowed_get, 'Content-Length'),
        'Router middleware calculates the same generated 405 length before suppression');
    is(response_bodies($not_allowed), [{ type => 'http.response.body', body => '', more => 0 }],
        'the one outer HEAD boundary suppresses the generated 405 body');

    my $file_app = router(
        http_default => async sub {
            my ($scope, $receive, $send) = @_;
            await Future->wrap($send->({
                type => 'http.response.start', status => 404,
                headers => [['content-length' => -s __FILE__]],
                trailers => 1,
            }));
            await Future->wrap($send->({
                type => 'http.response.body', file => __FILE__,
                offset => 0, length => -s __FILE__,
            }));
            await Future->wrap($send->({
                type => 'http.response.trailers',
                headers => [['x-fallback', 'complete']],
            }));
        },
        routes => [],
    )->to_app;
    my $file = run_app($file_app, method => 'HEAD', path => '/missing');
    is(response_status($file), 404,
        'sendfile HTTP default retains its 404 status');
    is(response_header($file, 'Content-Length'), -s __FILE__,
        'sendfile HTTP default retains its calculated file length');
    is(response_bodies($file), [
        { type => 'http.response.body', body => '', more => 0 },
    ], 'default sendfile and trailers are suppressed at the outer edge');
};

subtest 'GET events remain byte-for-byte unchanged' => sub {
    my $app = router(routes => [
        route('/unchanged' => as_app(async sub {
            my ($scope, $receive, $send) = @_;
            await $send->({
                type    => 'http.response.start',
                status  => 207,
                headers => [['x-raw' => 'kept']],
            });
            await $send->({ type => 'http.response.body', body => 'unchanged', more => 1 });
            await $send->({ type => 'http.response.body', body => '!', more => 0 });
            await $send->({ type => 'http.response.trailers', headers => [['x-end' => 'kept']] });
        })),
    ])->to_app;

    my $events = run_app($app, method => 'GET', path => '/unchanged');

    is($events, [
        {
            type    => 'http.response.start',
            status  => 207,
            headers => [['x-raw' => 'kept']],
        },
        { type => 'http.response.body', body => 'unchanged', more => 1 },
        { type => 'http.response.body', body => '!', more => 0 },
        { type => 'http.response.trailers', headers => [['x-end' => 'kept']] },
    ], 'non-HEAD responses pass through without event rewriting');
};

subtest 'HEAD forwards unrelated response events unchanged' => sub {
    my $diagnostic = { type => 'http.response.diagnostic', detail => 'malformed app evidence' };
    my $app = router(routes => [
        route('/diagnostic' => as_app(async sub {
            my ($scope, $receive, $send) = @_;
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->($diagnostic);
            await $send->({ type => 'http.response.body', body => 'hidden' });
        })),
    ])->to_app;

    my $events = run_app($app, method => 'HEAD', path => '/diagnostic');

    is($events, [
        { type => 'http.response.start', status => 200, headers => [] },
        $diagnostic,
        { type => 'http.response.body', body => '', more => 0 },
    ], 'only body and trailer events are special at the HEAD boundary');
    is(refaddr($events->[1]), refaddr($diagnostic), 'the unrelated event is forwarded by identity');
};

subtest 'the outer HEAD boundary covers application and inline mounts' => sub {
    my $buffered = router(routes => [
        mount('/buffered', app => async sub {
            my ($scope, $receive, $send) = @_;
            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [['content-length' => 16]],
            });
            await $send->({
                type => 'http.response.body',
                body => 'mounted buffered',
                more => 0,
            });
        }),
    ])->to_app;
    my $buffered_events = run_app(
        $buffered,
        method => 'HEAD',
        path => '/buffered/resource',
    );
    is(response_header($buffered_events, 'Content-Length'), 16,
        'an application mount retains its buffered representation length');
    is(response_bodies($buffered_events), [
        { type => 'http.response.body', body => '', more => 0 },
    ], 'an application mount buffered body is suppressed');

    my $streamed = router(routes => [
        mount('/stream', routes => [
            route('/events' => as_app(async sub {
                my ($scope, $receive, $send) = @_;
                await $send->({
                    type    => 'http.response.start',
                    status  => 200,
                    headers => [['x-mounted' => 'stream']],
                });
                await $send->({ type => 'http.response.body', body => 'one', more => 1 });
                await $send->({ type => 'http.response.body', body => 'two', more => 0 });
                await $send->({ type => 'http.response.trailers', headers => [] });
            })),
        ]),
    ])->to_app;
    my $streamed_events = run_app(
        $streamed,
        method => 'HEAD',
        path => '/stream/events',
    );
    is($streamed_events, [
        {
            type    => 'http.response.start',
            status  => 200,
            headers => [['x-mounted' => 'stream']],
        },
        { type => 'http.response.body', body => '', more => 0 },
    ], 'an inline mounted stream emits only start and one empty terminal body');

    my $sendfile = router(routes => [
        mount('/files', app => async sub {
            my ($scope, $receive, $send) = @_;
            await $send->({
                type    => 'http.response.start',
                status  => 200,
                headers => [['content-length' => 91]],
            });
            await $send->({
                type   => 'http.response.body',
                file   => 't/routing/mounted-file-must-not-exist',
                offset => 9,
                length => 91,
            });
        }),
    ])->to_app;
    my $sendfile_events = run_app(
        $sendfile,
        method => 'HEAD',
        path => '/files/report',
    );
    is($sendfile_events, [
        {
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-length' => 91]],
        },
        { type => 'http.response.body', body => '', more => 0 },
    ], 'an application-mounted sendfile descriptor is suppressed before transport');
};

done_testing;
