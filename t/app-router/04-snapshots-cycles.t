#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::App::Router::Builder ();
use PAGI::Compose qw(compose);
use PAGI::Response::Text ();
use PAGI::Routing::URL qw(path_for);
use PAGI::Routing::Router ();
use PAGI::Test::Client ();

sub handler {
    my ($body) = @_;
    return sub { return PAGI::Response::Text->new($body) };
}

sub receive {
    return Future->done({ type => 'http.request', body => '', more => 0 });
}

sub scope {
    my (%changes) = @_;
    return {
        type => 'http', method => 'GET', path => '/', raw_path => '/',
        root_path => '', path_params => {}, headers => [], %changes,
    };
}

sub response_body {
    my ($events) = @_;
    return join '', map { $_->{body} || '' }
        grep { ($_->{type} || '') eq 'http.response.body' } @$events;
}

sub router_methods_exist {
    my ($builder) = @_;
    my $ok = 1;
    for my $method (qw(mount to_router to_app)) {
        $ok = 0 unless ok($builder->can($method), "Builder provides $method");
    }
    return $ok;
}

sub malformed_child_mount {
    my ($path, $child, $name) = @_;
    return {
        node_kind           => 'mount',
        declaration_package => __PACKAGE__,
        path                => $path,
        child               => $child,
        middleware          => [],
        name                => $name,
        desc                => undef,
        constraints         => undef,
    };
}

{
    package Local::FailOnceBuilder;
    our @ISA = ('PAGI::App::Router::Builder');

    sub _materialize_with {
        my ($self, $materializer) = @_;
        die "first materialization failure\n" unless $self->{failed_once}++;
        return $self->SUPER::_materialize_with($materializer);
    }
}

{
    package Local::SharedStateMiddleware;

    sub new {
        my ($class, $state) = @_;
        return bless {
            state => $state, wrappers => [], inner_ids => [], state_ids => [],
        }, $class;
    }

    sub wrap {
        my ($self, $inner) = @_;
        push @{$self->{inner_ids}}, Scalar::Util::refaddr($inner);
        my $wrapper = sub {
            ++$self->{state}{requests};
            push @{$self->{state_ids}}, Scalar::Util::refaddr($self->{state});
            return $inner->(@_);
        };
        push @{$self->{wrappers}}, $wrapper;
        return $wrapper;
    }
}

subtest 'snapshots are immutable, root-local, and fresh' => sub {
    my $builder = PAGI::App::Router::Builder->new;
    return unless router_methods_exist($builder);
    $builder->get('/one' => handler('one'))->name('one');
    my $first = $builder->to_router;
    $builder->get('/two' => handler('two'))->name('two');
    my $second = $builder->to_router;

    isa_ok($first, 'PAGI::Routing::Router');
    isa_ok($second, 'PAGI::Routing::Router');
    isnt(refaddr($first), refaddr($second),
        'two root snapshots have different Router identities');
    is([map { $_->path } @{$first->routes}], ['/one'],
        'mutation after the first snapshot is invisible to it');
    is([map { $_->path } @{$second->routes}], ['/one', '/two'],
        'a later snapshot sees the later declaration in written order');
    is(PAGI::Test::Client->new(
        app => compose(app => $first)->to_app,
    )->get('/two')->status, 404,
        'the retained first snapshot cannot dispatch a later mutation');
    is(PAGI::Test::Client->new(app => $second->to_app)->get('/two')->text, 'two',
        'the later snapshot dispatches its own immutable declaration set');
};

