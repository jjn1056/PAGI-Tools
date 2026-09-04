#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);

use PAGI::Response::Text ();
use PAGI::Routing qw(router route websocket sse mount middleware);
use PAGI::Routing::URL qw(path_for);
use PAGI::SSE;
use PAGI::WebSocket;
use PAGI::Utils qw(as_app_object);

sub ProtocolProvider { return qr/accepted/ }

{
    package Local::ProtocolPathCheck;
    sub new { return bless { expected => $_[1] }, $_[0] }
    sub check { return $_[1] eq $_[0]{expected} }
    sub get_message { return "expected $_[0]{expected}, got $_[1]" }
}

{
    package Local::WrongProtocolCache;
    sub new { return bless { scope => $_[1] }, $_[0] }
    sub scope { return $_[0]{scope} }
}

{
    package Local::DyingProtocolCache;
    sub new { return bless {}, $_[0] }
    sub scope { die 'cached protocol scope exploded' }
}

{
    package Local::ProtocolApplication;

    sub new {
        my ($class, @completions) = @_;
        return bless {
            allowed_methods_calls => 0,
            to_app_calls          => 0,
            completions           => \@completions,
            invocations           => [],
        }, $class;
    }

    sub allowed_methods {
        my ($self) = @_;
        ++$self->{allowed_methods_calls};
        return qw(POST);
    }

    sub to_app {
        my ($self) = @_;
        my $generation = ++$self->{to_app_calls};
        return sub {
            push @{$self->{invocations}}, {
                generation => $generation,
                triplet    => [@_],
            };
            return shift @{$self->{completions}}
                if @{$self->{completions}};
            return 'immediate application completion';
        };
    }

    sub allowed_methods_calls { $_[0]{allowed_methods_calls} }
    sub to_app_calls          { $_[0]{to_app_calls} }
    sub invocations           { $_[0]{invocations} }
}

our @NAMED_WEBSOCKET_CALLS;
sub named_websocket_handler {
    push @NAMED_WEBSOCKET_CALLS, [@_];
    return 'immediate handler completion';
}

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

sub run_scope {
    my ($app, $request_scope, %channels) = @_;
    my @events;
    my $receive = $channels{receive} || sub { Future->done({ type => 'unused.receive' }) };
    my $send = $channels{send} || sub {
        push @events, $_[0];
        return Future->done;
    };

    $app->($request_scope, $receive, $send)->get;
    return \@events;
}

subtest 'protocol endpoint shape selects one-argument handlers or native applications' => sub {
    local @NAMED_WEBSOCKET_CALLS;
    my @anonymous_sse_calls;
    my @native_calls;
    my @selected_native_triplets;
    my $anonymous_completion = Future->new;
    my $object_completion = Future->new;
    my $object_endpoint = Local::ProtocolApplication->new(
        $object_completion,
        'immediate application completion',
        'second compilation completion',
    );
    my $capture_native_triplet = middleware(sub {
        my ($inner) = @_;
        return sub {
            push @selected_native_triplets, [@_];
            return $inner->(@_);
        };
    });
    my $routing = router(routes => [
        websocket('/named' => \&named_websocket_handler),
        sse('/anonymous' => sub {
            push @anonymous_sse_calls, [@_];
            return $anonymous_completion;
        }),
        websocket('/adapted' => as_app_object(sub {
            push @native_calls, [@_];
            return 'immediate native completion';
        }), middleware => [$capture_native_triplet]),
        sse('/object' => $object_endpoint,
            middleware => [$capture_native_triplet]),
    ]);

    is($object_endpoint->allowed_methods_calls, 0,
        'protocol declaration ignores the HTTP allowed_methods capability');

    my $app = $routing->to_app;
    is($object_endpoint->to_app_calls, 1,
        'an object endpoint compiles once for one Router compilation');
    is($object_endpoint->allowed_methods_calls, 0,
        'protocol compilation does not consult allowed_methods');

    is(run_scope($app, scope(type => 'websocket', path => '/named')), [],
        'a named handler immediate completion is inert');
    is(scalar @NAMED_WEBSOCKET_CALLS, 1,
        'the named WebSocket handler is invoked once');
    is(scalar @{$NAMED_WEBSOCKET_CALLS[0]}, 1,
        'the named WebSocket handler receives exactly one argument');
    isa_ok($NAMED_WEBSOCKET_CALLS[0][0], ['PAGI::WebSocket'],
        'the named WebSocket handler receives a protocol object');

    my $anonymous_running = $app->(
        scope(type => 'sse', path => '/anonymous'),
        sub { return Future->done({ type => 'sse.disconnect' }) },
        sub { return Future->done },
    );
    ok(!$anonymous_running->is_ready,
        'an anonymous handler Future keeps protocol dispatch pending');
    is(scalar @anonymous_sse_calls, 1,
        'the anonymous SSE handler is invoked once');
    is(scalar @{$anonymous_sse_calls[0]}, 1,
        'the anonymous SSE handler receives exactly one argument');
    isa_ok($anonymous_sse_calls[0][0], ['PAGI::SSE'],
        'the anonymous SSE handler receives a protocol object');
    $anonymous_completion->done('ignored handler value');
    is($anonymous_running->get, undef,
        'a handler Future completion is awaited and remains inert');

    run_scope($app, scope(type => 'websocket', path => '/adapted'));
    is(scalar @native_calls, 1, 'as_app_object invokes the wrapped native CODE once');
    is(scalar @{$native_calls[0]}, 3,
        'as_app_object gives the wrapped CODE the native triplet');
    is(
        [map { refaddr($_) } @{$native_calls[0]}],
        [map { refaddr($_) } @{$selected_native_triplets[0]}],
        'as_app_object receives the exact selected scope, receive, and send values',
    );

    my $object_running = $app->(
        scope(type => 'sse', path => '/object'),
        sub { return Future->done({ type => 'sse.disconnect' }) },
        sub { return Future->done },
    );
    ok(!$object_running->is_ready,
        'an object application Future keeps protocol dispatch pending');
    is($object_endpoint->to_app_calls, 1,
        'invoking the compiled object application does not recompile it');
    is(
        [map { refaddr($_) } @{$object_endpoint->invocations->[0]{triplet}}],
        [map { refaddr($_) } @{$selected_native_triplets[1]}],
        'an object application receives the exact selected native triplet',
    );
    $object_completion->done('ignored application value');
    is($object_running->get, undef,
        'an object application Future is awaited and remains inert');

    run_scope($app, scope(type => 'sse', path => '/object'));
    is($object_endpoint->to_app_calls, 1,
        'repeated invocations reuse the one statically compiled application');
    is(
        [map { $_->{generation} } @{$object_endpoint->invocations}],
        [1, 1],
        'both invocations use the first compiled application generation',
    );

    my $second_app = $routing->to_app;
    is($object_endpoint->to_app_calls, 2,
        'a second Router compilation independently compiles the object once');
    run_scope($second_app, scope(type => 'sse', path => '/object'));
    is(
        [map { $_->{generation} } @{$object_endpoint->invocations}],
        [1, 1, 2],
        'the second Router application uses its independent compilation',
    );
    is($object_endpoint->allowed_methods_calls, 0,
        'protocol lifecycle never consults the HTTP method capability');
};

