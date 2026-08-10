#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::App::Router::Builder ();
use PAGI::Routing::Router ();
use PAGI::Test::Client ();

sub handler {
    my ($body) = @_;
    return sub { return $_[0]->text($body) };
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

{
    package Local::FailOnceBuilder;
    our @ISA = ('PAGI::App::Router::Builder');

    sub _materialize_with {
        my ($self, $materializer) = @_;
        die "first materialization failure\n" unless $self->{failed_once}++;
        return $self->SUPER::_materialize_with($materializer);
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
    is(PAGI::Test::Client->new(app => $first->to_app)->get('/two')->status, 404,
        'the retained first snapshot cannot dispatch a later mutation');
    is(PAGI::Test::Client->new(app => $second->to_app)->get('/two')->text, 'two',
        'the later snapshot dispatches its own immutable declaration set');
};

subtest 'sibling mutable reuse shares identity only inside one snapshot' => sub {
    my $child = PAGI::App::Router::Builder->new;
    return unless router_methods_exist($child);
    $child->get('/item/{id}' => handler('child'))->name('show');

    my $parent = PAGI::App::Router::Builder->new;
    $parent->mount('/left' => router => $child)->name('left')->desc('Left placement');
    $parent->mount('/right' => router => $child)->name('right')->desc('Right placement');
    my $first = $parent->to_router;
    my $first_nodes = $first->routes;

    isnt(refaddr($first_nodes->[0]), refaddr($first_nodes->[1]),
        'two placements retain distinct immutable Mount nodes');
    is([map { [$_->path, $_->name, $_->desc] } @$first_nodes], [
        ['/left', 'left', 'Left placement'],
        ['/right', 'right', 'Right placement'],
    ], 'two placements retain distinct path, local name, and description metadata');
    is(refaddr($first_nodes->[0]->router), refaddr($first_nodes->[1]->router),
        'one child Builder maps to one child Router identity inside a snapshot');

    my $second_nodes = $parent->to_router->routes;
    isnt(refaddr($first_nodes->[0]->router), refaddr($second_nodes->[0]->router),
        'a separate root snapshot receives a fresh child Router identity');
    is(refaddr($second_nodes->[0]->router), refaddr($second_nodes->[1]->router),
        'the second snapshot independently reuses its one completed child identity');

    my $immutable = PAGI::Routing::Router->new(routes => []);
    my $immutable_parent = PAGI::App::Router::Builder->new;
    $immutable_parent->mount('/one', router => $immutable)->name('one');
    $immutable_parent->mount('/two', router => $immutable)->name('two');
    my $immutable_nodes = $immutable_parent->to_router->routes;
    is([map { refaddr($_->router) } @$immutable_nodes],
        [refaddr($immutable), refaddr($immutable)],
        'immutable Router inputs retain their original identity at every placement');
};

subtest 'active mutable revisits report the placement chain and clean up' => sub {
    my $a = PAGI::App::Router::Builder->new;
    return unless router_methods_exist($a);
    my $b = PAGI::App::Router::Builder->new;
    $a->mount('/b', router => $b)->name('b');
    $b->mount('/a', router => $a)->name('a');

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
    my $app = $builder->to_app;
    is($builder->{to_router_calls}, 1, 'to_app calls to_router exactly once');
    $builder->get('/late' => handler('late'));
    my $client = PAGI::Test::Client->new(app => $app);
    is($client->get('/item')->text, 'item', 'the retained snapshot serves existing routes');
    is($client->get('/late')->status, 404,
        'the compiled app does not observe Builder mutation after to_app');
};

subtest 'one compiled app isolates two in-flight reused-child requests' => sub {
    my (@contexts, @gates);
    my $child = PAGI::App::Router::Builder->new;
    return unless router_methods_exist($child);
    $child->get('/item/{id}' => sub {
        my ($context) = @_;
        push @contexts, $context;
        my $gate = Future->new;
        push @gates, $gate;
        return $gate;
    })->name('show');
    my $parent = PAGI::App::Router::Builder->new;
    $parent->mount('/left', router => $child)->name('left');
    $parent->mount('/right', router => $child)->name('right');
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
    is([$contexts[0]->path_for('show'), $contexts[1]->path_for('show')],
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

    $gates[0]->done($contexts[0]->text('left one'));
    $gates[1]->done($contexts[1]->text('right two'));
    $left->get;
    $right->get;
    is(response_body(\@left_events), 'left one',
        'the first in-flight request completes with its own response');
    is(response_body(\@right_events), 'right two',
        'the second in-flight request completes with its own response');
};

done_testing;
