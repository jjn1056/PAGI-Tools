package PAGI::State::Deferred;
use strict;
use warnings;
use Carp qw(croak);
use Future;
use Scalar::Util qw(blessed refaddr weaken);

# A value in application state that PAGI::State's get builds instead of
# returning: the seam for lifetimes. A subclass implements resolve.
sub new {
    my ($class, $builder) = @_;
    croak "$class needs a builder coderef" unless ref $builder eq 'CODE';
    return bless { builder => $builder }, $class;
}

# ($state, $source) -> the value, or a Future of it. $state is the
# PAGI::State view the builder works through; $source what the asking view
# was made from.
sub resolve { croak ref($_[0]) . ' must implement resolve' }

sub _is_future { return blessed($_[0]) && $_[0]->isa('Future') }

# Keeps a built value in $slot->{$key}. A Future is kept while it is pending
# or done; one that fails or is cancelled is dropped, so the next get builds
# again, and everyone already waiting gets the outcome. The callback holds
# neither the Future nor the slot strongly: a request's cache that goes away
# frees what it kept.
sub _keep {
    my ($value, $slot, $key) = @_;
    $slot->{$key} = $value;
    return $value unless _is_future($value);
    my $id = refaddr($value);
    weaken(my $weak_slot = $slot);
    $value->on_ready(sub {
        my ($build) = @_;
        return if $build->is_done;
        delete $weak_slot->{$key}
            if $weak_slot && exists $weak_slot->{$key}
            && refaddr($weak_slot->{$key}) == $id;
    });
    return $value;
}

# What a caller gets for a kept value. A ready Future as it is: cancelling it
# does nothing. A pending one through a Future of the caller's own, settled
# from the build, so a caller that goes away cancels only its own.
sub _shared {
    my ($value, $name) = @_;
    return $value unless _is_future($value) && !$value->is_ready;
    my $copy = Future->new;
    $value->on_ready(sub {
        my ($build) = @_;
        return if $copy->is_ready;                         # the caller went away
        if    ($build->is_done)      { $copy->done($build->result) }
        elsif ($build->is_cancelled) { $copy->fail("the build of state key '$name' was cancelled") }
        else                         { $copy->fail($build->failure) }
    });
    return $copy;
}

package PAGI::State::Deferred::Singleton;
our @ISA = ('PAGI::State::Deferred');

# Kept here, in the object every request's copy of the state shares by
# reference -- never by replacing the key, which would change only one copy.
sub resolve {
    my ($self, $state) = @_;
    $self->{name} //= $state->_building_key;
    return PAGI::State::Deferred::_shared($self->{kept}{value}, $self->{name})
        if exists $self->{kept}{value};
    # Built through a view with no request: a per_request value asked for
    # here would be kept for the life of the worker. The caller gets what was
    # built even when _keep drops it at once (an already-failed Future).
    my $value = $self->{builder}->($state->_without_request);
    $state->_expire_with($value);
    PAGI::State::Deferred::_keep($value, $self->{kept} //= {}, 'value');
    return PAGI::State::Deferred::_shared($value, $self->{name});
}

sub built { return exists $_[0]{kept}{value} ? 1 : 0 }

# What was kept, as a caller gets it from get: the value, or a Future of
# its own for a build still running.
sub value {
    my ($self) = @_;
    Carp::croak('this singleton has not been built: check built first')
        unless exists $self->{kept}{value};
    return PAGI::State::Deferred::_shared($self->{kept}{value}, $self->{name});
}

package PAGI::State::Deferred::PerRequest;
our @ISA = ('PAGI::State::Deferred');

# Kept in the request's own copy of the state, which the server makes per
# request and every middleware layer shares.
sub resolve {
    my ($self, $state, $source) = @_;
    my $name  = $state->_building_key;
    my $cache = $state->_request_cache;
    my $id    = Scalar::Util::refaddr($self);
    return PAGI::State::Deferred::_shared($cache->{$id}, $name) if exists $cache->{$id};
    my $value = $self->{builder}->($state, $source);
    $state->_expire_with($value);
    PAGI::State::Deferred::_keep($value, $cache, $id);
    return PAGI::State::Deferred::_shared($value, $name);
}

package PAGI::State::Deferred::Factory;
our @ISA = ('PAGI::State::Deferred');

# Nothing kept: the caller owns what it gets.
sub resolve {
    my ($self, $state, $source) = @_;
    my $value = $self->{builder}->($state, $source);
    $state->_expire_with($value);
    return $value;
}

package PAGI::State::Deferred::RequestCache;

# A request's per_request values, in its own copy of the state. When the
# request goes away, a build still pending is cancelled: nothing can ask for
# it again, its I/O is not wanted, and a dropped suspended build would warn.
sub DESTROY {
    my ($self) = @_;
    return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
    for my $value (values %$self) {
        $value->cancel
            if PAGI::State::Deferred::_is_future($value) && !$value->is_ready;
    }
}

1;

__END__

=head1 NAME

PAGI::State::Deferred - A value in application state built when asked for

=head1 SYNOPSIS

    use PAGI::State qw(singleton per_request factory);

    $state->{db}   = singleton   { my ($state) = @_; MyDB->connect };
    $state->{who}  = per_request { my ($state, $source) = @_; ... };
    $state->{form} = factory     { my ($state, $source) = @_; MyForm->new };

A lifetime of your own:

    package MyApp::Pooled;
    use parent -norequire, 'PAGI::State::Deferred';

    sub resolve {
        my ($self, $state, $source) = @_;
        ...    # the value, or a Future of it
    }

=head1 DESCRIPTION

A value stored in application state that L<PAGI::State>'s C<get> builds
instead of returning: C<get> calls its C<resolve>. The three lifetimes in
L<PAGI::State/LIFETIMES> are subclasses; nothing else in PAGI::Tools knows
about them.

=head1 METHODS

=head2 new

    my $deferred = $class->new($builder);

Takes the builder coderef; dies without one.

=head2 resolve

    my $value = $deferred->resolve($state, $source);

Returns the value, or a L<Future> of it. C<$state> is the L<PAGI::State> view
the builder works through; C<$source> is what the asking view was made from
(a L<PAGI::Request>, L<PAGI::WebSocket> or L<PAGI::SSE>, or a scope hashref).
A subclass implements it; the base dies.

=head1 LIFETIMES

=over 4

=item * C<PAGI::State::Deferred::Singleton> (from C<singleton>): built once per
worker and kept in the object, which every request's copy of the state shares.
It has C<built>, true once a build has started and has not failed or been
cancelled, and C<value>, what was kept as C<get> gives it (dies if not built).

=item * C<PAGI::State::Deferred::PerRequest> (from C<per_request>): built once
per request and kept in that request's own copy of the state; a build still
pending when the request goes away is cancelled.

=item * C<PAGI::State::Deferred::Factory> (from C<factory>): built on every
C<get>; nothing is kept.

=back

A kept L<Future> is shared through a Future per caller, and dropped if it
fails or is cancelled; see L<PAGI::State/LIFETIMES>.

=head1 SEE ALSO

L<PAGI::State>

=cut
