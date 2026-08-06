use strict;
use warnings;
use Future::AsyncAwait;
use PAGI::Compose qw(compose);
use PAGI::Routing qw(route middleware);

async sub home {
    my ($c) = @_;
    return $c->json({
        message => $c->state->{message},
        request_id => $c->scope->{request_id},
    });
}

compose(
    routes => [
        route('/' => \&home, name => 'home', desc => 'Compose demo home'),
    ],
    middleware => [
        middleware('RequestId', generator => sub { return 'compose-demo' }),
    ],
    lifespan => {
        startup => sub {
            my ($state, $scope) = @_;
            $state->{message} = 'ready';
            $state->{started} = 1;
            return;
        },
        shutdown => sub {
            my ($state, $scope) = @_;
            $state->{stopped} = 1;
            return;
        },
    },
)->to_app;