subtest 'protocol endpoints reject package names and unblessed references' => sub {
    for my $case (
        [websocket => \&websocket, qr/route endpoint must be a WebSocket handler coderef or app object/],
        [sse       => \&sse, qr/route endpoint must be a SSE handler coderef or app object/],
    ) {
        my ($kind, $constructor, $error) = @$case;
        like(
            dies { $constructor->("/$kind-package" => 'Local::ProtocolApplication') },
            $error,
            "$kind rejects a package-name endpoint",
        );
        like(
            dies { $constructor->("/$kind-unblessed" => {}) },
            $error,
            "$kind rejects an unblessed endpoint",
        );
    }
};

subtest 'normal WebSocket and SSE handlers use direct cached protocol objects' => sub {
    my @seen;
    my @selected_channels;
    my @middleware_cached_ids;
    my @middleware_argument_counts;
    my $capture_channels = middleware(sub {
        my ($inner) = @_;
        return sub {
            push @middleware_argument_counts, scalar @_;
            push @selected_channels, [@_];
            my $cached = $_[0]{type} eq 'websocket'
                ? PAGI::WebSocket->new(@_)
                : PAGI::SSE->new(@_);
            push @middleware_cached_ids, refaddr($cached);
            return $inner->(@_);
        };
    });
    my $app = router(routes => [
        mount('/api/{tenant}', routes => [
            websocket('/socket/{room}' => async sub {
                my ($websocket) = @_;
                push @seen, {
                    argument_count => scalar @_,
                    kind        => ref($websocket),
                    object_id   => refaddr($websocket),
                    scope_id    => refaddr($websocket->scope),
                    cached_id   => refaddr(
                        PAGI::WebSocket->new(@{$selected_channels[-1]}),
                    ),
                    path        => $websocket->path,
                    root_path   => $websocket->scope->{root_path},
                    raw_path    => $websocket->raw_path,
                    path_params => $websocket->path_params,
                    frame_root  => $websocket->scope->{'pagi.routing'}{frames}[-1]{root_path},
                    namespace   => $websocket->scope->{'pagi.routing'}{frames}[-1]{logical_namespace},
                    captures    => { %{$websocket->scope->{'pagi.routing'}{frames}[-1]{captures}} },
                    link        => path_for($websocket, 'socket'),
                };
                await $websocket->accept(subprotocol => 'chat');
                await $websocket->send_text('welcome');
                await $websocket->close(1000, 'done');
                return { this => 'is not a wire event' };
            }, name => 'socket', middleware => [$capture_channels]),
            sse('/events/{channel}' => sub {
                my ($sse) = @_;
                push @seen, {
                    argument_count => scalar @_,
                    kind        => ref($sse),
                    object_id   => refaddr($sse),
                    scope_id    => refaddr($sse->scope),
                    cached_id   => refaddr(
                        PAGI::SSE->new(@{$selected_channels[-1]}),
                    ),
                    path        => $sse->path,
                    root_path   => $sse->scope->{root_path},
                    raw_path    => $sse->raw_path,
                    path_params => $sse->path_params,
                    frame_root  => $sse->scope->{'pagi.routing'}{frames}[-1]{root_path},
                    namespace   => $sse->scope->{'pagi.routing'}{frames}[-1]{logical_namespace},
                    captures    => { %{$sse->scope->{'pagi.routing'}{frames}[-1]{captures}} },
                    link        => path_for($sse, 'events'),
                };
                $sse->start(status => 201)->get;
                $sse->send('ready')->get;
                $sse->close->get;
                return 'plain synchronous completion';
            }, name => 'events', middleware => [$capture_channels]),
        ], name => 'tenant'),
    ])->to_app;

    my (@ws_events, @sse_events);
    my $ws_receive = sub { return Future->done({ type => 'websocket.connect' }) };
    my $ws_send = sub { push @ws_events, $_[0]; return Future->done };
    $app->(scope(
        type        => 'websocket',
        path        => '/api/acme/socket/lobby',
        root_path   => '/edge',
        raw_path    => '/edge/api/acme/socket/lobby',
        path_params => { retained => 'yes' },
    ), $ws_receive, $ws_send)->get;
    my $sse_receive = sub { return Future->done({ type => 'sse.disconnect' }) };
    my $sse_send = sub { push @sse_events, $_[0]; return Future->done };
    $app->(scope(
        type        => 'sse',
        path        => '/api/acme/events/news',
        root_path   => '/edge',
        raw_path    => '/edge/api/acme/events/news',
        path_params => { retained => 'yes' },
    ), $sse_receive, $sse_send)->get;

    is([map {
        my $record = $_;
        +{ map { $_ => $record->{$_} } qw(
            argument_count kind path root_path raw_path path_params
            frame_root namespace captures link
        ) }
    } @seen], [
        {
            argument_count => 1,
            kind        => 'PAGI::WebSocket',
            path        => '/socket/lobby',
            root_path   => '/edge/api/acme',
            raw_path    => '/edge/api/acme/socket/lobby',
            path_params => { retained => 'yes', tenant => 'acme', room => 'lobby' },
            frame_root  => '/edge',
            namespace   => '/tenant',
            captures    => { tenant => 'acme', room => 'lobby' },
            link        => '/edge/api/acme/socket/lobby',
        },
        {
            argument_count => 1,
            kind        => 'PAGI::SSE',
            path        => '/events/news',
            root_path   => '/edge/api/acme',
            raw_path    => '/edge/api/acme/events/news',
            path_params => { retained => 'yes', tenant => 'acme', channel => 'news' },
            frame_root  => '/edge',
            namespace   => '/tenant',
            captures    => { tenant => 'acme', channel => 'news' },
            link        => '/edge/api/acme/events/news',
        },
    ], 'mounted handlers receive one direct protocol object after routing metadata is installed');
    is([map { $_->{scope_id} } @seen],
        [map { refaddr($_->[0]) } @selected_channels],
        'protocol objects retain the exact selected scopes seen by middleware');
    is([map { $_->{cached_id} } @seen], [map { $_->{object_id} } @seen],
        'constructing each protocol helper again returns the exact cached object');
    is(\@middleware_cached_ids, [map { $_->{object_id} } @seen],
        'compiler reuses an object cached by route middleware on the exact selected scope');
    is(\@middleware_argument_counts, [3, 3],
        'protocol route middleware remains an exact three-argument native app');
    is(\@ws_events, [
        { type => 'websocket.accept', subprotocol => 'chat' },
        { type => 'websocket.send', text => 'welcome' },
        { type => 'websocket.close', code => 1000, reason => 'done' },
    ], 'Future-backed WebSocket completion adds no wire interpretation');
    is(\@sse_events, [
        { type => 'sse.start', status => 201 },
        { type => 'sse.send', data => 'ready' },
        { type => 'sse.close' },
    ], 'plain SSE completion adds no wire interpretation');
};

