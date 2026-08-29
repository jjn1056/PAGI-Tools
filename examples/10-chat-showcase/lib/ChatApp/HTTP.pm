package ChatApp::HTTP;

use strict;
use warnings;

use Future;
use Future::AsyncAwait;
use JSON::MaybeXS;
use PAGI::App::File;
use PAGI::App::Router;
use PAGI::Compose qw(compose);

use ChatApp::State qw(
    get_all_rooms get_room get_room_messages get_room_users get_stats
);

my $JSON = JSON::MaybeXS->new->utf8->canonical;
my $STATIC_APP = PAGI::App::File->from_app_path('public')->to_app;

# API Handlers
sub _rooms_handler {
    return async sub {
        my ($scope, $receive, $send) = @_;
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
        await _send_json($send, 200, $data);
    };
}

sub _room_history_handler {
    return async sub {
        my ($scope, $receive, $send) = @_;
        my $room_name = $scope->{path_params}{name};
        my $room = get_room($room_name);
        if ($room) {
            my $data = get_room_messages($room_name, 100);
            await _send_json($send, 200, $data);
        } else {
            await _send_json($send, 404, { error => 'Room not found' });
        }
    };
}

sub _room_users_handler {
    return async sub {
        my ($scope, $receive, $send) = @_;
        my $room_name = $scope->{path_params}{name};
        my $room = get_room($room_name);
        if ($room) {
            my $data = get_room_users($room_name);
            await _send_json($send, 200, $data);
        } else {
            await _send_json($send, 404, { error => 'Room not found' });
        }
    };
}

sub _stats_handler {
    return async sub {
        my ($scope, $receive, $send) = @_;
        my $data = get_stats();
        await _send_json($send, 200, $data);
    };
}

async sub _send_json {
    my ($send, $status, $data) = @_;
    my $body = $JSON->encode($data);
    await $send->({
        type    => 'http.response.start',
        status  => $status,
        headers => [
            ['content-type', 'application/json; charset=utf-8'],
            ['content-length', length($body)],
            ['cache-control', 'no-cache'],
        ],
    });
    await $send->({
        type => 'http.response.body',
        body => $body,
        more => 0,
    });
}

sub handler {
    my $router = PAGI::App::Router->new;

    # API routes
    $router->get('/api/rooms', raw => _rooms_handler());
    $router->get('/api/room/{name}/history', raw => _room_history_handler());
    $router->get('/api/room/{name}/users', raw => _room_users_handler());
    $router->get('/api/stats', raw => _stats_handler());

    my $api_app = compose(app => $router)->to_app;

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
- **GET /api/room/{name}/history** - Returns message history for a room. The `{name}` path parameter is captured by the router and available in `$scope->{path_params}{name}`.
- **GET /api/room/{name}/users** - Returns list of users in a room.
- **GET /api/stats** - Returns server statistics.

# SEE ALSO

PAGI::App::Router
