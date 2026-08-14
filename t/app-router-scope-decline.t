use strict;
use warnings;

use Test2::V0;
use Future;

use PAGI::App::Router;
use PAGI::Routing qw(middleware);
use PAGI::Routing::Trace ();

# HTTP route exhaustion is a normal unanswered routing decline. SSE and
# WebSocket keep their protocol-specific miss behavior.

sub mock_send {
    my @sent;
    my $send = sub { my ($msg) = @_; push @sent, $msg; Future->done };
    return ($send, \@sent);
}

subtest 'unmatched HTTP route completes unanswered with trusted evidence' => sub {
    my $router = PAGI::App::Router->new;
    my $app = $router->to_app;

    my ($scope, $trace) = PAGI::Routing::Trace->_ensure_http_scope({
        type => 'http', method => 'GET', path => '/nope', headers => [],
    });
    my $checkpoint = $trace->checkpoint;
    my ($send, $sent) = mock_send();
    $app->($scope, sub { Future->done }, $send)->get;
    my $snapshot = $trace->snapshot($checkpoint);

    is($sent, [], 'low-level App Router emits no HTTP response events');
    ok($snapshot->routing_declined, 'the compiler records a trusted decline');
    ok(!$snapshot->path_matched, 'the decline records no complete path match');
};

subtest 'unmatched SSE route -> sse.http.response.* 404' => sub {
    my $router = PAGI::App::Router->new;
    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ type => 'sse', path => '/nope' }, sub { Future->done }, $send)->get;

    is $sent->[0]{type},   'sse.http.response.start', 'start event is namespaced for sse';
    is $sent->[0]{status}, 404,                       'status 404';
    is $sent->[1]{type},   'sse.http.response.body',  'body event is namespaced for sse';
    is $sent->[1]{more},   0,                         'body closes the response';
};

subtest 'unmatched WebSocket route with denial extension -> namespaced 404' => sub {
    my $router = PAGI::App::Router->new;
    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({
        type       => 'websocket',
        path       => '/nope',
        extensions => { 'websocket.http.response' => {} },
    }, sub { Future->done }, $send)->get;

    is $sent->[0]{type},   'websocket.http.response.start', 'extension permits custom start';
    is $sent->[0]{status}, 404,                             'status 404';
    is $sent->[1]{type},   'websocket.http.response.body',  'extension permits custom body';
    is $sent->[1]{more},   0,                               'body closes the response';
};

subtest 'unmatched WebSocket route without denial extension -> portable close' => sub {
    my $router = PAGI::App::Router->new;
    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ type => 'websocket', path => '/nope' }, sub { Future->done }, $send)->get;

    is $sent, [{ type => 'websocket.close' }],
        'close before accept asks the server for the spec-defined bare 403';
};

subtest 'custom NotFound middleware is ordinary Router-level policy' => sub {
    my @seen;
    my $not_found = sub {
        my ($c, $trace) = @_;
        push @seen, [ref($c), scalar @_];
        ok($trace->routing_declined, 'custom policy receives the decline snapshot');
        return $c->text('custom missing');
    };
    my $router = PAGI::App::Router->new(
        middleware => [
            middleware('Routing::NotFound', handler => $not_found),
        ],
    );
    my $app = $router->to_app;

    my ($send, $sent) = mock_send();
    $app->({ type => 'http', method => 'GET', path => '/x', headers => [] },
        sub { Future->done }, $send)->get;

    is([$sent->[0]{status}, $sent->[1]{body}], [404, 'custom missing'],
        'the seeded custom HTTP response is emitted by middleware');
    is(\@seen, [['PAGI::Context::HTTP', 2]],
        'the fallback handler receives HTTP Context and routing snapshot');
};

done_testing;
