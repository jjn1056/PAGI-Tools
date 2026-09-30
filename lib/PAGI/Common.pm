package PAGI::Common;
use strict;
use warnings;
use Carp qw(croak);
use Future;
use Scalar::Util qw(blessed);
use PAGI::Utils ();
use PAGI::Routing::RequestResponse;

# PAGI::Spec::Www, "Sends Are Sequential": one send in flight per connection.
# Every send a protocol helper makes comes through here, so code with several
# producers on one connection needs no queue of its own. A send issued while
# another is outstanding waits for it to settle, whatever its outcome. The
# returned Future reports this send alone. Cancelling it before the send is
# issued skips the send; cancelling it afterwards leaves the server's send
# Future alone, and the next send still waits for that one to settle.
sub send_in_order {
    my ($owner, $event) = @_;
    my $result = Future->new;
    my $previous = $owner->{_send_tail} // Future->done;
    $owner->{_send_tail} = $previous->followed_by(sub {
        return Future->done if $result->is_cancelled;
        my $sent = eval { Future->wrap($owner->{send}->($event)) };
        $sent //= Future->fail($@);
        $sent->on_ready(sub {
            my ($settled) = @_;
            return if $result->is_ready;
            if    ($settled->is_failed)    { $result->fail($settled->failure) }
            elsif ($settled->is_cancelled) { $result->cancel }
            else                           { $result->done($settled->get) }
        });
        return $sent->followed_by(sub { Future->done });
    });
    return $result;
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
