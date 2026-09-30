use Future::AsyncAwait;
use PAGI::Pages qw(welcome);
use PAGI::Utils qw(handle_lifespan invoke_app);

use warnings;
use strict;

async sub pagi {
    my ( $scope, $receive, $send ) = @_;

    # Handle lifespan events
    return await handle_lifespan(
        $scope, $receive, $send,
        startup  => async sub { my ( $state ) = @_; warn 'doing startup'  },
        shutdown => async sub { my ( $state ) = @_; warn 'doing shutdown' },
    ) if $scope->{type} eq 'lifespan';

    # Rest of app (example)
    die "Unsupported scope type: $scope->{type}" unless $scope->{type} eq 'http';

    return await invoke_app(
        welcome(as => 'text'), $scope, $receive, $send,
    );
}

\&pagi;
