package PAGI::State;

use strict;
use warnings;
use Carp qw(croak);
use Exporter qw(import);
use Scalar::Util qw(blessed);
use PAGI::State::Deferred ();
use PAGI::Utils::Scope ();
use overload '%{}' => '_deprecated_hashref', fallback => 1;

our @EXPORT = ();
our @EXPORT_OK = qw(app_state singleton per_request factory);
our %EXPORT_TAGS = (all => [@EXPORT_OK]);

my %WARNED;

# Why a handler's state facade is empty: said by get and data.
my $NO_STATE = 'this scope has no application state '
    . '(did lifespan startup run? PAGI::Test::Client needs lifespan => 1)';

=head1 NAME

PAGI::State - Strict read-oriented access to application state

=head1 SYNOPSIS

    use PAGI::State qw(app_state);

    my $state = app_state($scope);
    my $state = app_state($request);
    my $state = app_state($ws);          # PAGI::WebSocket
    my $state = app_state($event_stream); # PAGI::SSE
    my $db = $state->get('db');
    my $optional = $state->get('optional', undef);

Values built on first use, for as long as they should live (see
L</LIFETIMES>):

    use PAGI::State qw(singleton per_request factory);

    # in lifespan startup
    $state->{db}     = singleton { my ($state) = @_; MyDB->connect };          # a Future
    $state->{viewer} = per_request async sub ($state, $request) {
        my $db = await $state->get('db');
        await $db->user_by_token($request->cookie('token'));
    };
    $state->{form}   = factory { my ($state) = @_; MyForm->new };

    # in a handler
    my $viewer = await $request->state->get('viewer');

=head1 DESCRIPTION

C<PAGI::State> wraps the optional C<< $scope->{state} >> hash with strict,
read-oriented access. Malformed present state is rejected. The raw backing
hash remains available through L</data> when an integration requires it.

Without application state, C<app_state> and C<new> return C<undef>, for
integrations that must tell. The C<state> accessor of L<PAGI::Request>,
L<PAGI::WebSocket> and L<PAGI::SSE> returns an empty facade instead, whose
C<get> and C<data> die naming the likely cause: lifespan startup did not run
(L<PAGI::Test::Client> runs it only with C<< lifespan => 1 >>).

=head1 WRITTEN AT STARTUP, READ THROUGH A FACADE

Lifespan startup writes the raw hash (L<PAGI::Compose>'s
C<< startup => sub { my ($state, $scope) = @_; $state->{db} = ...; } >>);
requests read it through this read-only facade. The asymmetry is deliberate.
Each request scope gets a I<shallow copy> of the state
(L<PAGI::Spec::Lifespan/"Lifespan State">): the values, such as a database
pool, are shared, but a top-level key assigned in one scope changes only that
scope's copy, and every other scope silently keeps its own. So store each
shared object once at startup, mutate it through its reference, and never
assign a top-level key afterwards.

That includes the startup C<$state> itself, kept in a closure: a timer that
later does C<< $state->{count}++ >> or C<< $state->{queue} = [] >> changes
only the lifespan's copy, and request scopes desync. Store a container at
startup and change what is inside it.

Startup may also I<declare> a value instead of building it: see
L</LIFETIMES>.

=head1 LIFETIMES

A value in state can be declared with how long it lives, and built the first
time something asks for it, as a Moo lazy attribute is:

    $state->{db}      = singleton   { my ($state) = @_; ... };
    $state->{viewer}  = per_request { my ($state, $source) = @_; ... };
    $state->{form}    = factory     { my ($state, $source) = @_; ... };

=over 4

=item * C<singleton>: built on the first C<get>, then the same value for the
life of the worker. Each worker runs its own lifespan, so each has its own.

=item * C<per_request>: built on the first C<get> in a request, then the same
value for that request, whichever view asks: a middleware's
C<< app_state($scope) >> and the handler's C<< $request->state >> share it. On
a WebSocket or SSE connection, a request is the connection: the value lives for
the connection and is not refreshed during it. Asked for during lifespan
startup or shutdown, it dies.

=item * C<factory>: built on every C<get>.

=back

Every builder receives C<$state>, a view of the same state through which it
C<get>s what it depends on, in any order. Get other keys through that
C<$state>, never through C<< $source->state >>, which would escape the cycle
check. C<per_request> and C<factory> builders also receive C<$source>, what
the asking view was made from: the L<PAGI::HTTPConnection> for
C<< $conn->state >> (a L<PAGI::Request>, L<PAGI::WebSocket> or L<PAGI::SSE>
in a handler), the scope hashref for C<< app_state($scope) >>. A middleware
that wants its builders to read the request -- its headers, cookies and
query -- asks through C<< PAGI::HTTPConnection->new($scope)->state >>, which
reads the scope without touching the body.

