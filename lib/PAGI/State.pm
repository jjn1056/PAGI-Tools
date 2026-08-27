package PAGI::State;

use strict;
use warnings;
use Carp qw(croak);
use Exporter qw(import);
use PAGI::Utils::Scope ();
use overload '%{}' => '_deprecated_hashref', fallback => 1;

our @EXPORT = ();
our @EXPORT_OK = qw(app_state);
our %EXPORT_TAGS = (ALL => [@EXPORT_OK]);

my %WARNED;

=head1 NAME

PAGI::State - Strict read-oriented access to application state

=head1 SYNOPSIS

    use PAGI::State qw(app_state);

    my $state = app_state($scope);
    my $db = $state->get('db');
    my $optional = $state->get('optional', undef);

=head1 DESCRIPTION

C<PAGI::State> wraps the optional C<< $scope->{state} >> hash with strict,
read-oriented access. Missing application state returns C<undef>; malformed
present state is rejected. The raw backing hash remains available through
L</data> when an integration requires it.

=head1 FUNCTIONS

=head2 app_state

    my $state = app_state($scope);
    my $state = app_state($request);

Constructs a state facade from an unblessed scope hashref or an object with a
C<scope> method. This function is an opt-in named export and is also available
through the uppercase C<:ALL> tag. Nothing is exported by default.

=cut

sub app_state { return __PACKAGE__->new(@_) }

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
    return bless [$scope->{state}], $class;
}

=head1 METHODS

=head2 get

    my $value = $state->get('required');
    my $value = $state->get('optional', $default);

The one-argument form croaks when the key is absent and lists the available
keys. The two-argument form returns the supplied default for an absent key.

=cut

sub get {
    my ($self, @arguments) = @_;
    croak 'get() requires 1 or 2 arguments'
        if @arguments < 1 || @arguments > 2;
    my ($key, @default) = @arguments;
    my $data = $self->[0];
    if (!exists $data->{$key}) {
        return $default[0] if @default;
        my @keys = sort CORE::keys %{$data};
        croak "State key '$key' does not exist. Available keys: "
            . (@keys ? join(', ', @keys) : '(none)');
    }
    return $data->{$key};
}

=head2 exists

Returns true when a key exists in the application state.

=cut

sub exists {
    my ($self, $key) = @_;
    return exists $self->[0]{$key} ? 1 : 0;
}

=head2 keys

Returns the application state keys.

=cut

sub keys {
    my ($self) = @_;
    return CORE::keys %{$self->[0]};
}

=head2 data

Returns the backing hashref. This is the explicit escape hatch for integrations
that require raw hash access.

=cut

sub data { return $_[0][0] }

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

L<PAGI::Request>, L<PAGI::Stash>

=cut
