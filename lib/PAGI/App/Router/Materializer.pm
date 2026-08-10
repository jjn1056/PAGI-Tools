package PAGI::App::Router::Materializer;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed refaddr);

sub new {
    my ($class) = @_;
    return bless {
        active     => {},
        completed  => {},
        placements => [],
    }, $class;
}

sub materialize {
    my ($self, $target, $placement) = @_;
    return $target if blessed($target)
        && $target->isa('PAGI::Routing::Router');

    my $is_app = blessed($target)
        && ($target->isa('PAGI::App::Router::Builder')
            || $target->isa('PAGI::App::Router'));
    my $is_endpoint = blessed($target)
        && $target->isa('PAGI::Endpoint::Router');
    croak 'router target must be an immutable Router, App Router, or Endpoint Router'
        unless ($is_app || $is_endpoint)
            && $target->can('_materialize_with');

    my $id = refaddr($target);
    return $self->{completed}{$id} if $self->{completed}{$id};
    croak $self->_cycle_message($placement)
        if $self->{active}{$id};

    $self->{active}{$id} = 1;
    push @{$self->{placements}}, $placement;
    my ($router, $error);
    {
        local $@;
        $router = eval { $target->_materialize_with($self) };
        $error = $@;
    }
    pop @{$self->{placements}};
    delete $self->{active}{$id};
    die $error if length $error;
    croak 'mutable router frontend did not materialize a PAGI::Routing::Router'
        unless blessed($router)
            && $router->isa('PAGI::Routing::Router');
    return $self->{completed}{$id} = $router;
}

sub _cycle_message {
    my ($self, $placement) = @_;
    my @placements = (@{$self->{placements}}, $placement);
    shift @placements
        if @placements && defined $placements[0]
            && $placements[0] eq '<root>';
    return 'router materialization cycle at placement chain '
        . join(' -> ', @placements);
}

1;

__END__

=head1 NAME

PAGI::App::Router::Materializer - Root-local mutable routing snapshot materializer

=head1 DESCRIPTION

This private helper owns active ancestry and completed mutable frontend
identities for one root snapshot operation. Immutable Routers pass through by
identity. A completed mutable frontend is reused by sibling placements, while
an active revisit fails with its declaration placement chain. All state is
discarded with the Materializer after the snapshot is built and never enters a
routing description or request scope.

=cut