A builder may be a block, a C<sub {...}> or an C<async sub {...}>. In the
middle of a list, a C<sub> or C<async sub> builder takes the rest of the list
as arguments, so parenthesise it there; a block never needs it:

    my %declared = (a => (singleton async sub ($state) { ... }), b => ...);

B<Async builders.> C<get> returns what the builder returns, so an async
builder's value is a L<Future>, which the caller awaits:
C<< my $db = await $request->state->get('db') >>. Forgetting the C<await>
gives a Future where an object was expected, which fails at the first method
call. A pending build is shared: two requests asking at once await one build,
each through a Future of its own, so a caller that goes away (its request is
cancelled) cancels only its own and the build runs on for the others. A build
that fails or is cancelled is not kept: everyone waiting gets the failure, and
the next C<get> builds again. A builder that dies keeps nothing either. A
C<per_request> build still pending when its request goes away is cancelled:
nothing can ask for it again, and its I/O is not wanted.

B<Singletons and requests.> A singleton outlives the request that first asks
for it, so it builds with no request: its builder gets no C<$source>, asking
it for a C<per_request> value dies (it would be kept for the life of the
worker), and a C<factory> it asks for gets no C<$source> either.

B<Cycles.> A builder that, through other builders, asks for its own key while
it is still being built dies naming the chain:
C<State key cycle: a -E<gt> b -E<gt> a>. Inside an async builder that fails
its Future, which also refuses the deadlock of C<a> awaiting C<b> while C<b>
awaits C<a>. A built value may keep the C<$state> its builder got: once the
build has finished, asking through it builds and returns as any view does.

B<Shutdown.> A singleton has C<built>, true once a build has started and has
not failed or been cancelled, and C<value>, what was kept as C<get> gives it.
Close what a request opened without opening it to close it:

    async sub on_shutdown ($self, $state, $scope) {
        (await $state->{db}->value)->disconnect if $state->{db}->built;
    }

Awaiting a build still pending at shutdown holds shutdown until it settles.

L<PAGI::State::Deferred> is the seam: a subclass with its own C<resolve> is
another lifetime, or a bridge to a richer container.

=head1 FUNCTIONS

=head2 app_state

    my $state = app_state($scope);
    my $state = app_state($request);
    my $state = app_state($ws);           # PAGI::WebSocket
    my $state = app_state($event_stream); # PAGI::SSE

Constructs a state facade from an unblessed scope hashref or an object with a
C<scope> method, including L<PAGI::Request>, L<PAGI::WebSocket>, and
L<PAGI::SSE>. This function is an opt-in named export and is also available
through the C<:all> tag. Nothing is exported by default.

=head2 singleton, per_request, factory

    $state->{db} = singleton { my ($state) = @_; ... };

Each takes a builder (a block, C<sub {...}> or C<async sub {...}>) and returns
a L<PAGI::State::Deferred> for lifespan startup to store; see L</LIFETIMES>.
Opt-in exports, also in C<:all>; L<PAGI::Tools> does not re-export them.

=cut

sub app_state { return __PACKAGE__->new(@_) }

sub singleton (&)   { return PAGI::State::Deferred::Singleton->new($_[0]) }
sub per_request (&) { return PAGI::State::Deferred::PerRequest->new($_[0]) }
sub factory (&)     { return PAGI::State::Deferred::Factory->new($_[0]) }

=head1 CONSTRUCTOR

=head2 new

    my $state = PAGI::State->new($scope);

Returns C<undef> when the scope has no C<state> member. A present member must be
an unblessed hashref.

=cut

sub new {
    my ($class, @arguments) = @_;
    my $scope = PAGI::Utils::Scope::scope_from_source($class, @arguments);
    return undef unless exists $scope->{state};
    croak 'PAGI::State requires scope state to be a hashref'
        unless ref($scope->{state}) eq 'HASH';
    # The state, whether it is the empty view, what the view was made from,
    # the scope, whether a singleton builds through it, the keys being built.
    return bless [$scope->{state}, 0, $arguments[0], $scope], $class;
}

# The facade a handler gets on a scope with no application state: empty, and
# its get and data say why.
sub _without_state {
    my ($class) = @_;
    return bless [{}, 1], $class;
}

=head1 METHODS

=head2 get

    my $value = $state->get('required');
    my $value = $state->get('optional', $default);

The one-argument form croaks when the key is absent and lists the available
keys; on the empty facade of a scope with no application state it says so
instead. The two-argument form returns the supplied default for an absent key.

=cut

