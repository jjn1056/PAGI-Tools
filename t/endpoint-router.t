use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

# Load the module
my $loaded = eval { require PAGI::Endpoint::Router; 1 };
ok($loaded, 'PAGI::Endpoint::Router loads') or diag $@;

subtest 'basic class structure' => sub {
    ok(PAGI::Endpoint::Router->can('new'), 'has new');
    ok(PAGI::Endpoint::Router->can('to_app'), 'has to_app');
    ok(PAGI::Endpoint::Router->can('stash'), 'has stash');
    ok(PAGI::Endpoint::Router->can('routes'), 'has routes');
    ok(PAGI::Endpoint::Router->can('on_startup'), 'has on_startup');
    ok(PAGI::Endpoint::Router->can('on_shutdown'), 'has on_shutdown');
};

subtest 'stash is a hashref' => sub {
    my $router = PAGI::Endpoint::Router->new;
    is(ref($router->stash), 'HASH', 'stash is hashref');

    $router->stash->{test} = 'value';
    is($router->stash->{test}, 'value', 'stash persists values');
};

subtest 'to_app returns coderef' => sub {
    my $app = PAGI::Endpoint::Router->to_app;
    is(ref($app), 'CODE', 'to_app returns coderef');
};

subtest 'HTTP route with method handler' => sub {
    # Create a test router subclass
    {
        package TestApp::HTTP;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        sub routes {
            my ($self, $r) = @_;
            $r->get('/hello' => 'say_hello');
            $r->get('/users/:id' => 'get_user');
        }

        async sub say_hello {
            my ($self, $req, $res) = @_;
            await $res->text('Hello!');
        }

        async sub get_user {
            my ($self, $req, $res) = @_;
            my $id = $req->param('id');
            await $res->json({ id => $id });
        }
    }

    my $app = TestApp::HTTP->to_app;

    # Test /hello
    (async sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'http.request', body => '' }) };

        my $scope = {
            type   => 'http',
            method => 'GET',
            path   => '/hello',
            headers => [],
        };

        await $app->($scope, $receive, $send);

        is($sent[0]{status}, 200, '/hello returns 200');
        is($sent[1]{body}, 'Hello!', '/hello returns Hello!');
    })->()->get;

    # Test /users/:id
    (async sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'http.request', body => '' }) };

        my $scope = {
            type   => 'http',
            method => 'GET',
            path   => '/users/42',
            headers => [],
        };

        await $app->($scope, $receive, $send);

        is($sent[0]{status}, 200, '/users/42 returns 200');
        like($sent[1]{body}, qr/"id".*"42"/, 'body contains user id');
    })->()->get;
};

subtest 'WebSocket route with method handler' => sub {
    {
        package TestApp::WS;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        sub routes {
            my ($self, $r) = @_;
            $r->websocket('/ws/echo/:room' => 'echo_handler');
        }

        async sub echo_handler {
            my ($self, $ws) = @_;

            # Check we got a PAGI::WebSocket
            die "Expected PAGI::WebSocket" unless $ws->isa('PAGI::WebSocket');

            # Check route params work
            my $room = $ws->param('room');
            die "Expected room param" unless $room eq 'test-room';

            await $ws->accept;
        }
    }

    my $app = TestApp::WS->to_app;

    (async sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'websocket.disconnect' }) };

        my $scope = {
            type    => 'websocket',
            path    => '/ws/echo/test-room',
            headers => [],
        };

        await $app->($scope, $receive, $send);

        is($sent[0]{type}, 'websocket.accept', 'WebSocket was accepted');
    })->()->get;
};

subtest 'SSE route with method handler' => sub {
    {
        package TestApp::SSE;
        use parent 'PAGI::Endpoint::Router';
        use Future::AsyncAwait;

        sub routes {
            my ($self, $r) = @_;
            $r->sse('/events/:channel' => 'events_handler');
        }

        async sub events_handler {
            my ($self, $sse) = @_;

            die "Expected PAGI::SSE" unless $sse->isa('PAGI::SSE');

            my $channel = $sse->param('channel');
            die "Expected channel param" unless $channel eq 'news';

            await $sse->send_event(event => 'connected', data => { channel => $channel });
        }
    }

    my $app = TestApp::SSE->to_app;

    (async sub {
        my @sent;
        my $send = sub { push @sent, $_[0]; Future->done };
        my $receive = sub { Future->done({ type => 'sse.disconnect' }) };

        my $scope = {
            type    => 'sse',
            path    => '/events/news',
            headers => [],
        };

        await $app->($scope, $receive, $send);

        ok(scalar @sent > 0, 'SSE sent events');
    })->()->get;
};

done_testing;
