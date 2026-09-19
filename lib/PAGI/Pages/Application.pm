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
    croak "PAGI::Pages::Application response_for requires HTTP, WebSocket, or SSE scope; received '$type'"
        unless $type eq 'http' || $type eq 'websocket' || $type eq 'sse';
    return $scope;
}

sub _materialize_scope {
    my ($self, $scope) = @_;
    my $descriptor = $self->{descriptor_factory}->($scope);
    croak 'PAGI::Pages descriptor factory must return an immediate value'
        if blessed($descriptor) && $descriptor->isa('Future');
    my $metadata = PAGI::Pages::_metadata_scope($scope);
    return $self->{policy}->_response_for($metadata, $descriptor);
}

sub to_app {
    my ($self) = @_;
    return async sub {
        my ($source, $receive, $send) = @_;
        my $scope = $self->_validated_scope($source);
        my $response = $self->_materialize_scope($scope);
        return await invoke_app($response, $scope, $receive, $send);
    };
}

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::Pages::Application - Deferred request-scope application returned by PAGI::Pages

=head1 DESCRIPTION

This component retains the exact configured L<PAGI::Pages> policy object and a
validated descriptor factory. It stores no Request, scope, Response, receive,
or send channel. Each HTTP, WebSocket, or SSE invocation builds a fresh
request-local descriptor and concrete Response, then delegates that Response
through L<PAGI::Utils/invoke_app>.

The policy object is not cloned, frozen, reconstructed, or inspected. A
deliberate later mutation may affect later invocations; renderer-maintained
subclass state is caller-owned. Concurrent mutation during descriptor/Response
derivation is unsupported.

When invoked via C<to_app>, the application rejects lifespan and custom scopes
before receive, rendering, or send. It does not handle lifespan. Automatic server
lifespan mode may treat that exception as a decline; strict mode rejects it.

=head1 METHODS

=head2 to_app

  my $native = $page->to_app();

Returns a native application coderef. Each call
C<< $native-E<gt>($scope, $receive, $send) >> validates an HTTP, WebSocket, or
SSE scope, immediately materializes a fresh concrete L<PAGI::Response>, invokes
it through L<PAGI::Utils/invoke_app>, and returns a Future for that invocation.
The coderef uses the same materialization path as C<response_for>.

The C<PAGI::Pages::Application> itself already implements C<to_app>, so callers
may pass C<$page> directly to ordinary application positions,
L<PAGI::WebSocket/deny>, or L<PAGI::SSE/decline>. Explicit conversion or
materialization is not required.

=head2 response_for

  my $response = $page->response_for($request);
  my $response = $page->response_for($websocket);
  my $response = $page->response_for($sse);
  my $response = $page->response_for($scope_hash);
  my $response = $page->response_for($object_with_scope_method);

C<response_for($source)> synchronously and immediately returns one concrete
L<PAGI::Response>. It requires exactly one source: an unblessed scope hashref,
or any blessed object whose C<scope()> method returns an unblessed scope
hashref. This includes L<PAGI::Request>, L<PAGI::WebSocket>, and L<PAGI::SSE>
without limiting the contract to those classes.

The resulting scope type must be C<http>, C<websocket>, or C<sse>. Lifespan,
custom, missing, and reference-valued types croak before descriptor creation or
rendering. Extra arguments are not materialization options and are rejected.
C<response_for> does not call C<receive> or C<send>, emit events, or own
protocol lifecycle. For ordinary protocol refusal, pass the Pages application
itself to the appropriate helper's C<deny> or C<decline>.

Materialization does not mutate the application, descriptor, source object,
or scope hash. Repeated and concurrent calls derive fresh response values.
Negotiation, preserved redirect query validation, the 426 HTTP/1.1 rule, and
presentation-hook validation occur during this call and can croak. A renderer
or descriptor factory must return an immediate value rather than a Future.

=head1 SEE ALSO

L<PAGI::Pages>, L<PAGI::Response>, L<PAGI::WebSocket>, L<PAGI::SSE>

=cut
