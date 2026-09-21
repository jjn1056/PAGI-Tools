package PAGI::Auth::Credentials;

use strict;
use warnings;

use Carp qw(croak);

sub _new {
    my ($class, $scopes) = @_;

    croak 'scopes must be an array reference' unless ref($scopes) eq 'ARRAY';
    for my $scope (@$scopes) {
        croak 'each scope must be a defined scalar'
            unless defined($scope) && !ref($scope);
    }

    return bless { scopes => $scopes }, $class;
}

sub scopes { return $_[0]{scopes} }

sub has {
    my ($self, @required) = @_;
    croak 'has requires exactly one scope' unless @required == 1;
    croak 'scope must be a defined scalar'
        unless defined($required[0]) && !ref($required[0]);
    return scalar(grep { $_ eq $required[0] } @{$self->{scopes}}) ? 1 : 0;
}

sub has_any {
    my ($self, @required) = @_;
    my @matches = map { $self->has($_) } @required;
    return scalar(grep { $_ } @matches) ? 1 : 0;
}

sub has_all {
    my ($self, @required) = @_;
    my @matches = map { $self->has($_) } @required;
    return scalar(grep { !$_ } @matches) ? 0 : 1;
}

1;

=head1 NAME

PAGI::Auth::Credentials - granted authentication scopes

=head1 METHODS

=head2 scopes

Returns the live scopes array reference supplied at construction.

=head2 has

Returns whether one exact, case-sensitive scope is granted.

=head2 has_any

Returns whether any supplied scope is granted. An empty requirement is false.

=head2 has_all

Returns whether every supplied scope is granted. An empty requirement is true.

C<_new> is private; applications receive credentials through an authentication
result.

=cut
