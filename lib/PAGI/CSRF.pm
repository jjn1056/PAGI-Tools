package PAGI::CSRF;

use strict;
use warnings;
use Carp qw(croak);
use Exporter 'import';
use PAGI::Utils::Scope ();
use PAGI::Utils::SecureCompare ();

our @EXPORT = ();
our @EXPORT_OK = qw(csrf);
our %EXPORT_TAGS = (ALL => [@EXPORT_OK]);

=head1 NAME

PAGI::CSRF - Strict access to an issued CSRF token

=head1 SYNOPSIS

    use PAGI::CSRF qw(csrf);

    my $guard = csrf($request);
    my $token = $guard->token;

    return $response->text('CSRF validation failed', status => 403)
        unless $guard->verify($submitted_token);

=head1 DESCRIPTION

C<PAGI::CSRF> wraps the C<csrf_token> provider installed in a PAGI scope by
L<PAGI::Middleware::CSRF>. The provider must be a defined, nonempty scalar.
Verification uses L<PAGI::Utils::SecureCompare/secure_compare>.

The facade retains the resolved scope and reads its provider at operation time.
It does not add a cache key to the scope, and separate constructor calls return
separate facade objects.

=head1 FUNCTIONS

=head2 csrf

    my $guard = csrf($scope);
    my $guard = csrf($request);

Constructs a CSRF facade from exactly one unblessed scope hashref or object
with a C<scope> method. This function is an opt-in named export and is also
available through the uppercase C<:ALL> tag. Nothing is exported by default.

=cut

sub csrf { return __PACKAGE__->new(@_) }

=head1 CONSTRUCTOR

=head2 new

    my $guard = PAGI::CSRF->new($source);

Requires a valid C<csrf_token> provider in the resolved scope.

=cut

sub new {
    my ($class, @arguments) = @_;
    my $scope = PAGI::Utils::Scope::scope_from_source($class, @arguments);
    _provider_token($scope);
    return bless { scope => $scope }, $class;
}

sub _provider_token {
    my ($scope) = @_;
    my $token = $scope->{csrf_token};
    croak 'PAGI::CSRF requires a defined, nonempty, non-reference csrf_token provider'
        unless defined($token) && !ref($token) && length($token);
    return $token;
}

=head1 METHODS

=head2 token

    my $token = $guard->token;

Returns the current token from the resolved scope.

=cut

sub token {
    my ($self, @arguments) = @_;
    croak 'token() accepts no arguments' if @arguments;
    return _provider_token($self->{scope});
}

=head2 verify

    if ($guard->verify($submitted_token)) { ... }

Returns true when the submitted nonempty scalar matches the current provider,
and false for a missing, empty, reference, or mismatching submitted value.

=cut

sub verify {
    my ($self, @arguments) = @_;
    croak 'verify() requires exactly one submitted token'
        unless @arguments == 1;
    my $submitted = $arguments[0];
    return 0 unless defined($submitted) && !ref($submitted) && length($submitted);
    return PAGI::Utils::SecureCompare::secure_compare(
        $submitted,
        $self->token,
    );
}

1;

=head1 SEE ALSO

L<PAGI::Middleware::CSRF>, L<PAGI::Request>

=cut
