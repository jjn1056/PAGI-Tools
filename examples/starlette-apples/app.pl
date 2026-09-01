#!/usr/bin/env perl
use v5.40;

use Future::AsyncAwait;
use Types::Standard qw(Int);

use AppleApp::Middleware qw(with_apples_api_header);
use AppleApp::Model qw(apple_model);
use PAGI::Compose qw(compose);
use PAGI::Pages qw(welcome not_found);
use PAGI::Response qw(file_response json_response);
use PAGI::Routing qw(route mount middleware);
use PAGI::Routing::URL qw(url_for path_for);
use PAGI::Utils qw(app_path);

my $manager_file = app_path('public', 'index.html');

sub startup($state, $scope) {
    $state->{apples} = apple_model();
    return;
}

sub apples($request) {
    my $state = $request->state
        or die 'starlette-apples requires Compose lifespan state';
    return $state->get('apples');
}

async sub list_apples($request) {
    my $apples = apples($request);

    return json_response([
        map {
            +{
                %$_,
                url => url_for(
                    $request,
                    'read',
                    { apple_id => $_->{id} },
                ),
            }
        } @{$apples->all}
    ]);
}

async sub read_apple($request) {
    my $id = $request->path_param('apple_id');
    my $apple = apples($request)->find($id);

    return json_response($apple) if $apple;
    return json_response(
        { error => 'Apple not found' },
        status => 404,
    );
}

async sub create_apple($request) {
    my $data = await $request->json;
    my $apple = apples($request)->create($data);

    return json_response(
        $apple,
        status  => 201,
        headers => [
            Location => path_for(
                $request,
                'read',
                { apple_id => $apple->{id} },
            ),
        ],
    );
}

async sub update_apple($request) {
    my $id = $request->path_param('apple_id');
    my $apples = apples($request);

    return json_response(
        { error => 'Apple not found' },
        status => 404,
    ) unless $apples->find($id);

    my $data = await $request->json;
    my $apple = $apples->update($id, $data);

    return json_response(
        { error => 'Apple not found' },
        status => 404,
    ) unless $apple;

    return json_response($apple);
}

async sub delete_apple($request) {
    my $id = $request->path_param('apple_id');
    my $apple = apples($request)->delete($id);

    return json_response(
        { error => 'Apple not found' },
        status => 404,
    ) unless $apple;

    return json_response({
        success => \1,
        deleted => $apple,
    });
}

compose(
    routes => [
        route('/' => file_response($manager_file, inline => 1),
            name => 'home',
            desc => 'Apple manager SPA',
        ),
        route('/welcome' => welcome(),
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
            name       => 'apples',
            middleware => [middleware(\&with_apples_api_header)],
        ),
    ],
    http_default => not_found(
        detail => 'That page does not exist in the Apple demo.',
    ),
    middleware => [middleware('RequestId')],
    lifespan => { startup => \&startup },
    desc     => 'Starlette apples comparison application',
);
