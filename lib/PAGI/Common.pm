package PAGI::Common;
use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use PAGI::Utils ();
use PAGI::Routing::RequestResponse;

# PAGI::Spec::Www lets frameworks rely on pagi.connection on a scope whose
# spec_version is 0.6 or later, and an omitted spec_version means 0.1. Both
# must hold: the server's advertised version, and the capabilities admission
# and helper cleanup use (a version is a claim, not proof of the contract).
sub require_connection {
    my ($scope, $operation) = @_;
    my $advertised = $scope->{pagi}{spec_version};
    croak "$operation requires PAGI::Spec::Www 0.6 or later; server reports spec_version "
        . ($advertised // 'none (0.1)')
        unless _www_version_at_least($advertised // '0.1', 0, 6);

    my $connection = $scope->{'pagi.connection'};
    my @required = qw(response_started is_connected on_end disconnect_reason disconnect_detail);
    push @required, qw(close_code close_reason) if $scope->{type} eq 'websocket';
    my @missing = blessed($connection)
        ? grep { !$connection->can($_) } @required : @required;
    croak "$operation requires pagi.connection capabilities " . join(', ', @missing)
        . " (server reports spec_version $advertised; current connection contract required)"
        if @missing;
    return $connection;
}

# Spec versions are dotted MAJOR.MINOR numbers: 0.10 is later than 0.6.
sub _www_version_at_least {
    my ($version, $major, $minor) = @_;
    my ($have_major, $have_minor) = ($version // '') =~ /\A(\d+)\.(\d+)\z/
        or return 0;
    return $have_major > $major
        || ($have_major == $major && $have_minor >= $minor);
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
