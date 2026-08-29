#!/usr/bin/env perl
use v5.40;

use Future::AsyncAwait;
use List::Util qw(max);
use Types::Standard qw(Int);

use PAGI::Compose qw(compose);
use PAGI::Pages qw(welcome_page not_found_page);
use PAGI::Response qw(file_response json_response);
use PAGI::Routing qw(route mount router request_app);
use PAGI::Routing::URL qw(url_for path_for);
use PAGI::Utils qw(app_path);

my $manager_file = app_path('public', 'index.html');

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

    return json_response([
        map {
            +{
                %{$db->{$_}},
                url => url_for(
                    $request,
                    'read',
                    { apple_id => $_ },
                ),
            }
        } sort { $a <=> $b } keys %$db
    ]);
}

async sub read_apple($request) {
    my $id = $request->path_param('apple_id');
    my $apple = apples_db($request)->{$id};

    return json_response($apple) if $apple;
    return json_response(
        { error => 'Apple not found' },
        status => 404,
    );
}

async sub create_apple($request) {
    my $db = apples_db($request);
    my $data = await $request->json;
    my $id = max(0, keys %$db) + 1;
    my $apple = { id => $id, %$data };
    $db->{$id} = $apple;

    return json_response(
        $apple,
        status  => 201,
        headers => [
            Location => path_for(
                $request,
                'read',
                { apple_id => $id },
            ),
        ],
    );
}

async sub update_apple($request) {
    my $db = apples_db($request);
    my $id = $request->path_param('apple_id');

    return json_response(
        { error => 'Apple not found' },
        status => 404,
    ) unless exists $db->{$id};

    my $data = await $request->json;
    $db->{$id} = { %{$db->{$id}}, %$data };
    return json_response($db->{$id});
}

async sub delete_apple($request) {
    my $db = apples_db($request);
    my $id = $request->path_param('apple_id');

    return json_response(
        { error => 'Apple not found' },
        status => 404,
    ) unless exists $db->{$id};

    return json_response({
        success => \1,
        deleted => delete $db->{$id},
    });
}

sub root_not_found($request) {
    return not_found_page(
        $request,
        detail => 'That page does not exist in the Apple demo.',
    );
}

compose(
    app => router(
        routes => [
            route('/' => file_response($manager_file, inline => 1),
                name => 'home',
                desc => 'Apple manager SPA',
            ),
            route('/welcome' => \&welcome_page,
                name => 'welcome',
                desc => 'PAGI welcome page',
            ),
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
                desc => 'Apples API namespace',
            ),
        ],
        http_default => request_app(\&root_not_found),
    ),
    lifespan => { startup => \&startup },
);
