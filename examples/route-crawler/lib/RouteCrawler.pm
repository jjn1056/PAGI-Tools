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
use PAGI::Tools qw(response route websocket);
use PAGI::Utils qw(app_path);
use RouteCrawler::Dungeon;

# Builds the dungeon once, when the application is built. `source` is any
# application with route_table; `seed` fixes where the keys are hidden.
sub prepare_app ($self) {
    $self->{source} //= do {
        require NotesApp;
        my $notes = NotesApp->new;
        $notes->application($notes->composition);
    };
    $self->{dungeon} = RouteCrawler::Dungeon->new(
        source => $self->{source},
        (defined $self->{seed} ? (seed => $self->{seed}) : ()),
    );
    open my $fh, '<:encoding(UTF-8)', app_path('public', 'index.html') or die "index.html: $!";
    $self->{page} = do { local $/; <$fh> };
    return;
}

sub routes ($self) {
    my ($dungeon, $page) = @$self{qw(dungeon page)};
    return [
        route('/' => sub ($request) { response('HTML', $page) }),
        # One game per connection: each line in, one answer out.
        websocket('/play' => async sub ($ws) {
            my $game = $dungeon->new_game;
            await $ws->accept;
            await $ws->send_text($game->intro);
            await $ws->each_text(async sub ($line) {
                await $ws->send_text($game->command($line));
            });
        }),
    ];
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
openapi-notes example, its document included) when the application is
built. C<seed> fixes where the keys are hidden.

=cut
