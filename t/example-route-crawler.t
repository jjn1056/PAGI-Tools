use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../examples/route-crawler/lib";
use lib "$Bin/../examples/openapi-notes/lib";
use PAGI::Test::Client;

# examples/route-crawler: a text adventure whose dungeon is another
# application's route_table -- by default the openapi-notes hero.

BEGIN { plan skip_all => 'examples/route-crawler requires Perl 5.40' if $] < 5.040 }

require NotesApp;
require RouteCrawler::Dungeon;

my $notes   = NotesApp->new;
my $source  = $notes->application($notes->composition);
my $dungeon = RouteCrawler::Dungeon->new(source => $source, seed => 1);

subtest 'the dungeon is built from route_table' => sub {
    is([sort $dungeon->room_paths], ['/', '/notes', '/notes/', '/notes/{id}', '/openapi.json', '/static'],
        'a room per path, the hall, and the archway the paths imply');
    is($dungeon->room('/')->{kind}, 'hall', 'the entrance hall');
    is($dungeon->room('/notes')->{kind}, 'archway', 'a mounted Router is an open archway');
    is($dungeon->room('/openapi.json')->{kind}, 'library', 'the OpenAPI document is the library');
    is([sort keys %{ $dungeon->room('/notes/')->{actions} }], ['get', 'post'],
        "a room's actions are its routes' methods, HEAD folded into GET");
    is($dungeon->room('/notes/{id}')->{actions}{delete}{desc}, 'Delete a note', "an action's desc is its route's");
    is([sort $dungeon->exits('/')], ['/notes', '/openapi.json', '/static'], "the hall's exits");
    is([sort $dungeon->exits('/notes')], ['/', '/notes/', '/notes/{id}'], "the archway's exits");
};

subtest 'locks match Requires scopes' => sub {
    is($dungeon->room('/notes/')->{actions}{post}{lock}, ['notes:write'], 'POST /notes/ needs notes:write');
    is($dungeon->room('/notes/{id}')->{actions}{delete}{lock}, ['notes:write'], 'and so does DELETE');
    is($dungeon->room('/notes/')->{actions}{get}{lock}, [], 'GET is open');
    is([$dungeon->key_names], ['notes:write'], 'one key per scope');
    my $where = $dungeon->key_room('notes:write');
    ok(defined $where, 'the key is hidden somewhere');
    isnt($dungeon->room($where)->{kind}, 'sealed', 'never behind a sealed door');
    ok(!grep({ @{ $_->{lock} } } values %{ $dungeon->room($where)->{actions} }), 'nor in a room it unlocks');
};

subtest 'sealed doors for separate applications' => sub {
    is($dungeon->room('/static')->{kind}, 'sealed', 'a mount entry is a sealed door');
    my $game = $dungeon->new_game;
    like($game->command('go /static'), qr/sealed/i, 'it cannot be opened');
    is($game->where, '/', 'and the player stays put');
};

subtest 'without the key, a lock holds' => sub {
    my $game = $dungeon->new_game;
    $game->command($_) for 'go /notes', 'go /notes/';
    like($game->command('post'), qr/chained.*notes:write/i, 'POST is chained without notes:write');
    like($game->command('read map'), qr/no map/i, 'the map is only in the library');
    like($game->command('dance'), qr/help/i, 'an unknown command points at help');
};

done_testing;
