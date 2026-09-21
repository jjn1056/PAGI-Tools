package PAGI::Auth;
use strict;
use warnings;
use Carp qw(croak);
use Exporter qw(import);
use Scalar::Util qw(blessed);
use PAGI::Auth::Credentials ();
use PAGI::Auth::Failure ();
use PAGI::Auth::Result ();
use PAGI::Auth::UnauthenticatedUser ();
use PAGI::Utils::Scope ();

our @EXPORT = ();
our @EXPORT_OK = qw(auth auth_result unauth_result www_authenticate);

sub new {
    my ($class, @args) = @_;
    croak 'PAGI::Auth constructor does not accept options' if @args;
    croak 'PAGI::Auth invocant must be an Auth class'
        if ref($class) || !defined($class) || !$class->isa('PAGI::Auth');
    return bless {}, $class;
}

sub auth {
    my ($proto, @args) = _factory_invocation(@_);
    _validate_invocant($proto);
    my $scope = PAGI::Utils::Scope::scope_from_source('PAGI::Auth auth', @args);
    croak q{PAGI::Auth auth scope has no 'pagi.auth' result}
        unless exists $scope->{'pagi.auth'};
    my $result = $scope->{'pagi.auth'};
    croak q{PAGI::Auth auth 'pagi.auth' must be a completed PAGI::Auth::Result}
        unless blessed($result) && $result->isa('PAGI::Auth::Result');
    return $result;
}

sub auth_result {
    my ($proto, @args) = _factory_invocation(@_);
    _validate_invocant($proto);
    my $opts = _options('auth_result', { user => 1, scopes => 1 }, @args);
    croak 'PAGI::Auth auth_result user is required' unless exists $opts->{user};
    _validate_user($opts->{user}, 1, 'auth_result');
    my $scopes = exists($opts->{scopes}) ? $opts->{scopes} : [];
    return PAGI::Auth::Result->_new(
        user        => $opts->{user},
        credentials => PAGI::Auth::Credentials->_new($scopes),
        failure     => undef,
    );
}

sub unauth_result {
    my ($proto, @args) = _factory_invocation(@_);
    _validate_invocant($proto);
    my $opts = _options('unauth_result',
        { user => 1, scopes => 1, failure => 1 }, @args);
    my $user = exists($opts->{user})
        ? $opts->{user} : PAGI::Auth::UnauthenticatedUser->new;
    _validate_user($user, 0, 'unauth_result');
    my $scopes = exists($opts->{scopes}) ? $opts->{scopes} : [];
    my $failure = exists($opts->{failure})
        ? PAGI::Auth::Failure->_new($opts->{failure}) : undef;
    return PAGI::Auth::Result->_new(
        user        => $user,
        credentials => PAGI::Auth::Credentials->_new($scopes),
        failure     => $failure,
    );
}

