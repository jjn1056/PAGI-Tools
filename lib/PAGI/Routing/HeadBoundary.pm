package PAGI::Routing::HeadBoundary;

use strict;
use warnings;
use Carp qw(croak);
use Future;
use Scalar::Util qw(refaddr);

my $SCOPE_KEY = "\0PAGI::Routing::HeadBoundary";
my $MARKER = sub { return };

sub prepare {
    my ($class, $scope, $send) = @_;

    croak 'HEAD boundary scope must be a hashref'
        unless ref($scope) eq 'HASH';
    croak 'HEAD boundary send must be a coderef'
        unless ref($send) eq 'CODE';

    return ($scope, $send)
        unless ($scope->{type} // 'http') eq 'http'
            && ($scope->{method} // '') eq 'HEAD';

    my $candidate = $scope->{$SCOPE_KEY};
    return ($scope, $send)
        if ref($candidate) && refaddr($candidate) == refaddr($MARKER);

    my $inner_scope = { %$scope };
    $inner_scope->{$SCOPE_KEY} = $MARKER;
    return ($inner_scope, $class->_wire_send($send));
}

sub _wire_send {
    my ($class, $send) = @_;
    my $terminal_sent = 0;

    return sub {
        my ($event) = @_;
        my $type = $event->{type} // '';

        return Future->done if $type eq 'http.response.trailers';

        if ($type eq 'http.response.body') {
            return Future->done if $terminal_sent || $event->{more};
            $terminal_sent = 1;
            return $send->({
                type => 'http.response.body',
                body => '',
                more => 0,
            });
        }

        return $send->($event);
    };
}

1;

__END__

=head1 NAME

PAGI::Routing::HeadBoundary - Internal shared HTTP HEAD wire boundary

=head1 DESCRIPTION

This internal utility is shared by declarative routing and L<PAGI::Compose>.
It is not application API.

=head2 prepare

    my ($inner_scope, $wire_send) =
        PAGI::Routing::HeadBoundary->prepare($scope, $send);

For HTTP HEAD, C<prepare> returns a shallow scope clone and a send adapter that
suppresses response bodies and trailers at the final wire boundary. For other
scopes it returns the original arguments. An idempotent private scope marker
prevents nested compatible compilers from installing a second boundary.
Callers and middleware must preserve unknown scope keys; the marker's key and
token are deliberately not public API.

=cut
