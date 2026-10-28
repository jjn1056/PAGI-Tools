package PAGI::Common;
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
sub send_event {
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
