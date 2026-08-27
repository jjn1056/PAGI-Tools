use strict;
use warnings;
use Future::AsyncAwait;
use PAGI::Compose qw(compose);
use PAGI::Response;
use PAGI::Routing qw(route middleware);

async sub home {
    my ($request) = @_;
    my $state = $request->state
        or die 'compose example requires lifespan state';
    return PAGI::Response->json({
        message => $state->get('message'),
        request_id => $request->scope->{request_id},
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
);
