use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use PAGI::Middleware::Stash;
use PAGI::Stash qw(stash);
use PAGI::Test::Client;
use PAGI::Tools qw(compose middleware response route);

# The Stash middleware gives everything below it one shared stash, so a
# value a handler stores is seen by every layer between the middleware and
# the handler, including after the handler returns, whatever scope copies
# those layers make.

my $handler = async sub {
    my ($scope, $receive, $send) = @_;
    stash($scope)->set(user => 'alice');
    await $send->({ type => 'http.response.start', status => 200, headers => [] });
    await $send->({ type => 'http.response.body', body => 'ok' });
};
# A middleware that hands its app a copy of the scope, as middleware do.
my $copying = sub {
    my ($app) = @_;
    async sub { my ($scope, @rest) = @_; await $app->({ %$scope, 'x.copied' => 1 }, @rest) };
};
# A layer that reads the stash after its app returns, as a logger would.
my %seen;
my $reader = sub {
    my ($app) = @_;
    async sub {
        my ($scope, @rest) = @_;
        await $app->($scope, @rest);
        $seen{user} = ($scope->{'pagi.stash'} // {})->{user} // 'not visible';
    };
};

subtest 'a layer below the middleware sees what the handler stored' => sub {
    %seen = ();
    my $res = PAGI::Test::Client->new(app => $reader->($copying->($handler)))->get('/');
    is $res->status, 500, 'without it, there is no stash, and the handler dies';
    like $res->exception, qr/\APAGI::Stash: this scope has no stash; stack middleware\('Stash'\) above this layer/,
        'naming the middleware';

    %seen = ();
    my $app = PAGI::Middleware::Stash->new->wrap($reader->($copying->($handler)));
    is(PAGI::Test::Client->new(app => $app)->get('/')->text, 'ok', 'the request is answered');
    is $seen{user}, 'alice', 'with it above the reader, the reader sees it';
};

subtest 'in a Compose middleware list' => sub {
    my $logged;
    my $app = compose(
        routes => [route('/' => sub { my ($req) = @_; stash($req)->set(user => 'bob'); response('Text', 'ok') })],
        middleware => [
            middleware('Stash'),
            middleware(sub {
                my ($app) = @_;
                async sub { my ($scope, @rest) = @_; await $app->($scope, @rest); $logged = stash($scope)->get('user', '-') };
            }),
        ],
    );
    PAGI::Test::Client->new(app => $app)->get('/');
    is $logged, 'bob', 'a middleware listed after it reads the route\'s value';
};

subtest 'a stash that already exists is kept' => sub {
    my $outer = {};
    my $app = PAGI::Middleware::Stash->new->wrap(PAGI::Middleware::Stash->new->wrap($handler));
    my $seeding = async sub { my ($scope, @rest) = @_; await $app->({ %$scope, 'pagi.stash' => $outer }, @rest) };
    PAGI::Test::Client->new(app => $seeding)->get('/');
    is $outer, { user => 'alice' }, 'two of them, inside an earlier stash, all share that one';
};

subtest 'each request gets its own stash' => sub {
    my @stashes;
    my $app = PAGI::Middleware::Stash->new->wrap(async sub {
        my ($scope, $receive, $send) = @_;
        push @stashes, $scope->{'pagi.stash'};
        stash($scope)->set(count => (stash($scope)->get('count', 0) + 1));
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => stash($scope)->get('count') });
    });
    my $client = PAGI::Test::Client->new(app => $app);
    is [map { $client->get('/')->text } 1 .. 2], [1, 1], 'nothing carries over';
    ok $stashes[0] != $stashes[1], 'two different hashes';
};

subtest 'a WebSocket connection gets one; lifespan does not' => sub {
    my %got;
    my $app = PAGI::Middleware::Stash->new->wrap(async sub {
        my ($scope, $receive, $send) = @_;
        $got{ $scope->{type} } = ref $scope->{'pagi.stash'};
        if ($scope->{type} eq 'lifespan') {
            while (1) {
                my $event = await $receive->();
                await $send->({ type => "$event->{type}.complete" });
                return if $event->{type} eq 'lifespan.shutdown';
            }
        }
        await $receive->();
        await $send->({ type => 'websocket.accept' });
        await $receive->();
    });
    PAGI::Test::Client->run($app, sub { my ($client) = @_; $client->websocket('/')->close });
    is \%got, { websocket => 'HASH', lifespan => '' }, 'by scope type';
};

done_testing;
