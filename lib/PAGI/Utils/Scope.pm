package PAGI::Utils::Scope;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed);

sub is_scope_source {
    my ($value) = @_;
    return 1 if ref($value) eq 'HASH' && !blessed($value);
    return blessed($value) && $value->can('scope') ? 1 : 0;
}

sub scope_from_source {
    my ($owner, @arguments) = @_;
    croak "$owner requires exactly one scope hashref or object with scope()"
        unless @arguments == 1;
    my $source = $arguments[0];
    my $scope = ref($source) eq 'HASH' && !blessed($source)
        ? $source
        : blessed($source) && $source->can('scope')
            ? $source->scope
            : undef;
    croak "$owner requires an unblessed scope hashref or object with scope()"
        unless ref($scope) eq 'HASH' && !blessed($scope);
    return $scope;
}

1;
