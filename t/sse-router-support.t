use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use PAGI::SSE;
use PAGI::Stash;
use PAGI::Routing qw(router sse);

my @sent;
my $send = sub {
    my ($msg) = @_;
    push @sent, $msg;
    return Future->done;
};

my $disconnected = 0;
my $receive = sub {
    if ($disconnected) {
        return Future->done({ type => 'sse.disconnect' });
    }
    # Return a future that never resolves (simulates waiting)
    return Future->new;
};

subtest 'stash accessor' => sub {
    my $scope = {
        type    => 'sse',
        path    => '/events',
        headers => [],
    };
    my $sse = PAGI::SSE->new($scope, $receive, $send);
    my $stash = PAGI::Stash->new($sse);

    is($stash->data, {}, 'stash returns empty hashref by default');

    $stash->set(counter => 0);
    is($stash->get('counter'), 0, 'stash values persist');
};

subtest 'stash lives in scope' => sub {
    my $scope = {
        type    => 'sse',
        path    => '/events',
        headers => [],
    };
    my $sse = PAGI::SSE->new($scope, $receive, $send);
    my $stash = PAGI::Stash->new($sse);

    $stash->set(metrics => { requests => 100 });
    is($stash->get('metrics')->{requests}, 100, 'stash persists values');
    is($scope->{'pagi.stash'}{metrics}{requests}, 100, 'stash lives in scope');
};

subtest 'param and params read from scope' => sub {
    my $scope_with_params = {
        type    => 'sse',
        path    => '/events',
        headers => [],
        path_params => { channel => 'news', format => 'json' },
    };
    my $sse = PAGI::SSE->new($scope_with_params, $receive, $send);

    is($sse->path_param('channel'), 'news', 'param returns route param from scope');
    is($sse->path_param('format'), 'json', 'param returns another param');
    is($sse->path_param('missing'), undef, 'param returns undef for missing');
    is($sse->path_params, { channel => 'news', format => 'json' }, 'params returns all');
};

subtest 'param returns undef when no route params in scope' => sub {
    my $scope = {
        type    => 'sse',
        path    => '/events',
        headers => [],
    };
    my $sse = PAGI::SSE->new($scope, $receive, $send);
    is($sse->path_param('anything'), undef, 'param returns undef when no params');
    is($sse->path_params, {}, 'params returns empty hash when no params');
};

subtest 'Router supplies captures to an ordinary SSE object handler' => sub {
    my @seen;
    my $router = router(routes => [
        sse('/events/{channel}' => sub {
            my ($sse) = @_;
            push @seen, [ref($sse), scalar @_, $sse->path_params];
            return Future->done;
        }),
    ]);

    $router->to_app->(
        { type => 'sse', path => '/events/news', headers => [] },
        sub { Future->done({ type => 'sse.disconnect' }) },
        sub { Future->done },
    )->get;

    is(\@seen, [[
        'PAGI::SSE', 1, { channel => 'news' },
    ]], 'normal SSE routing uses its direct object and shared path_params');
};

done_testing;
