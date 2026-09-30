package PAGI::Middleware::Authentication;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(blessed);
use PAGI::Auth qw(auth);
use PAGI::Request;
use PAGI::Utils::Middleware qw(clone_scope);

sub _init {
    my ($self, $config) = @_;

    for my $name (keys %$config) {
        croak "Authentication has unknown option '$name'"
            unless $name eq 'backend';
    }
    croak 'Authentication requires backend'
        unless exists $config->{backend};

    my $backend = $config->{backend};
    croak 'Authentication backend must be a coderef or an object implementing authenticate'
        unless ref($backend) eq 'CODE'
            || (blessed($backend) && $backend->can('authenticate'));

    $self->{backend} = $backend;
}

sub wrap {
    my ($self, $app) = @_;
    my $backend = $self->{backend};

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $type = $scope->{type} // '';
        unless ($type eq 'http' || $type eq 'websocket' || $type eq 'sse') {
            await $app->($scope, $receive, $send);
            return;
        }

        my $request = PAGI::Request->new($scope, $receive);
        my $returned = ref($backend) eq 'CODE'
            ? $backend->($request)
            : $backend->authenticate($request);
        my @results = await Future->wrap($returned);
        croak 'Authentication backend must return one Auth result'
            unless @results == 1;

        my $inner = clone_scope($scope, { 'pagi.auth' => $results[0] });
        auth($inner);
        await $app->($inner, $receive, $send);
        return;
    };
}

1;

__END__

=head1 NAME

PAGI::Middleware::Authentication - install request authentication results

=head1 SYNOPSIS

  use PAGI::Auth qw(unauth_result);
  use PAGI::Middleware::Authentication;

  my $middleware = PAGI::Middleware::Authentication->new(
      backend => sub {
          my ($request) = @_;
          return unauth_result();
      },
  );

  my $app = $middleware->wrap($next);

=head1 DESCRIPTION

Construct with C<new(backend =E<gt> $backend)> and call C<wrap($next)> to get a
native application. C<backend> is required and must be exactly a coderef or an
object implementing C<authenticate>; unknown constructor options are errors.
The same backend is reused across invocations. This middleware constructs one
L<PAGI::Request> for each HTTP, WebSocket, or SSE invocation. A coderef receives
that Request as its only argument; an object's C<authenticate($request)> receives
it after the normal invocant. Either form must return exactly one completed
L<PAGI::Auth::Result>, directly or through a L<Future>. Bare users, C<undef>,
and response values are errors.
The Request uses the real receive channel: backend body reads have their normal
consumption effects and protocol restrictions, with no automatic body replay.

The result is installed under C<pagi.auth> in a shallow child scope and the
downstream application always continues. Guest and rejected results do not
select responses; applications make that decision explicitly. Backend and
downstream exceptions and failed Futures propagate normally. No
C<authenticated> scope is granted implicitly. An application can read the
result with C<auth($scope)> or C<auth($request)>; absence is a configuration
error rather than an implicit guest.

Other scope types are passed through unchanged without constructing a request
or invoking the backend.

=cut
