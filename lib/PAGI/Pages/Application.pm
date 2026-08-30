package PAGI::Pages::Application;

use strict;
use warnings;

use Carp qw(croak);
use Future::AsyncAwait;
use Scalar::Util qw(blessed);

use PAGI::Utils qw(invoke_app);

sub new {
    my ($class, %args) = @_;
    my $policy = $args{policy};
    my $descriptor_factory = $args{descriptor_factory};

    croak 'PAGI::Pages::Application requires one Pages policy and descriptor factory'
        unless keys(%args) == 2
            && blessed($policy) && $policy->isa('PAGI::Pages')
            && ref($descriptor_factory) eq 'CODE';

    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        croak 'PAGI::Pages application requires an unblessed HTTP scope hashref'
            unless ref($scope) eq 'HASH' && !blessed($scope);
        my $type = $scope->{type};
        croak 'PAGI::Pages application scope type is required'
            unless defined($type) && !ref($type) && length($type);
        croak "PAGI::Pages application requires HTTP scope; received '$type'"
            unless $type eq 'http';

        my $descriptor = $descriptor_factory->($scope);
        my $response = $policy->_response_for($scope, $descriptor);
        return await invoke_app($response, $scope, $receive, $send);
    };

    my $self = bless \$app, $class;
    Internals::SvREADONLY($$self, 1);
    return $self;
}

sub to_app {
    return ${$_[0]};
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

The application rejects lifespan, WebSocket, SSE, and unknown scopes before
receive, rendering, or send. It does not handle lifespan. Automatic server
lifespan mode may treat that exception as a decline; strict mode rejects it.

=head1 METHODS

=head2 to_app

Returns the retained native HTTP application coderef.

=cut
