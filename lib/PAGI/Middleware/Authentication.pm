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

This middleware constructs one L<PAGI::Request> for each HTTP, WebSocket, or
SSE invocation and passes it to the configured backend. The backend is either a
coderef or an object implementing C<authenticate>. It must return one completed
L<PAGI::Auth::Result>, immediately or through a L<Future>.

The result is installed under C<pagi.auth> in a shallow child scope and the
downstream application always continues. Guest and rejected results do not
select responses; applications make that decision explicitly. Backend and
downstream exceptions and failed Futures propagate normally.

Other scope types are passed through unchanged without constructing a request
or invoking the backend.

=cut
