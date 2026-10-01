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
use PAGI::Utils::Headers ();
use PAGI::Utils::Scope ();

our @EXPORT = ();
our @EXPORT_OK = qw(auth auth_result unauth_result www_authenticate requires);

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
    return PAGI::Utils::Headers::www_authenticate(@args);
}

# Starlette's @requires: a handler that calls $handler only for an
# authenticated user holding every scope, and otherwise refuses -- with
# `status` (default 403), or a redirect: to a string as written, or to
# path_for(@arrayref) with ?next= added. HTTP routes return the refusal;
# WebSocket and SSE routes deny or decline with it.
sub requires {
    my ($proto, @args) = _factory_invocation(@_);
    _validate_invocant($proto);
    my ($scopes, $handler, @rest) = @args;
    $scopes = [$scopes] if defined $scopes && !ref $scopes;
    croak 'PAGI::Auth requires scopes must be a scope string or an arrayref of them'
        unless ref($scopes) eq 'ARRAY' && !grep { !defined || ref } @$scopes;
    croak 'PAGI::Auth requires handler must be a coderef'
        unless ref($handler) eq 'CODE';
    my $opts = _options('requires', { status => 1, redirect => 1 }, @rest);
    croak 'PAGI::Auth requires takes status or redirect, not both: a redirect replaces the refusal'
        if exists $opts->{status} && exists $opts->{redirect};
    my $status = $opts->{status} // 403;
    croak 'PAGI::Auth requires status must be a 4xx refusal status'
        unless $status =~ /\A4\d\d\z/;
    my $redirect = $opts->{redirect};
    croak 'PAGI::Auth requires redirect must be a location string or an arrayref of path_for arguments'
        if defined($redirect)
            && (ref($redirect) ? ref($redirect) ne 'ARRAY' || !@$redirect || !defined($redirect->[0]) || ref($redirect->[0])
                               : !length($redirect));

    require PAGI::Pages;
    my $denied = PAGI::Pages->status($status);
    my @required = @$scopes;

    return sub {
        my ($connection) = @_;
        my $context = $proto->auth($connection);
        return $handler->(@_)
            if $context->user->is_authenticated
                && $context->credentials->has_all(@required);

        my $refusal = defined($redirect)
            ? PAGI::Pages->redirect(_redirect_target($redirect, $connection), status => 303)
            : $denied;
        return $connection->deny($refusal)
            if blessed($connection) && $connection->isa('PAGI::WebSocket');
        return $connection->decline($refusal)
            if blessed($connection) && $connection->isa('PAGI::SSE');
        return $refusal;
    };
}