subtest 'normal protocol leaves reuse only an exact expected-class cache' => sub {
    for my $protocol (
        [websocket => 'PAGI::WebSocket', 'pagi.websocket'],
        [sse       => 'PAGI::SSE',       'pagi.sse'],
    ) {
        my ($kind, $expected_class, $cache_key) = @$protocol;
        for my $variant (qw(scalar hash parent wrong-class throwing-scope exact)) {
            subtest "$kind $variant cache" => sub {
                my ($seeded, $handled);
                my $seed_cache = middleware(sub {
                    my ($inner) = @_;
                    return sub {
                        my ($selected_scope, $receive, $send) = @_;
                        if ($variant eq 'scalar') {
                            $selected_scope->{$cache_key} = 1;
                        }
                        elsif ($variant eq 'hash') {
                            $selected_scope->{$cache_key} = {};
                        }
                        elsif ($variant eq 'parent') {
                            my $parent_scope = { %$selected_scope };
                            $seeded = $expected_class->new(
                                $parent_scope, $receive, $send,
                            );
                            $selected_scope->{$cache_key} = $seeded;
                        }
                        elsif ($variant eq 'wrong-class') {
                            $seeded = Local::WrongProtocolCache->new(
                                $selected_scope,
                            );
                            $selected_scope->{$cache_key} = $seeded;
                        }
                        elsif ($variant eq 'throwing-scope') {
                            $seeded = Local::DyingProtocolCache->new;
                            $selected_scope->{$cache_key} = $seeded;
                        }
                        else {
                            $seeded = $expected_class->new(
                                $selected_scope, $receive, $send,
                            );
                        }
                        return $inner->(@_);
                    };
                });
                my $handler = sub {
                    ($handled) = @_;
                    return;
                };
                my $leaf = $kind eq 'websocket'
                    ? websocket('/stream' => $handler,
                        middleware => [$seed_cache])
                    : sse('/stream' => $handler,
                        middleware => [$seed_cache]);

                run_scope(
                    $leaf->to_app,
                    scope(type => $kind, path => '/stream'),
                );

                isa_ok($handled, [$expected_class],
                    'handler receives the expected protocol class');
                if ($variant eq 'exact') {
                    is(refaddr($handled), refaddr($seeded),
                        'the exact selected-scope expected-class cache is reused');
                }
                elsif (ref($seeded)) {
                    isnt(refaddr($handled), refaddr($seeded),
                        'an incompatible cache is discarded');
                }
            };
        }
    }
};

