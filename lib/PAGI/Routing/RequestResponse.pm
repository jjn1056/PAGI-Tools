package PAGI::Routing::RequestResponse;

use strict;
use warnings;

use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use PAGI::Request;
use PAGI::Utils qw(invoke_app);

sub new {
    my ($class, %args) = @_;
    my $handler = $args{handler};

    croak 'request_response handler must be a coderef'
        unless keys(%args) == 1 && exists($args{handler})
            && ref($handler) eq 'CODE';

    return bless { handler => $handler }, $class;
}

sub to_app {
    my ($self) = @_;
    my $handler = $self->{handler};

    return async sub {
        my ($scope, $receive, $send) = @_;
        my $type = $scope->{type} // '';
        croak "PAGI::Routing::RequestResponse requires HTTP scope; received '$type'"
            unless $type eq 'http';

        my $request = PAGI::Request->new($scope, $receive);
        my $handler_result = $handler->($request);
        my $returned = await Future->wrap($handler_result);
        PAGI::Utils::_validate_app_value(
            $returned,
            'request endpoint must return a PAGI application:',
        );
        return await invoke_app($returned, $scope, $receive, $send);
    };
}

1;
