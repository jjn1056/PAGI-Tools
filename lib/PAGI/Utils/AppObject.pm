package PAGI::Utils::AppObject;

use strict;
use warnings;

sub new {
    my ($class, $app) = @_;
    my $self = bless \$app, $class;
    Internals::SvREADONLY($$self, 1);
    return $self;
}

sub to_app {
    return ${$_[0]};
}

1;

__END__

=head1 NAME

PAGI::Utils::AppObject - Object form of a native PAGI application coderef

=head1 DESCRIPTION

An app object is an instantiated object with a C<to_app> method. This concrete
app object is returned by L<PAGI::Utils/as_app_object> when a native
three-argument PAGI coderef must occupy an object endpoint position.

Call C<as_app_object> rather than constructing this class directly.

=head1 METHOD

=head2 to_app

Returns the exact native application coderef supplied to
C<as_app_object>. Repeated calls return the same coderef.

=cut
