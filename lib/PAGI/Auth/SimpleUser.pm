package PAGI::Auth::SimpleUser;

use strict;
use warnings;

use Carp qw(croak);

sub new {
    my ($class, @args) = @_;
    croak 'SimpleUser options must be key/value pairs' if @args % 2;

    my %values;
    while (@args) {
        my ($name, $value) = splice(@args, 0, 2);
        croak 'SimpleUser option names must be defined scalars'
            unless defined($name) && !ref($name);
        croak "SimpleUser has unknown option '$name'"
            unless $name eq 'identity' || $name eq 'display_name';
        croak "SimpleUser has duplicate option '$name'" if exists $values{$name};
        $values{$name} = $value;
    }

    croak 'SimpleUser identity must be a defined scalar'
        unless exists($values{identity})
            && defined($values{identity})
            && !ref($values{identity});
    croak 'SimpleUser display_name must be a defined scalar'
        if exists($values{display_name})
            && (!defined($values{display_name}) || ref($values{display_name}));

    $values{display_name} = $values{identity}
        unless exists $values{display_name};
    return bless \%values, $class;
}

sub is_authenticated { return 1 }
sub identity         { return $_[0]{identity} }
sub display_name     { return $_[0]{display_name} }

1;

=head1 NAME

PAGI::Auth::SimpleUser - simple authenticated user value

=head1 CONSTRUCTION

=head2 new

  my $user = PAGI::Auth::SimpleUser->new(
      identity     => '42',
      display_name => 'Alice',
  );

C<identity> is required. C<display_name> is optional and defaults to the
identity.

=head1 METHODS

=head2 is_authenticated

Returns true.

=head2 identity

Returns the supplied identity.

=head2 display_name

Returns the supplied display name, or the identity when omitted.

=cut
