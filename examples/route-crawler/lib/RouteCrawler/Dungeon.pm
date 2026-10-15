package RouteCrawler::Dungeon;

# The dungeon, built from an application's route_table, and the games played
# in it. Plain Perl: no request, no socket, no event loop.

use v5.40;
use Carp qw(croak);

my %REQUIRES = map { $_ => 1 } qw(Requires PAGI::Middleware::Requires +PAGI::Middleware::Requires);

my %KIND_TEXT = (
    hall    => 'the entrance hall',
    archway => 'an open archway',
    library => 'a library',
    room    => 'a room',
    sealed  => 'a sealed door',
);

sub new ($class, %args) {
    my $source = $args{source};
    croak 'RouteCrawler::Dungeon needs a source application with route_table'
        unless $source && $source->can('route_table');
    my $self = bless { rooms => {}, keys => {}, seed => $args{seed} // int rand 1_000_000 }, $class;

    $self->_room('/', 'hall', 'Passages lead off into the application.');
    for my $entry ($source->route_table) {
        my $path = $entry->template;
        if ($entry->kind eq 'mount') {
            $self->_room($path, 'sealed', 'A separate application lies beyond; you cannot see in.');
            $self->_archways_above($path);
            next;
        }
        my $room = $self->_room($path, $path eq '/openapi.json' ? 'library' : 'room');
        $self->_archways_above($path);
        my $lock = _lock_of($entry);
        for my $action (_actions_of($entry)) {
            $room->{actions}{$action} = { desc => $entry->desc, lock => $lock };
        }
        my $get = $room->{actions}{get};
        $room->{desc} //= $get && defined $get->{desc} ? $get->{desc} : $entry->desc;
    }
    $self->_hide_keys;
    return $self;
}

sub room_paths ($self)    { return sort keys %{ $self->{rooms} } }
sub room ($self, $path)   { return $self->{rooms}{$path} }
sub key_names ($self)     { return sort keys %{ $self->{keys} } }
sub key_room ($self, $k)  { return $self->{keys}{$k} }
sub new_game ($self)      { return RouteCrawler::Game->new($self) }

# The rooms next to one: its parent, and the rooms directly below it.
sub exits ($self, $path) {
    my @exits = grep { $_ ne $path && _parent($_) eq $path } $self->room_paths;
    unshift @exits, _parent($path) unless $path eq '/';
    return @exits;
}

sub kind_text ($self, $path) { return $KIND_TEXT{ $self->{rooms}{$path}{kind} } }

sub _room ($self, $path, $kind, $desc = undef) {
    my $room = $self->{rooms}{$path} //= { path => $path, kind => $kind, actions => {} };
    # A room found later beats the archway a deeper path implied.
    $room->{kind} = $kind if $room->{kind} eq 'archway' && $kind ne 'archway';
    $room->{desc} //= $desc;
    return $room;
}

# A path below another implies the passage to it: an archway, unless a route
# of its own makes it a room.
sub _archways_above ($self, $path) {
    for (my $up = _parent($path); $up ne '/'; $up = _parent($up)) {
        $self->_room($up, 'archway', 'The routes beyond are part of this application.')
            unless $self->{rooms}{$up};
    }
}

sub _parent ($path) {
    return '/' if $path eq '/';
    my ($up) = $path =~ m{\A(.*)/[^/]*\z};
    return length $up ? $up : '/';
}

sub _actions_of ($entry) {
    return ('listen')  if $entry->kind eq 'sse';
    return ('connect') if $entry->kind eq 'websocket';
    my $methods = $entry->methods;
    my @methods = ref $methods ? @$methods : ('ANY');
    my %has = map { $_ => 1 } @methods;
    return map { lc } grep { !($_ eq 'HEAD' && $has{GET}) } @methods;
}

# The scopes every Requires around the route asks for; a Requires with none
# asks only for a logged-in user.
sub _lock_of ($entry) {
    my ($found, %scopes);
    for my $description (@{ $entry->middleware }) {
        my $factory = $description->factory;
        next unless defined $factory && !ref $factory && $REQUIRES{$factory};
        $found = 1;
        my $scopes = $description->config->{scopes};
        $scopes{$_} = 1 for !defined $scopes ? () : ref $scopes ? @$scopes : ($scopes);
    }
    return [] unless $found;
    return %scopes ? [sort keys %scopes] : ['logged-in'];
}

# Each key in a room it does not unlock, never behind a sealed door; the seed
# makes a dungeon repeatable.
sub _hide_keys ($self) {
    my %needed = map { $_ => 1 } map { @{ $_->{lock} } } map { values %{ $_->{actions} } } values %{ $self->{rooms} };
    my @hiding = grep {
        my $room = $self->{rooms}{$_};
        $room->{kind} ne 'sealed' && !grep { @{ $_->{lock} } } values %{ $room->{actions} };
    } $self->room_paths;
    my $i = 0;
    $self->{keys}{$_} = $hiding[ ($self->{seed} + $i++) % @hiding ] for sort keys %needed;
}

package RouteCrawler::Game;

# One player's game: where they are, what they carry, what they have opened.

use v5.40;

my $HELP = 'Commands: look, go <path>, take, inventory, read map, help -- '
    . 'and the actions a room offers (get, post, delete, ...).';

sub new ($class, $dungeon) {
    my %keys = map { $_ => $dungeon->key_room($_) } $dungeon->key_names;
    return bless { dungeon => $dungeon, where => '/', visited => { '/' => 1 },
        carrying => {}, hidden => \%keys, opened => {} }, $class;
}

sub where ($self) { return $self->{where} }

sub intro ($self) {
    return "ROUTE CRAWLER. Every route of an application is a room; find the keys, "
        . "open the locks, see every room you can.\n\n" . $self->look;
}

sub command ($self, $line) {
    $line =~ s/\A\s+|\s+\z//g;
    my ($verb, $rest) = split /\s+/, lc($line) =~ s/\Aread map\z/read_map/r, 2;
    $verb //= '';
    return $self->look         if $verb eq 'look';
    return $self->go($rest)    if $verb eq 'go';
    return $self->take         if $verb eq 'take';
    return $self->inventory    if $verb eq 'inventory';
    return $self->read_map     if $verb eq 'read_map';
    return $HELP               if $verb eq 'help';
    return $self->act($verb)   if exists $self->_room->{actions}{$verb};
    return "You can't do that here. Type help.";
}

sub look ($self) {
    my $dungeon = $self->{dungeon};
    my $room    = $self->_room;
    my @lines   = ("$room->{path}: " . $dungeon->kind_text($room->{path}) . '.');
    push @lines, $room->{desc} if defined $room->{desc};
    my $actions = $room->{actions};
    push @lines, 'Actions: ' . join(', ', map {
        my @needs = @{ $actions->{$_}{lock} };
        @needs && !$self->{opened}{"$room->{path} $_"} ? "$_ (chained: @needs)" : $_;
    } sort keys %$actions) if %$actions;
    push @lines, 'Exits: ' . join(', ', map { "$_ (" . $dungeon->kind_text($_) . ')' } $dungeon->exits($room->{path}));
    my @here = grep { ($self->{hidden}{$_} // '') eq $room->{path} } sort keys %{ $self->{hidden} };
    push @lines, "Something glints here: the key '$_'." for @here;
    return join "\n", @lines;
}

sub go ($self, $path) {
    my $dungeon = $self->{dungeon};
    return 'Go where? Name one of the exits.' unless defined $path && length $path;
    my $to = $dungeon->room($path);
    return "There is no way to $path from here."
        unless $to && grep { $_ eq $path } $dungeon->exits($self->{where});
    return "The door to $path is sealed: a separate application lies beyond, and its routes are its own."
        if $to->{kind} eq 'sealed';
    $self->{where} = $path;
    $self->{visited}{$path} = 1;
    return $self->look;
}

sub take ($self) {
    my @here = grep { ($self->{hidden}{$_} // '') eq $self->{where} } sort keys %{ $self->{hidden} };
    return 'There is nothing here to take.' unless @here;
    for my $key (@here) { delete $self->{hidden}{$key}; $self->{carrying}{$key} = 1 }
    return join "\n", map { "You take the key '$_'." } @here;
}

sub inventory ($self) {
    my @keys = sort keys %{ $self->{carrying} };
    return @keys ? "You carry the keys: @keys." : 'You carry nothing.';
}

sub read_map ($self) {
    my $dungeon = $self->{dungeon};
    return 'There is no map here. Find the library.' unless $self->_room->{kind} eq 'library';
    return join "\n", 'The map shows:',
        map { "  $_ (" . $dungeon->kind_text($_) . ')' . ($self->{visited}{$_} ? ', visited' : '') } $dungeon->room_paths;
}

sub act ($self, $verb) {
    my $room   = $self->_room;
    my $action = $room->{actions}{$verb};
    my $does   = uc($verb) . (defined $action->{desc} ? ": $action->{desc}" : '');
    my @needs  = @{ $action->{lock} };
    return "You $does." unless @needs;

    my @missing = grep { !$self->{carrying}{$_} } @needs;
    return 'The ' . uc($verb) . " lever is chained shut. It needs the key: @missing." if @missing;
    my $first = !$self->{opened}{"$room->{path} $verb"}++;
    my $text  = ($first ? 'The chain falls away. ' : '') . "You $does.";
    return $self->_won ? "$text\n\n*** You have seen every room you can and opened every lock. You win! ***" : $text;
}

sub _room ($self) { return $self->{dungeon}->room($self->{where}) }

sub _won ($self) {
    my $dungeon = $self->{dungeon};
    for my $path ($dungeon->room_paths) {
        my $room = $dungeon->room($path);
        next if $room->{kind} eq 'sealed';
        return 0 unless $self->{visited}{$path};
        for my $verb (keys %{ $room->{actions} }) {
            return 0 if @{ $room->{actions}{$verb}{lock} } && !$self->{opened}{"$path $verb"};
        }
    }
    return 1;
}

1;

__END__

=head1 NAME

RouteCrawler::Dungeon - a text-adventure dungeon built from an application's route_table

=head1 SYNOPSIS

    my $dungeon = RouteCrawler::Dungeon->new(source => $compose, seed => 42);
    my $game    = $dungeon->new_game;
    print $game->intro;
    print $game->command('go /notes');

=head1 DESCRIPTION

Every entry of C<< $source->route_table >> becomes a room at its path
template: a route's methods (HEAD folded into GET), an SSE route's C<listen>
or a WebSocket route's C<connect> are its actions, and its C<desc> describes
it. A C<Requires> on a route chains the action with a key per scope (one
called C<logged-in> for a Requires with none); the keys are hidden in rooms
they do not unlock. Paths imply the passages between rooms: a path with no
route of its own is an open archway, as a mounted Router is. A C<mount> entry
-- a separate application -- is a sealed door. C</openapi.json> is the
library.

=head1 METHODS

=over 4

=item new(source => $application, seed => $n)

C<source> has C<route_table>. C<seed> fixes where the keys are hidden;
without one each dungeon differs.

=item room_paths, room($path), exits($path), kind_text($path)

The rooms' paths; a room's hash (C<path>, C<kind>, C<desc>, C<actions>, each
action's C<desc> and C<lock>); the paths reachable from a room; its kind in
words.

=item key_names, key_room($key)

The keys, and where each is hidden.

=item new_game

A L</RouteCrawler::Game> in this dungeon.

=back

=head1 RouteCrawler::Game

=over 4

=item intro, where, command($line)

The opening text; the player's room; the answer to a command: C<look>,
C<go PATH>, C<take>, C<inventory>, C<read map>, C<help>, or one of the room's
actions. Opening the last lock, with every reachable room seen, wins.

=back

=cut
