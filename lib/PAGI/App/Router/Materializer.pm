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
        completion_frames => [],
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
    croak 'snapshot target must be an immutable Router or mutable Router frontend'
        unless ($is_app || $is_endpoint)
            && $target->can('_materialize_with');

    my $id = refaddr($target);
    return $self->{completed}{$id} if $self->{completed}{$id};
    croak $self->_cycle_message($placement)
        if $self->{active}{$id};

    push @{$self->{completion_frames}}, [];
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
    if (length $error) {
        $self->_rollback_completion_frame;
        die $error;
    }
    unless (blessed($router)
            && $router->isa('PAGI::Routing::Router')) {
        $self->_rollback_completion_frame;
        croak 'mutable router frontend did not materialize a PAGI::Routing::Router';
    }

    $self->{completed}{$id} = $router;
    push @{$self->{completion_frames}[-1]}, $id;
    $self->_commit_completion_frame;
    return $router;
}

sub _rollback_completion_frame {
    my ($self) = @_;
    my $created = pop @{$self->{completion_frames}};
    delete @{$self->{completed}}{@$created} if @$created;
    return;
}

sub _commit_completion_frame {
    my ($self) = @_;
    my $created = pop @{$self->{completion_frames}};
    push @{$self->{completion_frames}[-1]}, @$created
        if @{$self->{completion_frames}};
    return;
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
identities for one mutable frontend snapshot operation. Immutable Routers pass
through by identity. App Router callback children use the same identity cache
as explicit App or Endpoint Router roots. A completed frontend is reused by
defensive sibling references, while an active malformed revisit fails with its
declaration placement chain. Completed identities first created beneath a
failed materialization are rolled back; identities completed before that
operation remain reusable. All state is discarded after the snapshot is built
and never enters a routing description or request scope.

=cut