sub get {
    my ($self, @arguments) = @_;
    croak 'get() requires 1 or 2 arguments'
        if @arguments < 1 || @arguments > 2;
    my ($key, @default) = @arguments;
    my $data = $self->[0];
    if (!exists $data->{$key}) {
        return $default[0] if @default;
        croak "State key '$key' does not exist: $NO_STATE" if $self->[1];
        my @keys = sort $self->keys;
        croak "State key '$key' does not exist. Available keys: "
            . (@keys ? join(', ', @keys) : '(none)');
    }
    my $value = $data->{$key};
    return $value unless blessed($value) && $value->isa('PAGI::State::Deferred');
    my @live = grep { $_->{live} } @{ $self->[5] // [] };
    croak 'State key cycle: ' . join(' -> ', (map { $_->{key} } @live), $key)
        if grep { $_->{key} eq $key } @live;

    # This lookup's link in the chain. A build ties it to itself (see
    # _expire_with); a lookup that builds nothing expires it at once.
    my $link = { key => $key, live => 1 };
    my $result;
    unless (eval { $result = $value->resolve($self->_building($link), $self->[2]); 1 }) {
        $link->{live} = 0;
        die $@;
    }
    $link->{live} = 0 unless $link->{bound};
    return $result;
}

# The key whose builder this view was made for: the end of the chain.
sub _building_key { return $_[0][5][-1]{key} }

# The view a builder works through: the same state, with $link on the chain.
sub _building {
    my ($self, $link) = @_;
    return bless [@{$self}[0 .. 4], [@{ $self->[5] // [] }, $link]], ref $self;
}

# Ties this view's build to the end of its chain: the link expires when the
# build finishes, so a view a built value keeps carries no live chain, while
# a build still running (an async one awaiting) keeps its link and still sees
# a cycle back to it.
sub _expire_with {
    my ($self, $build) = @_;
    my $link = $self->[5] && $self->[5][-1] or return;
    $link->{bound} = 1;
    if (blessed($build) && $build->isa('Future') && !$build->is_ready) {
        $build->on_ready(sub { $link->{live} = 0 });
    }
    else {
        $link->{live} = 0;
    }
    return;
}

# The same state, seen with no request: what a singleton builds through.
sub _without_request {
    my ($self) = @_;
    return bless [$self->[0], $self->[1], undef, $self->[3], 1, $self->[5]], ref $self;
}

# The per-request cache, in the request's copy of the state.
sub _request_cache {
    my ($self) = @_;
    croak 'a per_request value was asked for while building a singleton,'
        . ' which would keep it for the life of the worker'
        if $self->[4];
    croak 'a per_request value was asked for outside a request (lifespan startup or shutdown)'
        if ($self->[3]{type} // '') eq 'lifespan';
    return $self->[0]{'pagi.state.per_request'}
        //= bless {}, 'PAGI::State::Deferred::RequestCache';
}

=head2 exists

Returns true when a key exists in the application state. Keys beginning
C<pagi.state.> are reserved for PAGI::State's own use and are not reported.

=cut

sub exists {
    my ($self, $key) = @_;
    return 0 if $key =~ /\Apagi\.state\./;
    return exists $self->[0]{$key} ? 1 : 0;
}

=head2 keys

Returns the application state keys, without the reserved C<pagi.state.> keys.

=cut

sub keys {
    my ($self) = @_;
    return grep { !/\Apagi\.state\./ } CORE::keys %{$self->[0]};
}

=head2 data

Returns the backing hashref. This is the explicit escape hatch for integrations
that require raw hash access: it holds declared values unresolved (their
L<PAGI::State::Deferred> objects) and the reserved C<pagi.state.> keys. On the empty facade of a scope with no
application state it croaks, naming the likely cause, rather than hand back a
hash that nothing else would see.

=cut

sub data {
    my ($self) = @_;
    croak "State data is unavailable: $NO_STATE" if $self->[1];
    return $self->[0];
}

sub _deprecated_hashref {
    my ($self) = @_;

    if (!defined($ENV{PAGI_SILENCE_STATE_HASHREF_WARNING})
            || $ENV{PAGI_SILENCE_STATE_HASHREF_WARNING} ne '1') {
        my ($package, $file, $line) = _external_callsite();
        my $key = join("\x1e", $package, $file, $line);
        if (!$WARNED{$key}++) {
            warn "Direct hash dereference of PAGI::State is deprecated; use ->get for values or ->data when a raw hashref is required at $file line $line.\n";
        }
    }

    return $self->[0];
}

sub _external_callsite {
    my $level = 1;
    while (my @caller = caller($level++)) {
        next if $caller[0] eq __PACKAGE__ || $caller[0] eq 'overload';
        return @caller[0, 1, 2];
    }
    return ('unknown', 'unknown', 0);
}

=head1 COMPATIBILITY

Legacy C<< $state->{key} >> dereferencing continues to work through hash
overloading and warns once per external package, file, and line. Set
C<PAGI_SILENCE_STATE_HASHREF_WARNING> to exactly C<1> to suppress this warning.
The facade remains an object rather than a real hashref; use L</data> where a
real hashref is required.

=cut

1;

=head1 SEE ALSO

L<PAGI::State::Deferred>, L<PAGI::Request>, L<PAGI::WebSocket>, L<PAGI::SSE>,
L<PAGI::Stash>

=cut