subtest 'normal protocol leaves discard live caches inherited from outer scopes' => sub {
    my @cases = (
        {
            label    => 'incoming WebSocket cache',
            kind     => 'websocket',
            class    => 'PAGI::WebSocket',
            cache_at => 'incoming',
            id       => 'incoming-ws',
            event    => {
                type => 'websocket.close', code => 1000,
                reason => 'selected',
            },
        },
        {
            label    => 'incoming SSE cache',
            kind     => 'sse',
            class    => 'PAGI::SSE',
            cache_at => 'incoming',
            id       => 'incoming-sse',
            event    => { type => 'sse.start', status => 200 },
        },
        {
            label    => 'Router-middleware WebSocket cache',
            kind     => 'websocket',
            class    => 'PAGI::WebSocket',
            cache_at => 'router',
            id       => 'router-ws',
            event    => {
                type => 'websocket.close', code => 1000,
                reason => 'selected',
            },
        },
        {
            label    => 'Mount-middleware SSE cache',
            kind     => 'sse',
            class    => 'PAGI::SSE',
            cache_at => 'mount',
            id       => 'mount-sse',
            event    => { type => 'sse.close', reason => 'selected' },
        },
    );

    for my $case (@cases) {
        subtest $case->{label} => sub {
            my (@old_events, @selected_events, @wire_events);
            my ($stale, $handled, $selected_scope, $handled_params,
                $handled_frame, $received_from);

            my $capture_selected = middleware(sub {
                my ($inner) = @_;
                return sub {
                    $selected_scope = $_[0];
                    return $inner->(@_);
                };
            });
            my $handler = async sub {
                my ($protocol) = @_;
                $handled = $protocol;
                $handled_params = { %{$protocol->path_params} };
                my $container = $protocol->scope->{'pagi.routing'};
                my $frames = ref($container) eq 'HASH'
                    ? $container->{frames}
                    : undef;
                $handled_frame = ref($frames) eq 'ARRAY' && @$frames
                    ? $frames->[-1]
                    : undef;

                if ($case->{cache_at} eq 'incoming'
                        && $case->{kind} eq 'websocket') {
                    my $event = await $protocol->receive;
                    $received_from = $event->{text};
                    await $protocol->close(1000, 'selected');
                }
                elsif ($case->{cache_at} eq 'incoming') {
                    await $protocol->run;
                    $received_from = $protocol->disconnect_reason;
                }
                elsif ($case->{kind} eq 'websocket') {
                    await $protocol->close(1000, 'selected');
                }
                else {
                    await $protocol->close(reason => 'selected');
                }
                return;
            };
            my $leaf = $case->{kind} eq 'websocket'
                ? websocket('/stream/{id}' => $handler,
                    middleware => [$capture_selected])
                : sse('/stream/{id}' => $handler,
                    middleware => [$capture_selected]);

            my $outer_cache = middleware(sub {
                my ($inner) = @_;
                return sub {
                    my ($outer_scope, $receive, $send) = @_;
                    my $old_send = sub {
                        push @old_events, $_[0];
                        return $send->($_[0]);
                    };
                    $stale = $case->{class}->new(
                        $outer_scope, $receive, $old_send,
                    );
                    my $selected_send = sub {
                        push @selected_events, $_[0];
                        return $send->($_[0]);
                    };
                    return $inner->(
                        $outer_scope, $receive, $selected_send,
                    );
                };
            });

            my $routing = $case->{cache_at} eq 'mount'
                ? router(routes => [
                    mount('/api', routes => [$leaf],
                        middleware => [$outer_cache]),
                ])
                : router(
                    routes => [$leaf],
                    ($case->{cache_at} eq 'router'
                        ? (middleware => [$outer_cache])
                        : ()),
                );
            my $app = $routing->to_app;
            my $path = $case->{cache_at} eq 'mount'
                ? '/api/stream/' . $case->{id}
                : '/stream/' . $case->{id};
            my $incoming = scope(
                type => $case->{kind}, path => $path, raw_path => $path,
            );
            my $receive = sub {
                return Future->done(
                    $case->{kind} eq 'websocket'
                        ? { type => 'websocket.receive', text => 'selected' }
                        : { type => 'sse.disconnect', reason => 'selected' },
                );
            };
            my $wire_send = sub {
                push @wire_events, $_[0];
                return Future->done;
            };

            if ($case->{cache_at} eq 'incoming') {
                my $old_receive = sub {
                    return Future->done(
                        $case->{kind} eq 'websocket'
                            ? { type => 'websocket.receive', text => 'old' }
                            : { type => 'sse.disconnect', reason => 'old' },
                    );
                };
                $stale = $case->{class}->new(
                    $incoming,
                    $old_receive,
                    sub {
                        push @old_events, $_[0];
                        return Future->done;
                    },
                );
                my $selected_send = sub {
                    push @selected_events, $_[0];
                    return $wire_send->($_[0]);
                };
                $app->($incoming, $receive, $selected_send)->get;
            }
            else {
                $app->($incoming, $receive, $wire_send)->get;
            }

            isnt(refaddr($handled), refaddr($stale),
                'handler does not reuse the live outer-scope object');
            is(refaddr($handled->scope), refaddr($selected_scope),
                'handler object retains the exact selected route scope');
            is($handled_params, { id => $case->{id} },
                'handler object sees selected path parameters');
            is($handled_frame && $handled_frame->{captures},
                { id => $case->{id} },
                'handler object sees the selected routing frame');
            is($received_from, 'selected',
                'an incoming stale cache cannot retain the old receive callback')
                if $case->{cache_at} eq 'incoming';
            is(\@old_events, [],
                'handler emits nothing through the inherited callback');
            is(\@selected_events, [$case->{event}],
                'handler emits through the selected callback');
            is(\@wire_events, [$case->{event}],
                'selected callback forwards the event to the wire');
        };
    }
};

