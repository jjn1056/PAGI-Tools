package ChatApp::HTTP;

# The chat's JSON API. routing() returns an immutable Router that the
# application mounts at /api, so these paths are relative to that prefix.

use strict;
use warnings;

use PAGI::Pages qw(not_found);
use PAGI::Response qw(response);
use PAGI::Routing qw(route router);

use ChatApp::State qw(
    get_all_rooms get_room get_room_messages get_room_users get_stats
);

my @NO_CACHE = (headers => ['Cache-Control' => 'no-cache']);

sub routing {
    return router(
        routes => [
            route('/rooms'                => \&rooms),
            route('/room/{name}/history'  => \&room_history),
            route('/room/{name}/users'    => \&room_users),
            route('/stats'                => \&stats),
        ],
        # Negotiated: HTML for a browser, a problem document for an API client.
        http_default => not_found(detail => 'No API route matched'),
    );
}

sub rooms {
    my ($request) = @_;
    my $rooms = get_all_rooms();
    return response('JSON', [
        map { +{
            name       => $_->{name},
            users      => scalar(keys %{$_->{users}}),
            created_at => $_->{created_at},
        } }
        sort { $a->{name} cmp $b->{name} } values %$rooms
    ], @NO_CACHE);
}

sub room_history {
    my ($request) = @_;
    my $name = $request->path_param('name');
    return not_found(detail => 'Room not found') unless get_room($name);
    return response('JSON', get_room_messages($name, 100), @NO_CACHE);
}

sub room_users {
    my ($request) = @_;
    my $name = $request->path_param('name');
    return not_found(detail => 'Room not found') unless get_room($name);
    return response('JSON', get_room_users($name), @NO_CACHE);
}

sub stats {
    my ($request) = @_;
    return response('JSON', get_stats(), @NO_CACHE);
}

1;

__END__

# NAME

ChatApp::HTTP - the chat's JSON API

# SYNOPSIS

    use PAGI::Routing qw(mount);
    mount('/api', app => ChatApp::HTTP::routing());

# DESCRIPTION

`routing()` returns a Router; each handler takes one PAGI::Request and
returns a Response. An unknown API path, or a room that does not exist, is a
negotiated 404 from PAGI::Pages: HTML for a browser, a problem document when
the client asks for `application/problem+json`.

## API Endpoints

- **GET /api/rooms** - All rooms with user counts.
- **GET /api/room/{name}/history** - A room's message history.
- **GET /api/room/{name}/users** - A room's users.
- **GET /api/stats** - Server statistics.

# SEE ALSO

PAGI::Routing, PAGI::Response, PAGI::Pages
