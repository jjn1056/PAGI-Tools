package PAGI::Utils::_Refusal;
use strict;
use warnings;
use Carp qw(croak);
use Future::AsyncAwait;
use Scalar::Util qw(blessed);
use PAGI::Utils ();
use PAGI::Routing::RequestResponse;

# Admission and helper cleanup use these public capabilities. A version string
# is diagnostic context, not proof that the connection implements the contract.
sub require_connection {
    my ($scope, $operation) = @_;
    my $connection = $scope->{'pagi.connection'};
    my $version = $scope->{pagi}{spec_version} // 'unspecified';
    my @required = qw(response_started is_connected on_end disconnect_reason disconnect_detail);
    push @required, qw(close_code close_reason) if $scope->{type} eq 'websocket';
    my @missing = blessed($connection)
        ? grep { !$connection->can($_) } @required : @required;
    croak "$operation requires pagi.connection capabilities " . join(', ', @missing)
        . " (server reports spec_version $version; current connection contract required)"
        if @missing;
    return $connection;
}

sub run_refusal {
    my ($helper, @targets) = @_;
    my $scope = $helper->{scope};
    my $websocket = $scope->{type} eq 'websocket';
    my $operation = $websocket ? 'WebSocket deny' : 'SSE decline';
    my $connection = require_connection($scope, $operation);
    croak "$operation requires exactly one Request handler or app object"
        unless @targets == 1;
    my ($target) = @targets;
    PAGI::Utils::_validate_app_value($target, $operation, 'Request handler');
    $helper->_refresh_connection;
    my $initial_phase = $websocket ? 'connecting' : 'pending';
    croak "$operation is only valid before " . ($websocket ? 'accept while connecting' : 'start while pending')
        unless $helper->{_state} eq $initial_phase
            && $connection->is_connected && !$connection->response_started;
    my $application = ref($target) eq 'CODE'
        ? PAGI::Routing::RequestResponse->new(handler => $target) : $target;
    $helper->{_state} = $websocket ? 'denying' : 'declining';
    my $worker = (async sub {
        await PAGI::Utils::invoke_app($application, $scope, $helper->{receive}, $helper->{send});
        return $helper;
    })->();
    $worker->on_ready(sub {
        if ($connection->is_connected && !$connection->response_started) {
            $helper->{_state} = $initial_phase;
        } else {
            $helper->_refresh_connection;
        }
    });
    $worker->retain;
    return $worker->without_cancel;
}
1;