subtest 'as_app_object HTTP, WebSocket, and SSE leaves own their exact matched channels' => sub {
    my @seen;
    my $native = sub {
        my ($label, $event) = @_;
        return sub {
            my ($request_scope, $receive, $send) = @_;
            push @seen, {
                label      => $label,
                argument_count => scalar @_,
                scope      => $request_scope,
                receive_id => refaddr($receive),
                send_id    => refaddr($send),
            };
            $send->($event)->get;
            return "$label completion" if $label ne 'sse';
            return Future->done("$label Future completion");
        };
    };
    my $app = router(routes => [
        route('/native-http/{id}' => as_app_object($native->('http', {
            type => 'http.response.start', status => 204, headers => [],
        }))),
        websocket('/native-ws/{id}' => as_app_object($native->('websocket', {
            type => 'websocket.close', code => 1001, reason => 'native',
        }))),
        sse('/native-sse/{id}' => as_app_object($native->('sse', {
            type => 'sse.close',
        }))),
    ])->to_app;

    my @cases = (
        ['http', scope(path => '/native-http/1', raw_path => '/native-http/1')],
        ['websocket', scope(type => 'websocket', path => '/native-ws/2', raw_path => '/native-ws/2')],
        ['sse', scope(type => 'sse', path => '/native-sse/3', raw_path => '/native-sse/3')],
    );
    my @event_sets;
    for my $case (@cases) {
        my ($label, $request_scope) = @$case;
        my $receive = sub { Future->done({ type => "$label.receive" }) };
        my @events;
        my $send = sub {
            push @events, $_[0];
            return Future->done;
        };
        $app->($request_scope, $receive, $send)->get;
        push @event_sets, \@events;
        is($seen[-1]{receive_id}, refaddr($receive), "$label native leaf receives the exact receive channel");
        isnt($seen[-1]{send_id}, refaddr($send),
            "$label native leaf receives the Router-owned send boundary");
    }

    is(
        [map {
            [$_->{label}, $_->{argument_count}, $_->{scope}{type},
                $_->{scope}{path_params}]
        } @seen],
        [
            ['http', 3, 'http', { id => '1' }],
            ['websocket', 3, 'websocket', { id => '2' }],
            ['sse', 3, 'sse', { id => '3' }],
        ],
        'as_app_object leaves receive exactly three native values and matched child scopes',
    );
    is($event_sets[0], [{ type => 'http.response.start', status => 204, headers => [] }],
        'as_app_object HTTP leaf owns HTTP emission');
    is($event_sets[1], [{ type => 'websocket.close', code => 1001, reason => 'native' }],
        'as_app_object WebSocket leaf owns WebSocket emission');
    is($event_sets[2], [{ type => 'sse.close' }],
        'as_app_object SSE leaf owns SSE emission and its Future result is inert');
};

subtest 'handler and native protocols apply inline providers and explicit constraints before invocation' => sub {
    my (@normal_ws, @native_ws, @normal_sse, @native_sse);
    my $app = router(routes => [
        websocket('/provider-ws/{id:&ProtocolProvider}' => async sub {
            push @normal_ws, $_[0]->path_param('id');
            await $_[0]->close(1000, 'normal provider');
        }),
        websocket('/predicate-ws/{id}' => as_app_object(sub {
            my ($request_scope, $receive, $send) = @_;
            push @native_ws, $request_scope->{path_params}{id};
            $send->({
                type => 'websocket.close', code => 1001, reason => 'native predicate',
            })->get;
            return Future->done;
        }), name => 'predicate-ws',
            constraints => { id => Local::ProtocolPathCheck->new('accepted') }),
        sse('/predicate-sse/{id}' => async sub {
            push @normal_sse, $_[0]->path_param('id');
            await $_[0]->close;
        }, name => 'predicate-sse',
            constraints => { id => sub { return $_[0] eq 'accepted' } }),
        sse('/provider-sse/{id:&ProtocolProvider}' => as_app_object(sub {
            my ($request_scope, $receive, $send) = @_;
            push @native_sse, $request_scope->{path_params}{id};
            $send->({ type => 'sse.close' })->get;
            return Future->done;
        })),
    ])->to_app;

    is(run_scope($app, scope(type => 'websocket', path => '/provider-ws/accepted')),
        [{ type => 'websocket.close', code => 1000, reason => 'normal provider' }],
        'normal WebSocket dispatch accepts an inline provider capture');
    is(run_scope($app, scope(type => 'websocket', path => '/predicate-ws/accepted')),
        [{ type => 'websocket.close', code => 1001, reason => 'native predicate' }],
        'native WebSocket dispatch accepts an explicit check object');
    is(run_scope($app, scope(type => 'sse', path => '/predicate-sse/accepted')),
        [{ type => 'sse.close' }],
        'normal SSE dispatch accepts an explicit predicate');
    is(run_scope($app, scope(type => 'sse', path => '/provider-sse/accepted')),
        [{ type => 'sse.close' }],
        'native SSE dispatch accepts an inline provider capture');

    for my $path (qw(/provider-ws/rejected /predicate-ws/rejected)) {
        my $events = run_scope($app, scope(
            type => 'websocket', path => $path,
            extensions => { 'websocket.http.response' => {} },
        ));
        is($events->[0]{type}, 'websocket.http.response.start',
            "$path rejection uses the existing WebSocket denial family");
        is($events->[0]{status}, 404, "$path rejection is a denial 404");
    }
    for my $path (qw(/predicate-sse/rejected /provider-sse/rejected)) {
        my $events = run_scope($app, scope(type => 'sse', path => $path));
        is($events->[0]{type}, 'sse.http.response.start',
            "$path rejection uses the existing SSE decline family");
        is($events->[0]{status}, 404, "$path rejection is a decline 404");
    }

    is(\@normal_ws, ['accepted'], 'normal WebSocket handler runs only after acceptance');
    is(\@native_ws, ['accepted'], 'native WebSocket app runs only after acceptance');
    is(\@normal_sse, ['accepted'], 'normal SSE handler runs only after acceptance');
    is(\@native_sse, ['accepted'], 'native SSE app runs only after acceptance');
};

