package PAGI::Routing::Middleware;

use strict;
use warnings;
use Carp qw(croak);

sub new {
    my ($class, $factory, @args) = @_;

    croak 'middleware requires a factory, object, or class name'
        unless defined $factory;
    croak 'middleware configuration must be key/value pairs'
        if @args % 2;

    my %config = @args;
    return bless {
        factory => $factory,
        config  => { %config },
    }, $class;
}

sub factory { $_[0]->{factory} }
sub config  { return { %{$_[0]->{config}} } }

1;

__END__

=head1 NAME

PAGI::Routing::Middleware - Immutable declarative middleware description

=head1 SYNOPSIS

    my $logging = PAGI::Routing::Middleware->new(
        'PAGI::Middleware::AccessLog', format => 'combined',
    );

=head1 METHODS

=head2 new

    PAGI::Routing::Middleware->new($factory_or_object_or_class, %config)

Stores the middleware factory and a shallow copy of its configuration.

=head2 factory

Returns the original factory, object, or class name.

=head2 config

Returns a shallow copy of the configuration hash.

=cut
