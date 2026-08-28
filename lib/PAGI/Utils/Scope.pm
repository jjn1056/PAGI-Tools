package PAGI::Utils::Scope;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed refaddr);

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

sub _compatible_cached_scope_object {
    my ($scope, $key, $expected_class) = @_;
    my $cached = $scope->{$key};
    my $reusable = (blessed($cached) // '') eq $expected_class
        && $cached->can('scope');
    if ($reusable) {
        my $cached_scope = eval { $cached->scope };
        $reusable = 0
            if $@
                || ref($cached_scope) ne 'HASH'
                || refaddr($cached_scope) != refaddr($scope);
    }
    delete $scope->{$key} unless $reusable;
    return $reusable ? $cached : undef;
}

1;