subtest 'protocol adapters await pending completion and propagate failures' => sub {
    my $normal_completion = Future->new;
    my ($normal_object, $normal_argument_count);
    my $normal_app = websocket('/wait' => sub {
        $normal_argument_count = scalar @_;
        $normal_object = $_[0];
        return $normal_completion;
    })->to_app;
    my @normal_events;
    my $normal_running = $normal_app->(
        scope(type => 'websocket', path => '/wait'),
        sub { Future->done({ type => 'websocket.connect' }) },
        sub { push @normal_events, $_[0]; return Future->done },
    );
    ok(!$normal_running->is_ready, 'normal protocol dispatch waits for handler completion');
    isa_ok($normal_object, ['PAGI::WebSocket']);
    is($normal_argument_count, 1,
        'pending normal protocol handler receives exactly one direct object');
    $normal_completion->done({ ignored => 'handler value' });
    is($normal_running->get, undef, 'normal completion resolves to inert router completion');
    is(\@normal_events, [], 'normal resolved value is not interpreted as an event');

    my $native_completion = Future->new;
    my $native_app = sse('/wait' => as_app_object(sub {
        return $native_completion;
    }))->to_app;
    my $native_running = $native_app->(
        scope(type => 'sse', path => '/wait'),
        sub { Future->done({ type => 'sse.disconnect' }) },
        sub { return Future->done },
    );
    ok(!$native_running->is_ready, 'native protocol dispatch waits for application completion');
    $native_completion->done('ignored native value');
    is($native_running->get, undef, 'native Future result remains inert');

    my $throwing = websocket('/boom' => sub { die "synchronous protocol boom\n" })->to_app;
    like(
        dies { run_scope($throwing, scope(type => 'websocket', path => '/boom')) },
        qr/synchronous protocol boom/,
        'a synchronous handler exception propagates without becoming a decline',
    );
    my $failing = sse('/boom' => sub {
        return Future->fail("failed protocol Future\n");
    })->to_app;
    like(
        dies { run_scope($failing, scope(type => 'sse', path => '/boom')) },
        qr/failed protocol Future/,
        'a failed handler Future propagates without becoming a decline',
    );
};

subtest 'protocol selection is declaration ordered, protocol local, and mount aware' => sub {
    my @trace;
    my $route_middleware = middleware(sub {
        my ($inner) = @_;
        return async sub {
            push @trace, 'route before';
            my $returned = $inner->(@_);
            await Future->wrap($returned);
            push @trace, 'route after';
        };
    });
    my $mount_middleware = middleware(sub {
        my ($inner) = @_;
        return async sub {
            push @trace, 'mount before';
            my $returned = $inner->(@_);
            await Future->wrap($returned);
            push @trace, 'mount after';
        };
    });
    my $app = router(routes => [
        route('/shared' => sub {
            push @trace, 'http';
            return PAGI::Response::Text->new('http');
        }),
        websocket('/shared' => async sub {
            push @trace, 'first websocket';
            await $_[0]->close;
        }),
        websocket('/shared' => async sub {
            push @trace, 'second websocket';
            await $_[0]->close;
        }),
        sse('/shared' => async sub {
            push @trace, 'sse';
            await $_[0]->close;
        }),
        mount('/blocked/{tenant}', routes => [
            websocket('/socket' => async sub {
                push @trace, 'blocked mount';
                await $_[0]->close;
            }),
        ], constraints => { tenant => qr/allowed/ }),
        websocket('/blocked/denied/socket' => async sub {
            push @trace, 'constraint fallback';
            await $_[0]->close;
        }, middleware => [$route_middleware]),
        mount('/nested', routes => [
            sse('/events' => async sub {
                push @trace, 'nested sse';
                await $_[0]->close;
            }, middleware => [$route_middleware]),
        ], middleware => [$mount_middleware]),
    ])->to_app;

    run_scope($app, scope(type => 'websocket', path => '/shared'));
    run_scope($app, scope(type => 'sse', path => '/shared'));
    run_scope($app, scope(type => 'websocket', path => '/blocked/denied/socket'));
    run_scope($app, scope(type => 'sse', path => '/nested/events'));

    is(\@trace, [
        'first websocket',
        'sse',
        'route before', 'constraint fallback', 'route after',
        'mount before', 'route before', 'nested sse', 'route after', 'mount after',
    ], 'only matching protocol leaves run; failed mount constraints continue and middleware surrounds selected leaves');

    my @mounted;
    my $component = router(routes => [
        mount('/component', app => sub {
            my ($request_scope) = @_;
            push @mounted, [
                $request_scope->{type} // 'http',
                $request_scope->{method},
                $request_scope->{path},
            ];
            return 'application completion';
        }),
    ])->to_app;
    run_scope($component, scope(type => 'http', method => 'DELETE', path => '/component/x'));
    run_scope($component, scope(type => 'websocket', method => undef, path => '/component/x'));
    run_scope($component, scope(type => 'sse', method => undef, path => '/component/x'));
    is(\@mounted, [
        ['http', 'DELETE', '/x'],
        ['websocket', undef, '/x'],
        ['sse', undef, '/x'],
    ], 'an application mount owns every supported scope type without an HTTP method filter');
};