sub www_authenticate {
    my ($proto, @args) = _factory_invocation(@_);
    _validate_invocant($proto);
    croak 'PAGI::Auth www_authenticate scheme is required' unless @args;
    my $scheme = shift @args;
    my $token = qr/\A[!#\$%&'*+\-.\^_`|~0-9A-Za-z]+\z/;
    croak 'PAGI::Auth www_authenticate scheme must be an HTTP token'
        unless defined($scheme) && !ref($scheme) && $scheme =~ $token;
    croak 'PAGI::Auth www_authenticate parameters must be name/value pairs'
        if @args % 2;
    my (%seen, @serialized);
    while (@args) {
        my ($name, $value) = splice(@args, 0, 2);
        croak 'PAGI::Auth www_authenticate parameter name must be an HTTP token'
            unless defined($name) && !ref($name) && $name =~ $token;
        croak "PAGI::Auth www_authenticate duplicate parameter '$name'"
            if $seen{lc $name}++;
        croak "PAGI::Auth www_authenticate value for '$name' must be a defined scalar"
            unless defined($value) && !ref($value);
        croak "PAGI::Auth www_authenticate value for '$name' must be an HTTP quoted-string byte value"
            unless $value =~ /\A[\x09\x20-\x7e\x80-\xff]*\z/;
        $value =~ s/([\\"])/\\$1/g;
        push @serialized, $name . '="' . $value . '"';
    }
    return @serialized ? $scheme . ' ' . join(', ', @serialized) : $scheme;
}

sub _factory_invocation {
    return ('PAGI::Auth', @_) unless @_ && _is_auth_invocant($_[0]);
    return @_;
}

sub _is_auth_invocant {
    my ($value) = @_;
    return $value->isa('PAGI::Auth') if blessed($value);
    return 0 unless defined($value) && !ref($value) && length($value);
    return eval { $value->isa('PAGI::Auth') } ? 1 : 0;
}

sub _validate_invocant {
    my ($proto) = @_;
    return $proto if blessed($proto) && $proto->isa('PAGI::Auth');
    croak 'PAGI::Auth invocant must be an Auth class or instance'
        if ref($proto) || !defined($proto) || !$proto->isa('PAGI::Auth');
    return $proto;
}

sub _options {
    my ($name, $allowed, @args) = @_;
    croak "PAGI::Auth $name options must be key/value pairs" if @args % 2;
    my %opts;
    while (@args) {
        my ($key, $value) = splice(@args, 0, 2);
        croak "PAGI::Auth $name option names must be defined scalars"
            unless defined($key) && !ref($key);
        croak "PAGI::Auth $name has unknown option '$key'" unless $allowed->{$key};
        croak "PAGI::Auth $name has duplicate option '$key'" if exists $opts{$key};
        $opts{$key} = $value;
    }
    return \%opts;
}

sub _validate_user {
    my ($user, $authenticated, $constructor) = @_;
    croak "PAGI::Auth $constructor user must be an object implementing is_authenticated, identity, and display_name"
        unless blessed($user) && $user->can('is_authenticated')
            && $user->can('identity') && $user->can('display_name');
    my $flag = $user->is_authenticated ? 1 : 0;
    croak "PAGI::Auth $constructor user must be authenticated"
        if $authenticated && !$flag;
    croak "PAGI::Auth $constructor user must be unauthenticated"
        if !$authenticated && $flag;
    return $user;
}

1;

=head1 NAME

PAGI::Auth - authentication results, installed context, and challenge formatting

=head1 SYNOPSIS

  use PAGI::Auth qw(auth auth_result unauth_result www_authenticate);

  return auth_result(user => $user, scopes => ['authenticated', 'notes:read']);
  return unauth_result(failure => { message => 'The token was not accepted.' });

  my $context = auth($request);
  my $challenge = www_authenticate('Bearer', realm => 'api');

=head1 DESCRIPTION

C<PAGI::Auth> constructs completed authentication results and observes a result
installed under C<pagi.auth> in a raw scope or an object exposing C<scope>.
Applications explicitly choose their refusal responses and may use
C<www_authenticate> to format one challenge value.

Nothing is exported by default. C<auth>, C<auth_result>, C<unauth_result>, and
C<www_authenticate> are optional exports. Each helper also supports class and
factory-instance invocation. C<new> accepts no options and creates a shareable,
stateless factory.

=head2 auth

Returns the completed L<PAGI::Auth::Result> stored under C<pagi.auth>. Missing
or invalid installed context is an error.

=head2 auth_result

Requires a duck-typed authenticated C<user>. Optional C<scopes> is an arrayref
and defaults to a fresh empty array. Supplied user and scopes references are
retained.

=head2 unauth_result

Accepts an optional unauthenticated C<user>, C<scopes>, and C<failure> hash with
a required C<message> and optional C<code>. Omitted user and scopes values are
fresh defaults.

=head2 www_authenticate

Formats one scheme and ordered list of named parameters as a plain header value.
Names use HTTP token syntax. Values are quoted strings; embedded quotes and
backslashes are escaped. Use repeated ordinary response header fields for
multiple challenges.

=head1 SEE ALSO

L<PAGI::Auth::Result>, L<PAGI::Auth::Credentials>, L<PAGI::Auth::Failure>,
L<PAGI::Auth::SimpleUser>, L<PAGI::Auth::UnauthenticatedUser>

=cut