subtest 'mutable frontends are valid opaque app values without name discovery' => sub {
    my $parent = PAGI::App::Router::Builder->new;
    return unless router_methods_exist($parent);
    $parent->get('/safe' => handler('safe'))->name('safe');

    my $opaque_child = PAGI::App::Router::Builder->new;
    $opaque_child->get('/before' => handler('opaque before'));
    $parent->mount('/opaque', app => $opaque_child)->name('opaque');

    my $raw_child = PAGI::App::Router::Builder->new;
    $raw_child->get('/before' => handler('raw before'));
    $parent->get('/raw', raw => $raw_child)->name('raw');

    my $snapshot = $parent->to_router;
    is(refaddr($snapshot->routes->[1]->app), refaddr($opaque_child),
        'opaque Mount retains the mutable application by identity');
    is(refaddr($snapshot->routes->[2]->target), refaddr($raw_child),
        'raw Route retains the mutable application by identity');
    is($snapshot->route_named('/opaque/before'), undef,
        'opaque mutable Mount internals are not discovered');
    is($snapshot->route_named('/raw'), $snapshot->routes->[2],
        'the raw leaf itself remains discoverable');
};

subtest 'one immutable child Router is reusable at named sibling placements' => sub {
    my $child = PAGI::App::Router::Builder->new;
    return unless router_methods_exist($child);
    $child->get('/item/{id}' => handler('child'))->name('show');

    my $child_router = $child->to_router;
    my $parent = PAGI::App::Router::Builder->new;
    $parent->mount('/left', app => $child_router)->name('left')->desc('Left placement');
    $parent->mount('/right', app => $child_router)->name('right')->desc('Right placement');
    my $first = $parent->to_router;
    my $first_nodes = $first->routes;

    isnt(refaddr($first_nodes->[0]), refaddr($first_nodes->[1]),
        'two placements retain distinct immutable Mount nodes');
    is([map { [$_->path, $_->name, $_->desc] } @$first_nodes], [
        ['/left', 'left', 'Left placement'],
        ['/right', 'right', 'Right placement'],
    ], 'two placements retain distinct path, local name, and description metadata');
    is(refaddr($first_nodes->[0]->app), refaddr($first_nodes->[1]->app),
        'both placements retain one immutable child Router identity');

    my $second_nodes = $parent->to_router->routes;
    is(refaddr($first_nodes->[0]->app), refaddr($second_nodes->[0]->app),
        'an explicit immutable app remains caller-owned across root snapshots');
    is(refaddr($second_nodes->[0]->app), refaddr($second_nodes->[1]->app),
        'the second snapshot retains the same reusable child identity');

    my $immutable = PAGI::Routing::Router->new(routes => []);
    my $immutable_parent = PAGI::App::Router::Builder->new;
    $immutable_parent->mount('/one', app => $immutable)->name('one');
    $immutable_parent->mount('/two', app => $immutable)->name('two');
    my $immutable_nodes = $immutable_parent->to_router->routes;
    is([map { refaddr($_->app) } @$immutable_nodes],
        [refaddr($immutable), refaddr($immutable)],
        'immutable Router inputs retain their original identity at every placement');
};

subtest 'active mutable revisits report the placement chain and clean up' => sub {
    my $a = PAGI::App::Router::Builder->new;
    return unless router_methods_exist($a);
    my $b = PAGI::App::Router::Builder->new;
    push @{$a->{declarations}}, malformed_child_mount('/b', $b, 'b');
    push @{$b->{declarations}}, malformed_child_mount('/a', $a, 'a');

    my $error = dies { $a->to_router };
    like($error, qr{/b(?::b)?.*->.*/a(?::a)?},
        'a cycle reports /b -> /a placement evidence in ancestry order');

    require PAGI::App::Router::Materializer;
    my $materializer = PAGI::App::Router::Materializer->new;
    like(dies { $materializer->materialize($a, '<root>') },
        qr{/b(?::b)?.*->.*/a(?::a)?},
        'direct root materialization reports the same cycle chain');
    is($materializer->{active}, {},
        'a caught recursive error leaves no active mutable identities');
    is($materializer->{placements}, [],
        'a caught recursive error leaves no placement ancestry');

    my $retry_materializer = PAGI::App::Router::Materializer->new;
    my $flaky = Local::FailOnceBuilder->new;
    $flaky->get('/ok' => handler('ok'));
    like(dies { $retry_materializer->materialize($flaky, '<first>') },
        qr/first materialization failure/,
        'a non-cycle frontend error propagates from materialization');
    is($retry_materializer->{active}, {},
        'a direct frontend error cleans the failed identity before rethrow');
    is($retry_materializer->{placements}, [],
        'a direct frontend error cleans its placement before rethrow');
    my $recovered = $retry_materializer->materialize($flaky, '<retry>');
    ok($recovered->isa('PAGI::Routing::Router'),
        'the same failed mutable identity can be retried after cleanup');
};

