#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);

use PAGI::Routing qw(router route mount middleware);

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
            my ($context) = @_;
            push @seen_methods, $context->request->method;
            return $context->response
                ->status(203)
                ->text('representation');
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
    my @cases = (
        [
            'explicit HEAD before GET wins',
            [
                route('/choice' => sub {
                    push @invoked, ['explicit', $_[0]->request->method];
                    return $_[0]->text('explicit');
                }, methods => 'HEAD'),
                route('/choice' => sub {
                    push @invoked, ['automatic', $_[0]->request->method];
                    return $_[0]->text('automatic');
                }, methods => 'GET'),
            ],
            'explicit',
        ],
        [
            'GET before explicit HEAD wins through automatic HEAD',
            [
                route('/choice' => sub {
                    push @invoked, ['automatic', $_[0]->request->method];
                    return $_[0]->text('automatic');
                }, methods => 'GET'),
                route('/choice' => sub {
                    push @invoked, ['explicit', $_[0]->request->method];
                    return $_[0]->text('explicit');
                }, methods => 'HEAD'),
            ],
            'automatic',
        ],
        [
            'a rejected explicit HEAD constraint falls through to automatic HEAD',
            [
                route('/choice/{id}' => sub {
                    push @invoked, ['must-not-run', $_[0]->request->method];
                    return $_[0]->text('must-not-run');
                },
                    methods => 'HEAD', constraints => { id => sub { return 0 } }),
                route('/choice/{id}' => sub {
                    push @invoked, ['fallback', $_[0]->request->method];
                    return $_[0]->text('fallback');
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
        routes => [route('/buffered', raw => $raw)],
        middleware => [middleware('ContentLength')],
    )->to_app;

    my $get = run_app($app, method => 'GET', path => '/buffered');
    my $head = run_app($app, method => 'HEAD', path => '/buffered');

    is(response_header($get, 'Content-Length'), 18, 'router middleware calculates the GET representation length');
    is(response_header($head, 'Content-Length'), 18, 'router middleware calculates the same HEAD representation length');
    is(response_bodies($get), [{ type => 'http.response.body', body => 'middleware-visible' }],
        'GET retains the raw representation');
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
                    routes => [mount('/api' => $child)],
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
                    mount('/api' => $child,
                        middleware => [middleware('ContentLength')]),
                ])->to_app;
            },
            '/api/item',
            '/item',
        ],
        [
            'raw route middleware',
            sub {
                my ($child) = @_;
                return router(routes => [
                    route('/item', raw => $child,
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
            route($child_path, raw => async sub {
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
            }),
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
        route('/stream', raw => async sub {
            my ($scope, $receive, $send) = @_;
            await $send->($start);
            await $send->({ type => 'http.response.body', body => 'one', more => 1 });
            await $send->({ type => 'http.response.body', body => 'two', more => 1 });
            await $send->({ type => 'http.response.body', body => 'three', more => 0 });
            await $send->({ type => 'http.response.trailers', headers => [['x-sum' => 'six']] });
            await $send->({ type => 'http.response.body', body => 'late', more => 0 });
        }),
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
        route('/stream', raw => async sub {
            my ($scope, $receive, $send) = @_;
            await $send->($start);
            await $send->({ type => 'http.response.body', body => 'one', more => 1 });
            await $send->({ type => 'http.response.body', body => 'terminal' });
            await $send->({ type => 'http.response.trailers', headers => [['x-sum' => 'done']] });
        }),
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
        route('/file', raw => async sub {
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
        }),
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

subtest 'generated HEAD outcomes preserve metadata and suppress their bodies' => sub {
    my $app = router(routes => [
        route('/get' => sub { return $_[0]->text('get') }, methods => 'GET'),
        route('/post' => sub { return $_[0]->text('post') }, methods => 'POST'),
    ])->to_app;

    my $not_found = run_app($app, method => 'HEAD', path => '/missing');
    is(response_start($not_found)->{status}, 404, 'HEAD preserves a generated 404 status');
    is(response_header($not_found, 'Content-Type'), 'text/plain; charset=utf-8', 'HEAD preserves generated 404 type');
    is(response_header($not_found, 'Content-Length'), 9, 'HEAD preserves generated 404 length');
    is(response_bodies($not_found), [{ type => 'http.response.body', body => '', more => 0 }],
        'HEAD suppresses the generated 404 body');

    my $not_allowed = run_app($app, method => 'HEAD', path => '/post');
    is(response_start($not_allowed)->{status}, 405, 'HEAD preserves a generated 405 status');
    is(response_header($not_allowed, 'Allow'), 'POST', 'HEAD preserves the generated Allow header');
    is(response_header($not_allowed, 'Content-Type'), 'text/plain; charset=utf-8', 'HEAD preserves generated 405 type');
    is(response_header($not_allowed, 'Content-Length'), 18, 'HEAD preserves generated 405 length');
    is(response_bodies($not_allowed), [{ type => 'http.response.body', body => '', more => 0 }],
        'HEAD suppresses the generated 405 body');
};

subtest 'GET events remain byte-for-byte unchanged' => sub {
    my $app = router(routes => [
        route('/unchanged', raw => async sub {
            my ($scope, $receive, $send) = @_;
            await $send->({
                type    => 'http.response.start',
                status  => 207,
                headers => [['x-raw' => 'kept']],
            });
            await $send->({ type => 'http.response.body', body => 'unchanged', more => 1 });
            await $send->({ type => 'http.response.body', body => '!', more => 0 });
            await $send->({ type => 'http.response.trailers', headers => [['x-end' => 'kept']] });
        }),
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
        route('/diagnostic', raw => async sub {
            my ($scope, $receive, $send) = @_;
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->($diagnostic);
            await $send->({ type => 'http.response.body', body => 'hidden' });
        }),
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
        mount('/buffered' => async sub {
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
            route('/events', raw => async sub {
                my ($scope, $receive, $send) = @_;
                await $send->({
                    type    => 'http.response.start',
                    status  => 200,
                    headers => [['x-mounted' => 'stream']],
                });
                await $send->({ type => 'http.response.body', body => 'one', more => 1 });
                await $send->({ type => 'http.response.body', body => 'two', more => 0 });
                await $send->({ type => 'http.response.trailers', headers => [] });
            }),
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
        mount('/files' => async sub {
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
