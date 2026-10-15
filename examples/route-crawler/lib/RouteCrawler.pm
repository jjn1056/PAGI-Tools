package RouteCrawler;

# A text adventure played over a WebSocket, whose dungeon is another
# application's route_table: by default the openapi-notes example.
#
# Run (from the distribution root):
#   pagi-server --lib lib -I examples/route-crawler/lib -I examples/openapi-notes/lib \
#       --app examples/route-crawler/lib/RouteCrawler.pm --port 5000
# Play: http://localhost:5000/

use v5.40;
use parent 'PAGI::App::Compose';
use Future::AsyncAwait;
use PAGI::State qw(app_state per_request singleton);
use PAGI::Tools qw(response route websocket);
use PAGI::Utils qw(app_path);
use RouteCrawler::Dungeon;

# What the game needs lives in application state, each with its lifetime:
# the dungeon and the page once per worker, a game per WebSocket connection
# (a connection is one request). `source` is any application with
# route_table, by default openapi-notes; `seed` fixes where keys are hidden.
sub on_startup ($self, $state, $scope) {
    my @seed = defined $self->{seed} ? (seed => $self->{seed}) : ();
    $state->{dungeon} = singleton { RouteCrawler::Dungeon->new(source => $self->{source} // _notes(), @seed) };
    $state->{game}    = per_request { my ($state) = @_; $state->get('dungeon')->new_game };
    $state->{page}    = singleton { _read(app_path('public', 'index.html')) };
    app_state($scope)->get('dungeon');    # built now, so a bad source fails at startup
    return;
}

sub routes ($self) {
    return [
        route('/' => sub ($request) { response('HTML', $request->state->get('page')) }),
        # Each line in, one answer out, from this connection's own game.
        websocket('/play' => async sub ($ws) {
            my $game = $ws->state->get('game');
            await $ws->accept;
            await $ws->send_text($game->intro);
            await $ws->each_text(async sub ($line) {
                await $ws->send_text($game->command($line));
            });
        }),
    ];
}

sub _notes {
    require NotesApp;
    my $notes = NotesApp->new;
    return $notes->application($notes->composition);
}

sub _read ($path) {
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return scalar <$fh>;
}

__PACKAGE__->run_if_script;

__END__

=head1 NAME

RouteCrawler - a text adventure whose dungeon is an application's routes

=head1 SYNOPSIS

    pagi-server --lib lib -I examples/route-crawler/lib -I examples/openapi-notes/lib \
        --app examples/route-crawler/lib/RouteCrawler.pm --port 5000

    my $app = RouteCrawler->new(source => $some_compose, seed => 7)->to_app;

=head1 DESCRIPTION

A L<PAGI::App::Compose>: C<GET /> is a terminal-style page, and the
C</play> WebSocket plays one game per connection, sending the answer to each
line it receives. The dungeon is built by L<RouteCrawler::Dungeon> from
C<source> (any application with C<route_table>; by default the
openapi-notes example, its document included). C<seed> fixes where the keys
are hidden.

Everything the game needs is declared in application state at lifespan
startup, with its lifetime (L<PAGI::State/LIFETIMES>): the dungeon and the
page are singletons, and the game is C<per_request> -- on a WebSocket a
request is the connection, so each connection plays its own game. The
dungeon is built at startup, so a source it cannot be built from fails
there.

=cut