# A string is the location as written. An arrayref holds path_for's
# arguments -- compact (NAME, \%params, \%query, $fragment) or named
# (NAME, params => ..., query => ..., fragment => ...) -- and gains a `next`
# query value, the original path and query, unless it sets its own.
sub _redirect_target {
    my ($redirect, $connection) = @_;
    return $redirect unless ref $redirect;

    my $scope = PAGI::Utils::Scope::scope_from_source('PAGI::Auth requires', $connection);
    my $original = PAGI::Utils::Scope::request_uri($scope);

    my ($name, @arguments) = @$redirect;
    if (!@arguments || !defined($arguments[0]) || ref($arguments[0]) eq 'HASH') {
        my ($params, $query, @fragment) = @arguments;
        @arguments = ($params // {}, { next => $original, %{ $query // {} } }, @fragment);
    }
    else {
        my %named = @arguments;
        $named{query} = { next => $original, %{ $named{query} // {} } };
        @arguments = %named;
    }
    require PAGI::Routing::URL;
    return PAGI::Routing::URL::path_for($connection, $name, @arguments);
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
      my $token = $request->bearer_token;
      return unauth_result() unless defined $token;
      my $claims = verify_application_jwt($token); # application-owned verifier
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

  # Declare who may call a route, like Starlette's @requires:
  use PAGI::Auth qw(requires);

  route('/notes'  => requires(['notes:read', 'notes:write'], \&publish_note), methods => ['POST']),
  route('/admin'  => requires(['admin'], \&admin, status => 404)),
  route('/home'   => requires([], \&home, redirect => ['login'])),

=head1 DESCRIPTION

C<PAGI::Auth> constructs completed authentication results and observes a result
installed under C<pagi.auth> in a raw scope or an object exposing C<scope>.
Applications choose their refusal responses: by declaring what a route
requires with C<requires>, or by hand, using C<www_authenticate> to format a
challenge value. C<credentials> means granted
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

=head2 requires($scopes, $handler, status => $code, redirect => $target)

    my $publish = requires(['notes:read', 'notes:write'], async sub ($request) {
        ...
    });
    route('/notes' => $publish, methods => ['POST']);

Returns a handler that calls C<$handler> with its arguments only when the
connection's authentication context (see C<auth>) has an authenticated user
holding every scope in C<$scopes> -- a scope string, or an arrayref of them;
C<[]> requires only an authenticated user. It is the equivalent of
Starlette's C<@requires>, as a function that returns an ordinary handler
coderef, so it fits anywhere a handler does (a C<route>, C<websocket> or
C<sse> handler) and can be applied by a framework, for example from a sub
attribute. It needs the L<PAGI::Middleware::Authentication> middleware in
front of the route.

Otherwise it refuses. Options:

=over 4

=item * C<status> (default 403)

The 4xx status of the refusal, as a negotiated L<PAGI::Pages> response
(C<application/problem+json> or HTML). C<< status => 404 >> hides the route
from those without access.

=item * C<redirect>

Instead of refusing, redirect (303); give this or C<status>, not both. The
value says which kind of target it is:

    redirect => '/login'                                # a location, as written
    redirect => 'https://login.example.com/?app=notes'
    redirect => ['login']                               # path_for arguments
    redirect => ['org_login', { org => 'acme' }, { reason => 'billing' }]

A string is used exactly as written: a path, or a URL outside the
application.

An arrayref holds the arguments to C<path_for> (see L<PAGI::Routing::URL>):
the route name, then its parameters, query and fragment, in either of the
forms C<path_for> takes. Being resolved against the request that was
refused, it does two things a fixed string cannot:

=over 4

=item * The target route's parameters are filled from the current route's
matching ones, as C<path_for> does: on C</orgs/{org}/settings>,
C<< redirect => ['org_login'] >> goes to C</orgs/acme/login>. Parameters you
give override them.

=item * The path and query the client requested (L<PAGI::Request/request_uri>,
including any mount and server root path) are added to the query as
C<next>, so the login page can send the user back after logging in. A C<next> you give
yourself is kept instead.

=back

A redirect lets a login page act on C<next>; only redirect to it when it is a
local path (it starts with C</> but not C<//>), or the login page becomes an
open redirect. See F<examples/auth-cookie-login>.

=back

HTTP routes return the refusal; WebSocket routes C<deny> and SSE routes
C<decline> with it, before accepting or starting. Like Starlette's, the
refusal is one status: it does not distinguish an unauthenticated user from a
missing scope or send a C<WWW-Authenticate> challenge. An API that wants
RFC 6750 challenges builds those responses itself (see the auth-notes
example).

Invalid arguments die when the route is declared: a handler that is not a
coderef, a status outside 400-499, a C<redirect> that is neither a string nor
a non-empty arrayref, C<status> and C<redirect> together, an unknown option.

=head2 Protecting a group of endpoints

This complete recipe installs Authentication before an application-owned HTTP
check. Both protected routes share it; C</public> sits outside the group.
The wrapper delegates lifespan and other non-HTTP scopes before reading auth,
awaits the next application, and invokes an ordinary response directly for a
guest or rejection. The backend delegates Authorization parsing to Request;
duplicates are rejected without selecting a token. The fixed token is only a
teaching fixture; replace it with application-owned verification.

  use v5.40;
  use Future::AsyncAwait;
  use PAGI::Auth qw(auth auth_result unauth_result www_authenticate);
  use PAGI::Auth::SimpleUser;
  use PAGI::Compose qw(compose);
  use PAGI::Response qw(text_response);
  use PAGI::Routing qw(route mount middleware);
  use PAGI::Utils qw(invoke_app);

  my $backend = sub ($request) {
      my $token;
      my $parsed = eval {
          $token = $request->bearer_token(raise_on_error => 1);
          1;
      };
      return unauth_result(failure => {
          message => 'Malformed Authorization header.',
          code    => 'malformed_authorization',
      }) unless $parsed;
      return unauth_result() unless defined $token;
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
