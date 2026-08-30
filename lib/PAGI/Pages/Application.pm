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
