package PAGI::Utils::_ProtocolHelpers;
use strict;
use warnings;
use Carp qw(croak);
use Future;
use Scalar::Util qw(blessed);
use PAGI::Utils ();
use PAGI::Routing::RequestResponse;

# Every send a protocol helper makes comes through here. PAGI::Spec::Www 0.7
# ("Sends Are Sequential") has the server keep a scope's sends in the order
# they were called, so each goes to the server at once and several producers
# on one connection need no queue. A send that dies is a failed Future, as
# from any send. Cancelling the returned Future leaves the server's send
# alone: PAGI::Spec advises against cancelling a send.
sub forward_send {
    my ($owner, $event) = @_;
    my $sent = eval { Future->wrap($owner->{send}->($event)) } // Future->fail($@);
    return $sent->without_cancel;
}

# Admission and helper cleanup use these public capabilities. A version string
# is diagnostic context, not proof that the connection implements the contract.
sub require_connection {
    my ($scope, $operation) = @_;
    my $connection = $scope->{'pagi.connection'};
    my $version = $scope->{pagi}{spec_version} // 'unspecified';
    my @required = qw(response_started is_connected on_end disconnect_reason disconnect_detail);
    push @required, qw(close_code close_reason) if $scope->{type} eq 'websocket';
    push @required, qw(end_future) if $scope->{type} eq 'sse';   # every() races it
    my @missing = blessed($connection)
        ? grep { !$connection->can($_) } @required : @required;
    croak "$operation requires pagi.connection capabilities " . join(', ', @missing)
        . " (server reports spec_version $version; current connection contract required)"
        if @missing;
    return $connection;
}

sub prepare_refusal {
    my ($scope, $label, @targets) = @_;
    my $connection = require_connection($scope, $label);
    croak "$label requires exactly one Request handler or app object"
        unless @targets == 1;
    my ($target) = @targets;
    PAGI::Utils::_validate_app_value($target, $label, 'Request handler');
    croak "$label requires a live connection with no response started"
        unless $connection->is_connected && !$connection->response_started;
    return ref($target) eq 'CODE'
        ? PAGI::Routing::RequestResponse->new(handler => $target)
        : $target;
}
1;

__END__

=head1 NAME

PAGI::Utils::_ProtocolHelpers - Private plumbing shared by PAGI::WebSocket and PAGI::SSE

=head1 DESCRIPTION

The functions L<PAGI::WebSocket> and L<PAGI::SSE> share: forwarding their
sends to the server, checking the connection supports what they need, and
preparing a refusal.

This package is a private implementation detail. Application code must not
depend on its name or interface; it may change without a compatibility
layer.

=head1 FUNCTIONS

=head2 forward_send

    await PAGI::Utils::_ProtocolHelpers::forward_send($helper, $event);

Sends C<$event> through C<< $helper->{send} >> at once (the server keeps a
scope's sends in call order) and returns a Future for it. A send that dies
is a failed Future; cancelling the returned Future never cancels the send
the server holds.

=head2 require_connection

    my $connection = PAGI::Utils::_ProtocolHelpers::require_connection($scope, $operation);

Returns C<< $scope->{'pagi.connection'} >>, or croaks naming C<$operation>
and the capabilities it lacks.

=head2 prepare_refusal

    my $app = PAGI::Utils::_ProtocolHelpers::prepare_refusal($scope, $label, $target);

Checks that a refusal can still be sent (a live connection, no response
started) and returns C<$target> as an application: a code reference becomes
a Request handler.

=cut