subtest 'the first prefix Mount owns every protocol and middleware boundary' => sub {
    my (@middleware_types, @later_calls);
    my $mount_middleware = middleware(sub {
        my ($inner) = @_;
        return async sub {
            push @middleware_types, $_[0]{type};
            await Future->wrap($inner->(@_));
        };
    });
    my $first = router(routes => [
        route('/http' => sub { return PAGI::Response::Text->new('first http') }),
        websocket('/socket' => async sub {
            await $_[0]->close(1000, 'first websocket');
        }),
        sse('/events' => async sub {
            await $_[0]->close;
        }),
    ]);
    my $later = async sub {
        push @later_calls, $_[0]{type};
        die 'a later same-prefix Mount must not run';
    };
    my $app = router(routes => [
        mount('/api', app => $first, middleware => [$mount_middleware]),
        mount('/api', app => $later),
        websocket('/api/missing' => async sub {
            push @later_calls, 'parent websocket';
            await $_[0]->close;
        }),
        sse('/api/missing' => async sub {
            push @later_calls, 'parent sse';
            await $_[0]->close;
        }),
    ])->to_app;

    my $http = run_scope($app, scope(
        path => '/api/http', raw_path => '/api/http'));
    my $websocket = run_scope($app, scope(
        type => 'websocket', path => '/api/socket', raw_path => '/api/socket'));
    my $sse = run_scope($app, scope(
        type => 'sse', path => '/api/events', raw_path => '/api/events'));
    is($http->[-1]{body}, 'first http',
        'the first same-prefix Mount owns HTTP');
    is($websocket, [
        { type => 'websocket.close', code => 1000, reason => 'first websocket' },
    ], 'the first same-prefix Mount owns WebSocket');
    is($sse, [{ type => 'sse.close' }],
        'the first same-prefix Mount owns SSE');

    is(run_scope($app, scope(
        type => 'websocket', path => '/api/missing', raw_path => '/api/missing')),
        [{ type => 'websocket.close' }],
        'a child WebSocket miss closes without parent resumption');
    my $denial = run_scope($app, scope(
        type => 'websocket', path => '/api/missing', raw_path => '/api/missing',
        extensions => { 'websocket.http.response' => {} }));
    is([$denial->[0]{type}, $denial->[0]{status}],
        ['websocket.http.response.start', 404],
        'a child WebSocket miss owns its HTTP denial');
    my $sse_miss = run_scope($app, scope(
        type => 'sse', path => '/api/missing', raw_path => '/api/missing'));
    is([$sse_miss->[0]{type}, $sse_miss->[0]{status}],
        ['sse.http.response.start', 404],
        'a child SSE miss owns its protocol-specific 404');
    is(\@middleware_types,
        [qw(http websocket sse websocket websocket sse)],
        'Mount middleware sees successes and misses for all delegated protocols');
    is(\@later_calls, [],
        'neither a later Mount nor later parent protocol sibling resumes');
};

subtest 'HTTP selection ignores WebSocket and SSE leaves without warnings' => sub {
    my $app = router(routes => [
        websocket('/ws-only' => sub { return 'inert' }),
        sse('/sse-only' => sub { return 'inert' }),
        websocket('/shared' => sub { return 'inert' }),
        sse('/shared' => sub { return 'inert' }),
        route('/shared' => sub { return PAGI::Response::Text->new('http leaf') }),
    ])->to_app;

    my @warnings;
    my ($ws_only, $sse_only, $shared);
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $ws_only = run_scope($app, scope(path => '/ws-only'));
        $sse_only = run_scope($app, scope(path => '/sse-only'));
        $shared = run_scope($app, scope(path => '/shared'));
    }

    is(\@warnings, [], 'mixed-protocol route tables do not warn during HTTP selection');
    is($ws_only->[0]{status}, 404,
        'a WebSocket-only path reaches the HTTP Router 404');
    is($sse_only->[0]{status}, 404,
        'an SSE-only path reaches the HTTP Router 404');
    is($shared->[0]{status}, 200, 'HTTP scanning continues to a later same-path HTTP leaf');
    is($shared->[1]{body}, 'http leaf', 'the later HTTP leaf owns the response');
};

subtest 'protocol misses, lifespan, and unknown scopes have distinct wire outcomes' => sub {
    my @http_default_calls;
    my $app = router(
        http_default => as_app_object(async sub {
            my ($request_scope, $receive, $send) = @_;
            push @http_default_calls, $request_scope->{type} // 'http';
            await Future->wrap($send->({
                type => 'http.response.start', status => 404, headers => [],
            }));
            await Future->wrap($send->({
                type => 'http.response.body', body => 'custom HTTP missing',
                more => 0,
            }));
        }),
        routes => [],
    )->to_app;

    my $sse_events = run_scope($app, scope(type => 'sse', path => '/missing'));
    is($sse_events, [
        {
            type    => 'sse.http.response.start',
            status  => 404,
            headers => [['content-type', 'text/plain']],
        },
        {
            type => 'sse.http.response.body',
            body => 'Not Found',
            more => 0,
        },
    ], 'an unmatched SSE scope receives the SSE decline event family');

    my $ws_denial = run_scope($app, scope(
        type       => 'websocket',
        path       => '/missing',
        extensions => { 'websocket.http.response' => {} },
    ));
    is($ws_denial, [
        {
            type    => 'websocket.http.response.start',
            status  => 404,
            headers => [['content-type', 'text/plain']],
        },
        {
            type => 'websocket.http.response.body',
            body => 'Not Found',
            more => 0,
        },
    ], 'the advertised WebSocket denial extension carries a namespaced 404');

    my $ws_close = run_scope($app, scope(
        type => 'websocket',
        path => '/missing',
    ));
    is($ws_close, [{ type => 'websocket.close' }],
        'without the denial extension an unmatched WebSocket closes before acceptance');
    is(\@http_default_calls, [],
        'WebSocket and SSE misses never invoke the HTTP default');

    my ($lifespan_reads, $lifespan_sends) = (0, 0);
    my $lifespan_result = $app->(
        { type => 'lifespan' },
        sub { ++$lifespan_reads; return Future->fail('must not read lifespan') },
        sub { ++$lifespan_sends; return Future->fail('must not send lifespan') },
    )->get;
    is($lifespan_result, undef, 'lifespan returns inert completion');
    is([$lifespan_reads, $lifespan_sends], [0, 0],
        'lifespan completion neither reads nor sends');

    like(
        dies {
            $app->(
                { method => 'GET', path => '/missing', headers => [] },
                sub { return Future->done },
                sub { return Future->done },
            )->get;
        },
        qr/PAGI scope type is required/,
        'a missing scope type is rejected as a malformed PAGI scope',
    );
    is(\@http_default_calls, [],
        'a malformed scope never invokes the HTTP default');

    my ($grpc_reads, $grpc_sends) = (0, 0);
    like(
        dies {
            $app->(
                { type => 'grpc', path => '/missing' },
                sub { ++$grpc_reads; return Future->done },
                sub { ++$grpc_sends; return Future->done },
            )->get;
        },
        qr/unsupported PAGI scope type 'grpc'/,
        'an unknown scope type croaks with the type in the diagnostic',
    );
    is([$grpc_reads, $grpc_sends], [0, 0],
        'unknown scope rejection does not touch either channel');
};

