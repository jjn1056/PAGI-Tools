#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);
use FindBin qw($Bin);
use lib "$Bin/lib", "$Bin/../lib";
use ComposeTest qw(scope run_scope capture_send);
use PAGI::Compose qw(compose);
use PAGI::Routing qw(route websocket sse);

subtest 'routes mode dispatches HTTP WebSocket and SSE' => sub {
    my $app = compose(routes => [
        route('/' => sub { return $_[0]->text('home') }),
        websocket('/ws' => async sub {
            my ($c) = @_;
            await $c->accept;
            await $c->send_text('hello');
            await $c->close;
        }),
        sse('/events' => sub {
            my ($c) = @_;
            $c->start->get;
            $c->send('ready')->get;
            $c->close->get;
        }),
    ])->to_app;

    my $http = run_scope($app, scope(path => '/'));
    is([map { $_->{type} } @$http],
        [qw(http.response.start http.response.body)],
        'HTTP route emits one response pair');
    is($http->[0]{status}, 200, 'HTTP route status is retained');
    is($http->[1],
        { type => 'http.response.body', body => 'home', more => 0 },
        'HTTP route emits its returned response body');
    is(run_scope($app, scope(type => 'websocket', path => '/ws')), [
        { type => 'websocket.accept' },
        { type => 'websocket.send', text => 'hello' },
        { type => 'websocket.close', code => 1000, reason => '' },
    ], 'WebSocket route runs through its Context');
    is(run_scope($app, scope(type => 'sse', path => '/events')), [
        { type => 'sse.start', status => 200 },
        { type => 'sse.send', data => 'ready' },
        { type => 'sse.close' },
    ], 'SSE route runs through its Context');
};

{
    package Local::ComposeComponent;
    our $COMPILES = 0;
    sub new { return bless {}, $_[0] }
    sub to_app {
        ++$COMPILES;
        return sub { return Future->done };
    }
}
{
    package Local::ComposeClass;
    our $COMPILES = 0;
    sub to_app {
        ++$COMPILES;
        return sub { return Future->done };
    }
}
{
    package Local::NoToApp;
    sub new { return bless {}, $_[0] }
}

subtest 'non-HTTP immediate and Future-backed app completion remain normalized' => sub {
    my $immediate_calls = 0;
    my $immediate = compose(app => sub { ++$immediate_calls; return })->to_app;
    run_scope($immediate, scope(type => 'example.extension'));
    is($immediate_calls, 1, 'immediate app completes normally');

    my $pending = Future->new;
    my $future_app = compose(app => sub { return $pending })->to_app;
    my ($send) = capture_send();
    my $running = $future_app->(
        scope(type => 'example.extension'),
        sub { return Future->done },
        $send,
    );
    ok(!$running->is_ready, 'compiled app awaits a pending target Future');
    $pending->done('ignored target value');
    is($running->get, undef, 'target result is inert');

    my $throwing = compose(app => sub { die "target threw\n" })->to_app;
    like(dies { run_scope($throwing, scope(type => 'example.extension')) },
        qr/target threw/, 'synchronous target errors propagate');
    my $failing = compose(app => sub {
        return Future->fail("target Future failed\n");
    })->to_app;
    like(dies { run_scope($failing, scope(type => 'example.extension')) },
        qr/target Future failed/, 'failed target Futures propagate');
};

subtest 'object and class targets compile once per to_app' => sub {
    local $Local::ComposeComponent::COMPILES = 0;
    local $Local::ComposeClass::COMPILES = 0;
    my $object_description = compose(app => Local::ComposeComponent->new);
    my $object_app = $object_description->to_app;
    run_scope($object_app, scope(type => 'example.extension'));
    run_scope($object_app, scope(type => 'example.extension'));
    is($Local::ComposeComponent::COMPILES, 1, 'requests reuse one object compilation');
    my $object_app_two = $object_description->to_app;
    is($Local::ComposeComponent::COMPILES, 2, 'second to_app recompiles object');

    my $class_app = compose(app => 'Local::ComposeClass')->to_app;
    run_scope($class_app, scope(type => 'example.extension'));
    is($Local::ComposeClass::COMPILES, 1, 'loaded class compiles once');

    ok(!TestApps::AutoLoaded->can('to_app'), 'fixture class starts unloaded');
    my $autoloaded = compose(app => 'TestApps::AutoLoaded')->to_app;
    my $events = run_scope($autoloaded, scope(type => 'http'));
    is($events->[1]{body}, 'autoloaded', 'loadable class is required and compiled');
};

subtest 'app mode delegates unknown non-lifespan scopes by channel identity' => sub {
    my @seen;
    my $target = sub {
        push @seen, [map { refaddr($_) } @_];
        return;
    };
    my $app = compose(app => $target)->to_app;
    my $extension_scope = { type => 'example.extension', value => 1 };
    my $receive = sub { return Future->done };
    my $send = sub { return Future->done };
    $app->($extension_scope, $receive, $send)->get;
    is($seen[0], [map { refaddr($_) } ($extension_scope, $receive, $send)],
        'all three native channels reach the target unchanged');
};

subtest 'object capability errors remain at compilation' => sub {
    my $description = compose(app => Local::NoToApp->new);
    like(dies { $description->to_app }, qr/no to_app method/,
        'PAGI::Utils reports the unsupported object');
};

subtest 'no-hook lifespan succeeds without state and never reaches target' => sub {
    my $target_calls = 0;
    my $app = compose(app => sub { ++$target_calls })->to_app;
    my $events = run_scope($app, scope(type => 'lifespan'), [
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    ]);
    is($events, [
        { type => 'lifespan.startup.complete' },
        { type => 'lifespan.shutdown.complete' },
    ], 'Compose uniformly supports no-hook lifecycle');
    is($target_calls, 0, 'target never receives lifespan');
};

subtest 'only the outer composition owns nested lifecycle' => sub {
    my $inner_startup = 0;
    my $request_calls = 0;
    my $inner = compose(
        app => sub { ++$request_calls; return },
        lifespan => { startup => sub { ++$inner_startup; return } },
    );
    my $outer = compose(app => $inner)->to_app;
    run_scope($outer, scope(type => 'lifespan'), [
        { type => 'lifespan.startup' },
        { type => 'lifespan.shutdown' },
    ]);
    is($inner_startup, 0, 'outer owner never delegates lifecycle to nested Compose');
    run_scope($outer, scope(type => 'example.extension'));
    is($request_calls, 1, 'nested Compose remains a normal request target');
};

done_testing;
