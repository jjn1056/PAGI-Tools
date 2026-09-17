package PAGI::Pages::Application;

use strict;
use warnings;

use Carp qw(croak);
use Future::AsyncAwait;
use Scalar::Util qw(blessed);

use PAGI::Utils qw(invoke_app);
use PAGI::Utils::Scope ();

sub new {
    my ($class, %args) = @_;
    my $policy = $args{policy};
    my $descriptor_factory = $args{descriptor_factory};

    croak 'PAGI::Pages::Application requires one Pages policy and descriptor factory'
        unless keys(%args) == 2
            && blessed($policy) && $policy->isa('PAGI::Pages')
            && ref($descriptor_factory) eq 'CODE';

    return bless {
        policy             => $policy,
        descriptor_factory => $descriptor_factory,
    }, $class;
}

sub response_for {
    my ($self, @sources) = @_;
    my $scope = $self->_validated_scope(@sources);
    return $self->_materialize_scope($scope);
}

sub _validated_scope {
    my ($self, @sources) = @_;
    my $scope = PAGI::Utils::Scope::scope_from_source(
        'PAGI::Pages::Application response_for', @sources,
    );
    my $type = $scope->{type};
    croak 'PAGI::Pages::Application response_for scope type is required'
        unless defined($type) && !ref($type) && length($type);
    croak 'PAGI::Pages application requires HTTP scope when invoked via to_app; '
        . 'PAGI::Pages::Application response_for does not accept a lifespan scope'
        if $type eq 'lifespan';
    return $scope;
}

sub _materialize_scope {
    my ($self, $scope) = @_;
    my $descriptor = $self->{descriptor_factory}->($scope);
    croak 'PAGI::Pages descriptor factory must return an immediate value'
        if blessed($descriptor) && $descriptor->isa('Future');
    my $metadata = PAGI::Pages::_http_metadata_scope($scope);
    return $self->{policy}->_response_for($metadata, $descriptor);
}

sub to_app {
    my ($self) = @_;
    return async sub {
        my ($source, $receive, $send) = @_;
        my $scope = $self->_validated_scope($source);
        my $type = $scope->{type};
        croak "PAGI::Pages application requires HTTP scope; received '$type'"
            unless $type eq 'http';
        my $response = $self->_materialize_scope($scope);
        return await invoke_app($response, $scope, $receive, $send);
    };
}

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::Pages::Application - Deferred HTTP application returned by PAGI::Pages

=head1 DESCRIPTION

This component retains the exact configured L<PAGI::Pages> policy object and a
validated descriptor factory. It stores no Request, scope, Response, receive,
or send channel. Each HTTP invocation builds a fresh request-local descriptor
and concrete Response, then delegates that Response through
L<PAGI::Utils/invoke_app>.

The policy object is not cloned, frozen, reconstructed, or inspected. A
deliberate later mutation may affect later invocations; renderer-maintained
subclass state is caller-owned. Concurrent mutation during descriptor/Response
derivation is unsupported.

When invoked via C<to_app>, the application rejects lifespan, WebSocket,
SSE, and custom scopes before receive, rendering, or send. It does not handle lifespan. Automatic server
lifespan mode may treat that exception as a decline; strict mode rejects it.

=head1 METHODS

=head2 to_app

Returns a native HTTP application coderef that uses the same response
materialization path as C<response_for>.

=head2 response_for

  my $response = $page->response_for($request);
  my $response = $page->response_for($websocket);
  my $response = $page->response_for($sse);
  my $response = $page->response_for($scope_hash);

Synchronously materializes one concrete L<PAGI::Response> using metadata from
a Request, WebSocket, SSE, or raw scope hash. It accepts HTTP, WebSocket, SSE,
and custom request-like scopes with a defined, non-reference, nonempty
C<type>; lifespan scopes are rejected. It does not call C<receive> or C<send>,
emit events, or own protocol lifecycle. Use the appropriate helper's C<deny>
or C<decline> to emit the returned Response. A custom protocol adapter owns
emission for its protocol. C<to_app> remains restricted to HTTP scopes.

Materialization does not mutate the application, descriptor, source object,
or scope hash. Repeated and concurrent calls derive fresh response values.

=head1 SEE ALSO

L<PAGI::Pages>, L<PAGI::Auth>, L<PAGI::Response>, L<PAGI::WebSocket>,
L<PAGI::SSE>

=cut