subtest 'a failed root rolls back completed descendants before retry' => sub {
    my $child = PAGI::App::Router::Builder->new;
    return unless router_methods_exist($child);
    $child->get('/before' => handler('before'));

    my $fails_late = Local::FailOnceBuilder->new;
    $fails_late->get('/eventual' => handler('eventual'));
    my $root = PAGI::App::Router::Builder->new;
    push @{$root->{declarations}},
        malformed_child_mount('/child', $child, 'child');
    push @{$root->{declarations}},
        malformed_child_mount('/late', $fails_late, 'late');

    require PAGI::App::Router::Materializer;
    my $materializer = PAGI::App::Router::Materializer->new;
    like(dies { $materializer->materialize($root, '<root>') },
        qr/first materialization failure/,
        'the root fails only after its first child completed');
    is($materializer->{completed}, {},
        'a failed root operation rolls back child identities it completed');

    $child->get('/after' => handler('after'));
    my $retry = $materializer->materialize($root, '<retry>');
    my $retried_child = $retry->routes->[0]->app;
    is([map { $_->path } @{$retried_child->routes}], ['/before', '/after'],
        'retry rematerializes the child and observes mutation after the failed attempt');
    is(refaddr($retry->routes->[0]->app),
        refaddr($materializer->materialize($child, '<completed-child>')),
        'the successful retry still retains completed identity reuse');
};

{
    package Local::CountingBuilder;
    our @ISA = ('PAGI::App::Router::Builder');

    sub to_router {
        my ($self) = @_;
        ++$self->{to_router_calls};
        return $self->SUPER::to_router;
    }
}

subtest 'to_app materializes once and compiles the retained snapshot' => sub {
    my $builder = Local::CountingBuilder->new;
    return unless router_methods_exist($builder);
    $builder->get('/item' => handler('item'));
    my $root_app = $builder->to_app;
    my $app = compose(app => $root_app)->to_app;
    is($builder->{to_router_calls}, 1, 'to_app calls to_router exactly once');
    $builder->get('/late' => handler('late'));
    my $client = PAGI::Test::Client->new(app => $app);
    is($client->get('/item')->text, 'item', 'the retained snapshot serves existing routes');
    is($client->get('/late')->status, 404,
        'the compiled app does not observe Builder mutation after to_app');
};

subtest 'two to_app calls compile fresh wrappers around caller-owned shared state' => sub {
    my $state = { requests => 0 };
    my $middleware = Local::SharedStateMiddleware->new($state);
    my $builder = PAGI::App::Router::Builder->new(
        middleware => [$middleware],
    );
    $builder->get('/item' => handler('item'));

    my $first = $builder->to_app;
    my $second = $builder->to_app;
    isnt(refaddr($first), refaddr($second),
        'separate to_app calls return distinct compiled root applications');
    is(scalar @{$middleware->{wrappers}}, 2,
        'the configured middleware object wraps once per compilation');
    isnt(refaddr($middleware->{wrappers}[0]), refaddr($middleware->{wrappers}[1]),
        'each compilation receives a fresh middleware wrapper closure');
    isnt($middleware->{inner_ids}[0], $middleware->{inner_ids}[1],
        'each wrapper encloses a fresh downstream compiled graph');

    is(PAGI::Test::Client->new(app => $first)->get('/item')->text, 'item',
        'the first compiled graph dispatches');
    is(PAGI::Test::Client->new(app => $second)->get('/item')->text, 'item',
        'the second compiled graph dispatches');
    is($state->{requests}, 2,
        'both fresh graphs intentionally update the caller-owned state');
    is($middleware->{state_ids}, [(refaddr($state)) x 2],
        'both wrappers retain the exact caller-owned state reference');
};

