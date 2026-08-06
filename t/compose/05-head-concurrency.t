use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);
use FindBin qw($Bin);
use lib "$Bin/lib";
use ComposeTest qw(scope run_scope capture_send);
use PAGI::Compose qw(compose);
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

subtest 'application middleware derives HEAD headers from the full body' => sub {
    my $raw = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'representation', more => 0 });
    };
    my $app = compose(
        app => $raw,
        middleware => [middleware('ContentLength')],
    )->to_app;
    my $get = run_scope($app, scope(method => 'GET'));
    my $head = run_scope($app, scope(method => 'HEAD'));
    is(response_header($get, 'Content-Length'), 14, 'GET length is calculated');
    is(response_header($head, 'Content-Length'), 14, 'HEAD retains GET-equivalent length');
    is(response_bodies($head), [
        { type => 'http.response.body', body => '', more => 0 },
    ], 'wire receives one empty terminal body');
};

subtest 'an explicit HEAD route can avoid its expensive GET sibling' => sub {
    my @called;
    my $app = compose(routes => [
        route('/resource' => sub {
            push @called, ['head', $_[0]->request->method];
            return $_[0]->response->header('x-source' => 'head')->text('');
        }, methods => 'HEAD'),
        route('/resource' => sub {
            push @called, ['get', $_[0]->request->method];
            return $_[0]->text('expensive representation');
        }, methods => 'GET'),
    ])->to_app;
    my $events = run_scope($app, scope(method => 'HEAD', path => '/resource'));
    is(\@called, [['head', 'HEAD']], 'declaration-ordered explicit HEAD runs alone');
    is(response_header($events, 'x-source'), 'head', 'custom HEAD metadata survives');
    is(response_bodies($events), [
        { type => 'http.response.body', body => '', more => 0 },
    ], 'outer boundary remains terminal');
};

subtest 'one Compose owner covers a separately compiled router' => sub {
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
    ], 'nested router recognizes the existing owner');
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

    $send_for{'/one'}->({ type => 'http.response.body', body => 'one' })->get;
    $send_for{'/two'}->({ type => 'http.response.body', body => 'two' })->get;
    is($events_one, [{ type => 'http.response.body', body => '', more => 0 }], 'first request terminates');
    is($events_two, [{ type => 'http.response.body', body => '', more => 0 }], 'second request has independent terminal state');
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
