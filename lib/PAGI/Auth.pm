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
  use PAGI::Auth::SimpleUser;
  use PAGI::Middleware::Authentication;

  my $backend = sub {
      my ($request) = @_;
      my $token = $request->header('Authorization') // '';
      return unauth_result() unless $token =~ /\ABearer (.+)\z/;
      my $claims = verify_application_jwt($1); # application-owned verifier
      return unauth_result(failure => {
          message => 'The token was not accepted.',
      }) unless $claims;
      return auth_result(
          user   => PAGI::Auth::SimpleUser->new(identity => $claims->{sub}),
          scopes => ['notes:read'],
      );
  };

  my $authentication = PAGI::Middleware::Authentication->new(
      backend => $backend,
  );
  my $app = $authentication->wrap($next);

  my $context = auth($request);
  my $challenge = www_authenticate('Bearer', realm => 'api');

=head1 DESCRIPTION

C<PAGI::Auth> constructs completed authentication results and observes a result
installed under C<pagi.auth> in a raw scope or an object exposing C<scope>.
Applications explicitly choose their refusal responses and may use
C<www_authenticate> to format one challenge value. C<credentials> means granted
scopes; it does not hold the original token or other presented credentials.
C<pagi.auth> contains a completed Result, not a hash of public fields. Reading a
missing or invalid entry is a configuration error.

Nothing is exported by default. C<auth>, C<auth_result>, C<unauth_result>, and
C<www_authenticate> are optional exports. Each helper also supports class and
factory-instance invocation. C<new> accepts no options and creates a shareable,
stateless factory.

=head1 INSTALLING CUSTOM AUTHENTICATION CONTEXT

Custom authentication middleware publishes a completed result under the public
C<pagi.auth> scope key. Inside custom middleware, after credentials have been
verified:

  use PAGI::Auth qw(auth_result unauth_result);
  use PAGI::Utils::Middleware qw(clone_scope);

  my $result = auth_result(
      user   => $verified_user,
      scopes => ['catalog:read'],
  );
  # A guest can instead be established with unauth_result(...).
  my $child_scope = clone_scope($scope, {
      'pagi.auth' => $result,
  });

  await $next->($child_scope, $receive, $send);

Downstream code reads the installed value with C<auth($request)>. Installation
replaces the whole C<pagi.auth> entry in a shallow child scope, leaving the
incoming scope unchanged. It does not merge an outer result or clone the result,
its user, or its scopes array; supplied references retain normal Perl reference
semantics.

=head1 PUBLIC METHODS

=head2 new

C<PAGI::Auth-E<gt>new()> returns a shareable, stateless factory instance. It
accepts no options; any argument is an error. The optional exports work as
functions, class methods, and instance methods, including subclass overrides.

=head2 auth($source)

Accepts exactly one raw scope hashref or an object exposing C<scope>, including
L<PAGI::Request>, L<PAGI::WebSocket>, and L<PAGI::SSE>. It resolves that
source's scope and returns the installed L<PAGI::Auth::Result>. An absent
argument, malformed source, missing C<pagi.auth>, or value other than a
completed Result is an error. The nearest installed complete context wins;
this reader does not merge an outer context or construct a guest.

=head2 auth_result(user => $user, scopes => \@grants)

Returns a completed L<PAGI::Auth::Result> with the supplied authenticated user,
L<PAGI::Auth::Credentials>, and no failure. C<user> is required and must be an
object implementing C<is_authenticated>, C<identity>, and C<display_name>, with
a true authentication flag. C<scopes> is optional and defaults to a fresh empty
arrayref. It must be an arrayref of defined scalar grants. No
C<authenticated> grant is inserted automatically; the user flag and grants are
independent. The supplied user and scopes arrayref are retained, not copied.
Odd pairs, duplicate or unknown options, an undefined user, an invalid user,
and invalid scopes are errors.

=head2 unauth_result(user => $guest, scopes => \@grants, failure => \%reason)

Returns a completed Result with an unauthenticated user, Credentials, and an
optional Failure. Omitted C<user> creates a fresh
L<PAGI::Auth::UnauthenticatedUser>; a custom guest must implement the same three
user methods and have a false authentication flag. Omitted C<scopes> creates a
fresh empty arrayref; a supplied arrayref may contain granted scopes even for a
guest. C<failure>, when supplied, is a hashref with a required defined scalar
C<message> and optional defined scalar C<code>. An absent failure means guest,
while a supplied failure records rejection. Empty strings are valid scalar
values. User and scopes references are retained. Odd pairs, duplicate or
unknown options, invalid user/scopes, and malformed failure fields are errors.

=head2 www_authenticate($scheme, name => $value, ...)