subtest 'one compiled app isolates two in-flight reused-child requests' => sub {
    my (@contexts, @gates);
    my $child = PAGI::App::Router::Builder->new;
    return unless router_methods_exist($child);
    $child->get('/item/{id}' => sub {
        my ($request) = @_;
        push @contexts, $request;
        my $gate = Future->new;
        push @gates, $gate;
        return $gate;
    })->name('show');
    my $parent = PAGI::App::Router::Builder->new;
    my $child_router = $child->to_router;
    $parent->mount('/left', app => $child_router)->name('left');
    $parent->mount('/right', app => $child_router)->name('right');
    my $app = $parent->to_app;

    my (@left_events, @right_events);
    my $left = $app->(
        scope(path => '/left/item/one', raw_path => '/left/item/one'),
        \&receive,
        sub { push @left_events, $_[0]; return Future->done },
    );
    my $right = $app->(
        scope(path => '/right/item/two', raw_path => '/right/item/two'),
        \&receive,
        sub { push @right_events, $_[0]; return Future->done },
    );

    is(scalar @contexts, 2, 'both handlers start before either response resolves');
    ok(!$left->is_ready && !$right->is_ready,
        'two requests through one compiled app remain independently pending');
    my $left_scope = $contexts[0]->scope;
    my $right_scope = $contexts[1]->scope;
    my $left_frame = $left_scope->{'pagi.routing'}{frames}[-1];
    my $right_frame = $right_scope->{'pagi.routing'}{frames}[-1];
    isnt(refaddr($left_scope->{path_params}), refaddr($right_scope->{path_params}),
        'in-flight captures use distinct request-local hashes');
    isnt(refaddr($left_frame), refaddr($right_frame),
        'in-flight requests use distinct metadata frames');
    isnt(refaddr($left_frame->{mounts}), refaddr($right_frame->{mounts}),
        'in-flight requests use distinct mount chains');
    isnt(refaddr($left_frame->{match}), refaddr($right_frame->{match}),
        'in-flight requests use distinct match records');
    is([$left_scope->{path_params}{id}, $right_scope->{path_params}{id}],
        ['one', 'two'], 'captures do not leak between reused child placements');
    is([map { $_->{name} } @{$left_frame->{mounts}}], ['left'],
        'the first request retains only its left placement metadata');
    is([map { $_->{name} } @{$right_frame->{mounts}}], ['right'],
        'the second request retains only its right placement metadata');
    is([path_for($contexts[0], 'show'), path_for($contexts[1], 'show')],
        ['/left/item/one', '/right/item/two'],
        'concurrent reverse generation uses each active placement and capture');
    is(refaddr($left_frame->{resolver}), refaddr($right_frame->{resolver}),
        'requests share only the immutable compiled resolver');

    push @{$left_frame->{mounts}}, { name => 'consumer-only' };
    $left_frame->{match}{consumer_only} = 1;
    is(scalar @{$right_frame->{mounts}}, 1,
        'consumer mutation of one mount chain is absent from the other');
    is($right_frame->{match}{consumer_only}, undef,
        'consumer mutation of one match record is absent from the other');

    $gates[0]->done(PAGI::Response::Text->new('left one'));
    $gates[1]->done(PAGI::Response::Text->new('right two'));
    $left->get;
    $right->get;
    is(response_body(\@left_events), 'left one',
        'the first in-flight request completes with its own response');
    is(response_body(\@right_events), 'right two',
        'the second in-flight request completes with its own response');
};

done_testing;
