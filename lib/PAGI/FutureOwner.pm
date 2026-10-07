package PAGI::FutureOwner;
use strict;
use warnings;
use Carp qw(croak);
use Future;
use Scalar::Util qw(blessed refaddr);

sub new {
    my ($class, %args) = @_;
    croak 'on_failure must be a coderef'
        if defined $args{on_failure} && ref($args{on_failure}) ne 'CODE';
    return bless {
        on_failure => $args{on_failure},
        pending    => {},
        failure    => undef,
        waiters    => [],
    }, $class;
}

sub adopt {
    my ($self, $future) = @_;
    croak 'adopt requires a Future' unless blessed($future) && $future->isa('Future');
    my $key = refaddr $future;
    $self->{pending}{$key} = $future;
    # The callback holds the owner and the owner holds the Future, so an
    # adopted Future stays alive until it settles even when nothing else
    # refers to either.
    $future->on_ready(sub {
        my ($ready) = @_;
        delete $self->{pending}{$key};
        $self->_failed($ready) if $ready->is_failed;
        $self->_wake unless %{ $self->{pending} };
    });
    return $future;
}

sub settled {
    my ($self) = @_;
    my $waiter = Future->new;
    push @{ $self->{waiters} }, $waiter;
    $self->_wake unless %{ $self->{pending} };
    return $waiter;
}

sub _failed {
    my ($self, $ready) = @_;
    if (my $on_failure = $self->{on_failure}) {
        $on_failure->($ready->failure);
        return;
    }
    $self->{failure} ||= [ $ready->failure ];
    return;
}

sub _wake {
    my ($self) = @_;
    for my $waiter (splice @{ $self->{waiters} }) {
        next if $waiter->is_ready;
        $self->{failure} ? $waiter->fail(@{ $self->{failure} }) : $waiter->done;
    }
    return;
}

1;

__END__

=head1 NAME

PAGI::FutureOwner - Own the Futures you start, until they settle

=head1 SYNOPSIS

    use PAGI::FutureOwner;

    # Work an application starts and does not wait for.
    my $background = PAGI::FutureOwner->new(
        on_failure => sub { warn "background task failed: $_[0]" },
    );
    $background->adopt(send_welcome_email($email));

    # In lifespan.shutdown: wait for what is still running.
    await $background->settled;

=head1 DESCRIPTION

A Future that nothing holds is lost: its work may never finish, and its
failure has nowhere to go. C<< ->retain >> keeps such a Future alive, but
nothing can wait for it or hear that it failed.

A PAGI::FutureOwner B<adopts> Futures instead. It holds each one until it
settles, and C<settled> tells the owner's own owner when all of them have.
Owners compose: C<settled> is an ordinary Future, so it can itself be
awaited or adopted by a longer-lived owner.

L<PAGI::WebSocket> and L<PAGI::SSE> each use one for the work they start
(C<on_close> cleanup, C<close>, best-effort sends); see their C<finished>.

=head1 METHODS

=head2 new

    my $owner = PAGI::FutureOwner->new;
    my $owner = PAGI::FutureOwner->new(on_failure => sub { my ($error) = @_; ... });

C<on_failure>, if given, is called with each adopted Future's failure as it
happens, and C<settled> then never fails. That suits a long-lived owner, such
as an application's background work. Without it, the first failure is held
and C<settled> fails with it. C<on_failure> is called from inside the failing
Future's callbacks and must not die. It croaks if C<on_failure> is given and
is not a code reference.

=head2 adopt

    my $future = $owner->adopt($future);

Holds C<$future> until it is done, failed or cancelled, and returns it.
Neither the owner nor the Future needs any other reference meanwhile. A
cancelled Future counts as settled and is not a failure. It croaks unless
given a Future.

=head2 settled

    await $owner->settled;

Returns a Future that is done once no adopted Future is pending. Work adopted
while waiting -- by an adopted Future before it completes, say -- is waited
for too; work adopted after the last pending Future has settled is not. It
fails with the first failure held (see C<on_failure>) instead.

=cut
