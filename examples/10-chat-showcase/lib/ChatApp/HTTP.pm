package ChatApp::HTTP;

use strict;
use warnings;

use Future;
use Future::AsyncAwait;
use PAGI::App::File;
use PAGI::App::Router;
use PAGI::Compose qw(compose);
use PAGI::Response qw(json_response);

use ChatApp::State qw(
    get_all_rooms get_room get_room_messages get_room_users get_stats
);

my $STATIC_APP = PAGI::App::File->from_app_path('public')->to_app;

# API Handlers
sub _rooms_handler {
    my ($request) = @_;
    my $rooms = get_all_rooms();
    my $data = [
        map {
            {
                name       => $_->{name},
                users      => scalar(keys %{$_->{users}}),
                created_at => $_->{created_at},
            }
        }
        sort { $a->{name} cmp $b->{name} }
        values %$rooms
    ];
    return json_response($data, headers => ['Cache-Control' => 'no-cache']);
}

sub _room_history_handler {
    my ($request) = @_;
    my $room_name = $request->path_param('name');
    my $room = get_room($room_name);
    return json_response(
        get_room_messages($room_name, 100),
        headers => ['Cache-Control' => 'no-cache'],
    ) if $room;
    return json_response(
        { error => 'Room not found' },
        status => 404, headers => ['Cache-Control' => 'no-cache'],
    );
}

sub _room_users_handler {
    my ($request) = @_;
    my $room_name = $request->path_param('name');
    my $room = get_room($room_name);
    return json_response(
        get_room_users($room_name),
        headers => ['Cache-Control' => 'no-cache'],
    ) if $room;
    return json_response(
        { error => 'Room not found' },
        status => 404, headers => ['Cache-Control' => 'no-cache'],
    );
}

sub _stats_handler {
    my ($request) = @_;
    return json_response(
        get_stats(), headers => ['Cache-Control' => 'no-cache'],
    );
}

sub handler {
    my $router = PAGI::App::Router->new;

    # API routes
    $router->get('/api/rooms' => \&_rooms_handler);
    $router->get('/api/room/{name}/history' => \&_room_history_handler);
    $router->get('/api/room/{name}/users' => \&_room_users_handler);
    $router->get('/api/stats' => \&_stats_handler);

    my $api_app = compose(router => $router->to_router)->to_app;

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $path = $scope->{path} // '/';

        # Route API requests through router
        if ($path =~ m{^/api/}) {
            return await $api_app->($scope, $receive, $send);
        }

        # Delegate every non-API request to the shared file application
        return await Future->wrap($STATIC_APP->($scope, $receive, $send));
    };
}

1;

__END__

# NAME

ChatApp::HTTP - HTTP request handler for the chat application

# DESCRIPTION

Handles HTTP requests including static file serving and API endpoints.
Uses the mutable PAGI::App::Router verb-method builder for API routing and
shared Pattern capture. Every non-API request is delegated to one
PAGI::App::File rooted at the component's public directory.

## API Endpoints

- **GET /api/rooms** - Returns list of all rooms with user counts.
- **GET /api/room/{name}/history** - Returns message history for a room. The `{name}` path parameter is captured by the router and available through `$request->path_param('name')`.
- **GET /api/room/{name}/users** - Returns list of users in a room.
- **GET /api/stats** - Returns server statistics.

# SEE ALSO

PAGI::App::Router