Returns one plain C<WWW-Authenticate> header value. C<scheme> is required and
must be an HTTP token. Optional ordered name/value pairs use HTTP token names;
names are unique without regard to case. Values must be defined scalar HTTP
quoted-string byte values (tab, printable ASCII, or bytes 0x80-0xff); quotes
and backslashes are escaped. Without parameters, the return value is just the
scheme. Missing or invalid scheme, odd pairs, duplicate or invalid names, and
undefined, reference, or invalid-byte values are errors. This formatter does
not choose status, send a response, or validate an application's auth policy.
Use repeated ordinary response header fields for multiple challenges; a raw
opaque challenge can also be supplied directly. Every formatter parameter is
quoted, and the formatter does not validate scheme-specific serialization.
Digest C<algorithm> and C<stale> need unquoted values, so construct the complete
header value explicitly through an ordinary response or Headers API:

  my $digest = 'Digest realm="api", nonce="example-nonce", qop="auth", '
      . 'algorithm=SHA-256, stale=true';
  $response->headers->set('WWW-Authenticate', $digest);

=head2 Protecting a group of endpoints

This complete recipe installs Authentication before an application-owned HTTP
check. Both protected routes share it; C</public> sits outside the group.
The wrapper delegates lifespan and other non-HTTP scopes before reading auth,
awaits the next application, and invokes an ordinary response directly for a
guest or rejection. The backend examines every Authorization field and never
selects one from duplicates. The fixed token is only a teaching fixture;
replace it with application-owned verification.

  use v5.40;
  use Future::AsyncAwait;
  use PAGI::Auth qw(auth auth_result unauth_result www_authenticate);
  use PAGI::Auth::SimpleUser;
  use PAGI::Compose qw(compose);
  use PAGI::Response qw(text_response);
  use PAGI::Routing qw(route mount middleware);
  use PAGI::Utils qw(invoke_app);

  my $backend = sub ($request) {
      my @authorization = $request->header_all('Authorization');
      return unauth_result() unless @authorization;
      my $token;
      if (@authorization == 1) {
          my ($scheme) = $authorization[0] =~ /\A(\S+)/;
          return unauth_result()
              if defined($scheme) && lc($scheme) ne 'bearer';
          ($token) = $authorization[0]
              =~ /\ABearer +([A-Za-z0-9._~+\/-]+=*)\z/i;
      }
      return unauth_result(failure => {
          message => 'Malformed Authorization header.',
          code    => 'malformed_authorization',
      }) unless defined $token;
      return auth_result(
          user => PAGI::Auth::SimpleUser->new(identity => 'alice'),
      ) if $token eq 'accepted';
      return unauth_result(failure => {
          message => 'Credential rejected', code => 'invalid_token',
      });
  };

  sub require_login ($next) {
      return async sub ($scope, $receive, $send) {
          if (($scope->{type} // '') ne 'http') {
              await $next->($scope, $receive, $send);
              return;
          }
          my $result = auth($scope);
          unless ($result->user->is_authenticated) {
              my $failure = $result->failure;
              my $malformed = $failure
                  && ($failure->code // '') eq 'malformed_authorization';
              my @params = (realm => 'example');
              push @params, error => ($malformed
                  ? 'invalid_request' : 'invalid_token') if $failure;
              my $response = text_response(
                  $malformed ? 'Malformed Authorization header.' : 'Sign in',
                  status => $malformed ? 400 : 401,
                  headers => ['WWW-Authenticate' =>
                      www_authenticate('Bearer', @params)]);
              await invoke_app($response, $scope, $receive, $send);
              return;
          }
          await $next->($scope, $receive, $send);
          return;
      };
  }

  my $protected = compose(
      middleware => [
          middleware('Authentication', backend => $backend),
          middleware(\&require_login),
      ],
      routes => [
          route('/one' => sub { text_response('one') }),
          route('/two' => sub { text_response('two') }),
      ],
  );

  compose(
      routes => [
          route('/public' => sub { text_response('public') }),
          mount('/', app => $protected),
      ],
      lifespan => {
          startup => sub { $_[0]{ready} = 1; return },
          shutdown => sub { $_[0]{ready} = 0; return },
      },
  );

The group policy is an ordinary middleware factory. The same policy can live
in an object whose C<wrap($next)> method returns that wrapper. If the following
class is in F<MyApp/RequireLogin.pm>, both an object descriptor and a class
descriptor are equivalent to C<middleware(\&require_login)> above:

  package MyApp::RequireLogin;
  use v5.40;
  sub new ($class, %config) { bless \%config, $class }
  sub wrap ($self, $next) { $self->{policy}->($next) }
  1;

  # In the application, after loading MyApp::RequireLogin:
  middleware(MyApp::RequireLogin->new(policy => \&require_login));
  middleware('+MyApp::RequireLogin', policy => \&require_login);

The class descriptor constructs its configured object during application
assembly; both descriptors use the ordinary C<wrap> contract. Place either
one after Authentication in the group middleware list.

=head1 SEE ALSO

L<PAGI::Auth::Result>, L<PAGI::Auth::Credentials>, L<PAGI::Auth::Failure>,
L<PAGI::Auth::SimpleUser>, L<PAGI::Auth::UnauthenticatedUser>

=cut
