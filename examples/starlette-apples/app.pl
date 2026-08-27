#!/usr/bin/env perl
use v5.40;

use Future::AsyncAwait;
use List::Util qw(max);
use Types::Standard qw(Int);

use PAGI::Compose qw(compose);
use PAGI::Pages;
use PAGI::Response;
use PAGI::Routing qw(route mount);
use PAGI::Routing::URL qw(url url_for path_for);

sub startup($state, $scope) {
    $state->{apples_db} = {
        1 => { id => 1, name => 'Gala',       color => 'Red/Yellow' },
        2 => { id => 2, name => 'Honeycrisp', color => 'Rosy Red' },
    };
    return;
}

sub apples_db($request) {
    my $state = $request->state
        or die 'starlette-apples requires Compose lifespan state';
    return $state->get('apples_db');
}

async sub list_apples($request) {
    my $db = apples_db($request);
    my @apples = map {
        +{
            %{$db->{$_}},
            url => url_for($request, 'read', { apple_id => $_ }),
        }
    } sort { $a <=> $b } keys %$db;

    return PAGI::Response->json(\@apples);
}

async sub read_apple($request) {
    my $apple_id = $request->path_param('apple_id');
    my $apple = apples_db($request)->{$apple_id};

    return PAGI::Response->json($apple) if $apple;
    return PAGI::Response->json(
        { error => 'Apple not found' },
        status => 404,
    );
}

async sub create_apple($request) {
    my $db = apples_db($request);
    my $data = await $request->json;
    my $new_id = max(0, keys %$db) + 1;
    my $new_apple = { id => $new_id, %$data };
    $db->{$new_id} = $new_apple;

    my $location = path_for($request, 'read', { apple_id => $new_id });
    return PAGI::Response->json(
        $new_apple,
        status  => 201,
        headers => [Location => $location],
    );
}

async sub update_apple($request) {
    my $db = apples_db($request);
    my $apple_id = $request->path_param('apple_id');
    return PAGI::Response->json(
        { error => 'Apple not found' }, status => 404,
    ) unless exists $db->{$apple_id};

    my $data = await $request->json;
    $db->{$apple_id} = { %{$db->{$apple_id}}, %$data };
    return PAGI::Response->json($db->{$apple_id});
}

async sub delete_apple($request) {
    my $db = apples_db($request);
    my $apple_id = $request->path_param('apple_id');
    return PAGI::Response->json(
        { error => 'Apple not found' }, status => 404,
    ) unless exists $db->{$apple_id};

    my $deleted_apple = delete $db->{$apple_id};
    return PAGI::Response->json({
        success => \1,
        deleted => $deleted_apple,
    });
}

compose(
    routes => [
        route('/' => PAGI::Pages->welcome,
            name => 'home', desc => 'PAGI welcome page'),
        mount('/apples',
            routes => [
                route('/' => \&list_apples,
                    methods => ['GET'], name => 'list'),
                route('/' => \&create_apple,
                    methods => ['POST'], name => 'create'),
                route('/{apple_id:&Int}' => \&read_apple,
                    methods => ['GET'], name => 'read'),
                route('/{apple_id:&Int}' => \&update_apple,
                    methods => ['PUT'], name => 'update'),
                route('/{apple_id:&Int}' => \&delete_apple,
                    methods => ['DELETE'], name => 'delete'),
            ],
            name => 'apples',
            desc => 'Apples API namespace'),
    ],
    lifespan => {
        startup => \&startup,
    },
);
