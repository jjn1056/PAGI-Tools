#!/usr/bin/env perl
use v5.40;

use Future::AsyncAwait;
use List::Util qw(max);
use Types::Standard qw(Int);

use PAGI::Compose qw(compose);
use PAGI::Pages;
use PAGI::Routing qw(router route mount);

my %apples_db = (
    1 => { id => 1, name => 'Gala',       color => 'Red/Yellow' },
    2 => { id => 2, name => 'Honeycrisp', color => 'Rosy Red' },
);

async sub list_apples($c) {
    my @ids = sort { $a <=> $b } keys %apples_db;
    return $c->json([map { $apples_db{$_} } @ids]);
}

async sub read_apple($c) {
    my $apple_id = $c->path_param('apple_id');
    my $apple = $apples_db{$apple_id};
    return $c->json($apple) if $apple;
    return $c->json({ error => 'Apple not found' }, status => 404);
}

async sub create_apple($c) {
    my $data = await $c->request->json;
    my $new_id = max(0, keys %apples_db) + 1;
    my $new_apple = { id => $new_id, %$data };
    $apples_db{$new_id} = $new_apple;
    return $c->json($new_apple, status => 201);
}

async sub update_apple($c) {
    my $apple_id = $c->path_param('apple_id');
    return $c->json({ error => 'Apple not found' }, status => 404)
        unless exists $apples_db{$apple_id};

    my $data = await $c->request->json;
    $apples_db{$apple_id} = {
        %{$apples_db{$apple_id}},
        %$data,
    };
    return $c->json($apples_db{$apple_id});
}

async sub delete_apple($c) {
    my $apple_id = $c->path_param('apple_id');
    return $c->json({ error => 'Apple not found' }, status => 404)
        unless exists $apples_db{$apple_id};

    my $deleted_apple = delete $apples_db{$apple_id};
    return $c->json({
        success => \1,
        deleted => $deleted_apple,
    });
}

my $apples = router(
    routes => [
        route('/' => \&list_apples,
            methods => ['GET'], name => 'list', desc => 'List apples'),
        route('/' => \&create_apple,
            methods => ['POST'], name => 'create', desc => 'Create an apple'),
        route('/{apple_id:&Int}' => \&read_apple,
            methods => ['GET'], name => 'read', desc => 'Read an apple'),
        route('/{apple_id:&Int}' => \&update_apple,
            methods => ['PUT'], name => 'update', desc => 'Update an apple'),
        route('/{apple_id:&Int}' => \&delete_apple,
            methods => ['DELETE'], name => 'delete', desc => 'Delete an apple'),
    ],
    desc => 'Apples API',
);

compose(
    routes => [
        route('/' => PAGI::Pages->welcome,
            name => 'home', desc => 'PAGI welcome page'),
        mount('/apples',
            router => $apples,
            name   => 'apples',
            desc   => 'Apples API namespace'),
    ],
)->to_app;
