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

    use Future::AsyncAwait;
    use PAGI::CSRF qw(csrf);
    use PAGI::Middleware::CSRF;
    use PAGI::Request;
    use PAGI::Response qw(response);

    # 1. The middleware handles it. For clients that can set a header (fetch,
    #    XHR): an unsafe request without an X-CSRF-Token header matching the
    #    csrf_token cookie gets a 403 and never reaches the application.
    my $api = PAGI::Middleware::CSRF->new(secret => $secret)->wrap(async sub {
        my ($scope, $receive, $send) = @_;
        # Only requests that passed the check get here.
        await response('JSON', { saved => \1 })->to_app->($scope, $receive, $send);
    });

    # To answer a failed check your own way, pass any application as refuse:
    #   PAGI::Middleware::CSRF->new(secret => $secret,
    #       refuse => response('JSON', { detail => 'CSRF token validation failed' }, status => 403));

    # 2. The application handles it. A plain HTML form sends its token in the
    #    body, which the middleware does not read: with refuse => 0 every
    #    request reaches the application, which verifies the parsed field.
    #    (csrf($scope)->valid and ->failure report the header check, if any.)
    my $form = PAGI::Middleware::CSRF->new(secret => $secret, refuse => 0)->wrap(async sub {
        my ($scope, $receive, $send) = @_;
        my $guard = csrf($scope);
        my $response;
        if ($scope->{method} eq 'GET') {
            # The cookie holding the token is HttpOnly, so the page hands it over.
            my $token = $guard->token;
            $response = response('HTML', qq{<form method="post">}
                . qq{<input type="hidden" name="csrf_token" value="$token">}
                . qq{<button>Save</button></form>});
        }
        else {
            my $fields = await PAGI::Request->new($scope, $receive)->form_params;
            $response = $guard->verify($fields->get('csrf_token') // '')
                ? response('Text', 'Saved')
                : response('Text', 'CSRF token validation failed', status => 403);
        }
        await $response->to_app->($scope, $receive, $send);
    });

=head1 DESCRIPTION

C<PAGI::CSRF> wraps the C<pagi.csrf_token> provider installed in a PAGI scope by
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

Requires a valid C<pagi.csrf_token> provider in the resolved scope.

=cut

sub new {
    my ($class, @arguments) = @_;
    my $scope = PAGI::Utils::Scope::scope_from_source($class, @arguments);
    _provider_token($scope);
    return bless { scope => $scope }, $class;
}

sub _provider_token {
    my ($scope) = @_;
    my $token = $scope->{'pagi.csrf_token'};
    croak 'PAGI::CSRF requires a defined, nonempty, non-reference pagi.csrf_token provider'
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

=head2 valid

    return $refused unless csrf($request)->valid;

Returns 1 unless L<PAGI::Middleware::CSRF> recorded a failed header check
for this request, else 0. Safe methods are not checked and report valid. A
token sent in a form field is not seen by the middleware: verify it with
L</verify> once the form is parsed.

=cut

sub valid {
    my ($self, @arguments) = @_;
    croak 'valid() accepts no arguments' if @arguments;
    return defined($self->failure) ? 0 : 1;
}

=head2 failure

    my $reason = csrf($request)->failure;

Returns why the middleware's header check failed -- C<missing_cookie>,
C<missing_token>, or C<mismatch> -- or undef when it passed or did not run.

=cut

sub failure {
    my ($self, @arguments) = @_;
    croak 'failure() accepts no arguments' if @arguments;
    return $self->{scope}{'pagi.csrf_failure'};
}

1;

=head1 SEE ALSO

L<PAGI::Middleware::CSRF>, L<PAGI::Request>

=cut
