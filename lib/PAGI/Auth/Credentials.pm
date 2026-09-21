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

=head1 DESCRIPTION

Credentials are the grants attached to a result, not the token or other
credentials presented by a client. Use L<PAGI::Auth> result helpers to create
one; the private C<_new> is not an application constructor. The supplied scopes
arrayref is retained with normal Perl reference semantics.

=head1 METHODS

=head2 scopes

Returns the live scopes arrayref. Changes to it or to the originally supplied
arrayref are visible to subsequent membership checks. Each element supplied at
construction must be a defined scalar; grants compare exactly and are case
sensitive.

=head2 has

Accepts exactly one defined scalar scope and returns a boolean for an exact,
case-sensitive match. Missing, extra, undefined, or reference arguments are
errors.

=head2 has_any

Accepts zero or more defined scalar scopes and returns a boolean. An empty
requirement is false; invalid entries are errors.

=head2 has_all

Accepts zero or more defined scalar scopes and returns a boolean. An empty
requirement is true; invalid entries are errors.

=cut
