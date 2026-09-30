package PAGI::Request::_BodyInput;
use strict;
use warnings;

use Carp ();

sub event_kind {
    my ($scope_type, $event) = @_;
    Carp::croak('body input requires HTTP or SSE scope')
        unless $scope_type eq 'http' || $scope_type eq 'sse';
    return 'disconnect' unless defined $event;
    Carp::croak('invalid request-body event') unless ref($event) eq 'HASH';
    my $type = $event->{type} // '';
    return 'body' if $type eq "$scope_type.request";
    return 'disconnect' if $type eq "$scope_type.disconnect";
    Carp::croak("unexpected request-body event '$type' on $scope_type scope");
}

1;
