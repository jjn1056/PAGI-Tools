package ChatApp::HTTP;

use strict;
use warnings;

use Future;
use Future::AsyncAwait;
use JSON::MaybeXS;
use PAGI::App::File;

use ChatApp::State qw(
    get_all_rooms get_room get_room_messages get_room_users get_stats
);

my $JSON = JSON::MaybeXS->new->utf8->canonical;
my $STATIC_APP = PAGI::App::File->app_path('public')->to_app;

sub handler {
    return async sub  {
        my ($scope, $receive, $send) = @_;
        my $path = $scope->{path} // '/';
        my $method = $scope->{method} // 'GET';

        # Route API requests
        if ($path =~ m{^/api/}) {
            return await _handle_api($scope, $receive, $send, $path, $method);
        }

        # Delegate every non-API request to the shared file application
        return await Future->wrap($STATIC_APP->($scope, $receive, $send));
    };
}

async sub _handle_api {
    my ($scope, $receive, $send, $path, $method) = @_;

    my ($status, $data);

    if ($path eq '/api/rooms' && $method eq 'GET') {
        my $rooms = get_all_rooms();
        $data = [
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
        $status = 200;
    }
    elsif ($path =~ m{^/api/room/([^/]+)/history$} && $method eq 'GET') {
        my $room_name = $1;
        my $room = get_room($room_name);
        if ($room) {
            $data = get_room_messages($room_name, 100);
            $status = 200;
        } else {
            $data = { error => 'Room not found' };
            $status = 404;
        }
    }
    elsif ($path =~ m{^/api/room/([^/]+)/users$} && $method eq 'GET') {
        my $room_name = $1;
        my $room = get_room($room_name);
        if ($room) {
            $data = get_room_users($room_name);
            $status = 200;
        } else {
            $data = { error => 'Room not found' };
            $status = 404;
        }
    }
    elsif ($path eq '/api/stats' && $method eq 'GET') {
        $data = get_stats();
        $status = 200;
    }
    else {
        $data = { error => 'Not found' };
        $status = 404;
    }

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

1;

__END__

# NAME

ChatApp::HTTP - HTTP request handler for the chat application

# DESCRIPTION

Handles HTTP requests including API endpoints. Every non-API request is
delegated to one PAGI::App::File rooted at the component's public directory.

## API Endpoints

- **GET /api/rooms** - Returns list of all rooms with user counts.
- **GET /api/room/{name}/history** - Returns message history for a room.
- **GET /api/room/{name}/users** - Returns list of users in a room.
- **GET /api/stats** - Returns server statistics.