subtest 'scope-type gates run before short-circuiting router middleware' => sub {
    my @middleware_types;
    my $short_circuit = middleware(sub {
        my ($inner) = @_;
        return async sub {
            my ($request_scope, $receive, $send) = @_;
            push @middleware_types, $request_scope->{type} // 'http';
            await $receive->();
            await $send->({
                type => 'http.response.start', status => 200, headers => [],
            });
            await $send->({
                type => 'http.response.body', body => 'middleware', more => 0,
            });
            return;
        };
    });
    my $app = router(
        routes => [],
        middleware => [$short_circuit],
    )->to_app;

    my ($lifespan_reads, $lifespan_sends) = (0, 0);
    is(
        $app->(
            { type => 'lifespan' },
            sub { ++$lifespan_reads; return Future->done({ type => 'lifespan.startup' }) },
            sub { ++$lifespan_sends; return Future->done },
        )->get,
        undef,
        'lifespan returns before short-circuiting router middleware',
    );
    is([$lifespan_reads, $lifespan_sends], [0, 0],
        'router middleware cannot read or send on lifespan');
    is(\@middleware_types, [], 'lifespan never enters router middleware');

    my ($missing_reads, $missing_sends) = (0, 0);
    like(
        dies {
            $app->(
                { path => '/' },
                sub { ++$missing_reads; return Future->done },
                sub { ++$missing_sends; return Future->done },
            )->get;
        },
        qr/PAGI scope type is required/,
        'a missing type is rejected before short-circuiting router middleware',
    );
    is([$missing_reads, $missing_sends], [0, 0],
        'router middleware cannot touch malformed-scope channels');
    is(\@middleware_types, [], 'malformed scopes never enter router middleware');

    my ($grpc_reads, $grpc_sends) = (0, 0);
    like(
        dies {
            $app->(
                { type => 'grpc', path => '/' },
                sub { ++$grpc_reads; return Future->done({ type => 'grpc.request' }) },
                sub { ++$grpc_sends; return Future->done },
            )->get;
        },
        qr/unsupported PAGI scope type 'grpc'/,
        'unknown scopes are rejected before short-circuiting router middleware',
    );
    is([$grpc_reads, $grpc_sends], [0, 0],
        'router middleware cannot touch unknown-scope channels');
    is(\@middleware_types, [], 'unknown scopes never enter router middleware');

    my $http_reads = 0;
    my @http_events;
    my $http_running = $app->(
        scope(method => 'HEAD', path => '/short'),
        sub { ++$http_reads; return Future->done({ type => 'http.request' }) },
        sub { push @http_events, $_[0]; return Future->done },
    );
    $http_running->get;
    is($http_reads, 1, 'supported HTTP still reaches router middleware');
    is(\@middleware_types, ['http'], 'supported type enters router middleware normally');
    is(\@http_events, [
        { type => 'http.response.start', status => 200, headers => [] },
        { type => 'http.response.body', body => '', more => 0 },
    ], 'the outer HEAD wire boundary still suppresses middleware-owned bodies');
};

subtest 'standalone protocol leaves and mounts compile as complete applications' => sub {
    my $ws_app = websocket('/socket' => async sub {
        await $_[0]->close(1000, 'standalone');
    })->to_app;
    my $sse_app = sse('/events' => async sub {
        await $_[0]->close;
    })->to_app;

    is(ref($ws_app), 'CODE', 'a standalone WebSocket node compiles to an application');
    is(ref($sse_app), 'CODE', 'a standalone SSE node compiles to an application');
    is(run_scope($ws_app, scope(type => 'websocket', path => '/socket')), [
        { type => 'websocket.close', code => 1000, reason => 'standalone' },
    ], 'the standalone WebSocket application dispatches its leaf');
    is(run_scope($ws_app, scope(type => 'sse', path => '/missing'))->[0]{type},
        'sse.http.response.start', 'a standalone WebSocket application retains SSE fallback behavior');
    is(run_scope($sse_app, scope(type => 'sse', path => '/events')), [
        { type => 'sse.close' },
    ], 'the standalone SSE application dispatches its leaf');
    is(run_scope($sse_app, scope(type => 'websocket', path => '/missing')), [
        { type => 'websocket.close' },
    ], 'a standalone SSE application retains WebSocket fallback behavior');

    my @trace;
    my $mount_wrapper = middleware(sub {
        my ($inner) = @_;
        return async sub {
            push @trace, 'mount before';
            my $returned = $inner->(@_);
            await Future->wrap($returned);
            push @trace, 'mount after';
        };
    });
    my $mount_app = mount('/api', routes => [
        websocket('/socket' => async sub { await $_[0]->close }),
    ], middleware => [$mount_wrapper])->to_app;
    is(ref($mount_app), 'CODE', 'a standalone mount compiles to an application');
    my $mounted_miss = run_scope($mount_app, scope(
        type => 'websocket', path => '/api/missing',
        extensions => { 'websocket.http.response' => {} },
    ));
    is($mounted_miss->[0]{type}, 'websocket.http.response.start',
        'the routes-shorthand child owns its protocol-specific miss');
    is($mounted_miss->[0]{status}, 404, 'the child Router emits its complete 404 fallback');
    is(\@trace, ['mount before', 'mount after'],
        'mount middleware surrounds a child protocol miss');
};

done_testing;
