package PAGI::HTTPConnection::_Protocol;
use strict;
use warnings;
use parent 'PAGI::HTTPConnection';
use Carp qw(croak);
use Future::AsyncAwait;
use Future;
use PAGI::Utils::_ProtocolHelpers ();
use PAGI::FutureOwner;


# A subclass supplies _scope_type (the scope type it serves) and
# _initial_state (its first connection state); _refresh_connection is its
# own and runs once the shared fields exist.
sub new {
    my ($class, $scope, $receive, $send) = @_;

    croak "$class requires scope hashref"
        unless $scope && ref($scope) eq 'HASH';
    croak "$class requires receive coderef"
        unless $receive && ref($receive) eq 'CODE';
    croak "$class requires send coderef"
        unless $send && ref($send) eq 'CODE';
    my $type = $class->_scope_type;
    croak "$class requires scope type '$type', got '$scope->{type}'"
        unless ($scope->{type} // '') eq $type;
    # PAGI::Spec::Www 0.6: servers provide pagi.connection on every scope.
    PAGI::Utils::_ProtocolHelpers::require_connection($scope, $class);

    # One object per call: nothing is cached in the scope, so a handler
    # keeps the object it was given (SUBCLASSING).
    my $self = $class->SUPER::new($scope);
    $self->{receive} = $receive;
    $self->{send} = $send;
    $self->{_state} = $class->_initial_state;
    $self->{_on_close} = [];
    $self->{_on_error} = [];

    $self->{_cleanup_future} = Future->new;
    $self->{_owner} = PAGI::FutureOwner->new;
    $self->{_ended} = Future->new;
    # The connection owns this helper until end. Cleanup then belongs to the
    # helper's owner, so whoever awaits finished waits for it too.
    $scope->{'pagi.connection'}->on_end(sub {
        $self->_refresh_connection;
        $self->_start_close_callbacks;
        $self->{_ended}->done;
        return;
    });
    $self->_refresh_connection;
    return $self;
}

# A helper drives only what it answered (PAGI::Utils::_ProtocolHelpers holds
# the claim rules): while its own refusal is in progress, or once another
# helper answered the open connection, it fails locally.
sub _refusing { PAGI::Utils::_ProtocolHelpers::refusing($_[0]) }
sub _answered_by_another { PAGI::Utils::_ProtocolHelpers::answered_by_another($_[0]) }

sub disconnect_detail {
    my ($self) = @_;
    $self->_refresh_connection;
    return $self->{_disconnect_detail};
}

# State accessors
sub connection_state { my $self = shift; $self->_refresh_connection; return $self->{_state} }

sub is_closed {
    my $self = shift;
    return $self->connection_state eq 'closed';
}

# Outbound flow-control introspection (delegates to the pagi.transport handle)
sub buffered_amount {
    my $self = shift;
    my $t = $self->{scope}{'pagi.transport'};
    return 0 unless $t;
    return $t->buffered_amount;
}

sub high_water_mark {
    my $self = shift;
    my $t = $self->{scope}{'pagi.transport'};
    return undef unless $t;
    return $t->high_water_mark;
}

sub low_water_mark {
    my $self = shift;
    my $t = $self->{scope}{'pagi.transport'};
    return undef unless $t;
    return $t->low_water_mark;
}

sub on_high_water {
    my ($self, $cb) = @_;
    my $t = $self->{scope}{'pagi.transport'};
    $t->on_high_water($cb) if $t && $t->can('on_high_water');
    return $self;
}

sub on_drain {
    my ($self, $cb) = @_;
    my $t = $self->{scope}{'pagi.transport'};
    $t->on_drain($cb) if $t && $t->can('on_drain');
    return $self;
}

sub is_writable {
    my $self = shift;
    my $t = $self->{scope}{'pagi.transport'};
    return 1 unless $t;
    my $high = $t->high_water_mark;
    return 1 unless defined $high;
    return $t->buffered_amount < $high ? 1 : 0;
}

# Internal state setter
sub _set_state {
    my ($self, $state) = @_;
    $self->{_state} = $state;
}

# Register callback to run on disconnect/close
sub on_close {
    my ($self, $callback) = @_;
    # Once the connection has ended, a callback runs now, after any still
    # running, as the spec's on_end does.
    return $self->_run_late_close_callback($callback) if $self->{_close_callbacks_ran};
    push @{$self->{_on_close}}, $callback;
    return $self;
}

sub _run_late_close_callback {
    my ($self, $callback) = @_;
    $self->{_close_chain} = $self->{_owner}->adopt(
        $self->_late_close_worker($self->{_close_chain}, $callback));
    return $self;
}

# Internal: run all on_close callbacks exactly once, as work the helper owns
sub _run_close_callbacks {
    my ($self) = @_;
    $self->_start_close_callbacks;
    return $self->{_cleanup_future}->without_cancel;
}

sub _start_close_callbacks {
    my ($self) = @_;
    return if $self->{_close_callbacks_ran};
    $self->{_close_callbacks_ran} = 1;
    my $completion = $self->{_cleanup_future};
    my $worker = $self->{_owner}->adopt($self->_close_callbacks_worker);
    $self->{_close_chain} = $worker;
    # The cleanup Future means the callbacks have run; a callback's failure
    # is reported once, through finished.
    $worker->on_ready(sub { $completion->done unless $completion->is_ready });
    return;
}

# Resolves to the helper once its scope has ended and all the work it
# started -- its on_close callbacks included -- has settled; fails with the
# first on_close failure.
async sub finished {
    my ($self) = @_;
    # A scope never accepted (or started) ends only when the application
    # returns, so waiting for its end would wait for the caller itself.
    await $self->{_ended}->without_cancel if $self->_ends_without_application;
    my $settled = eval { await $self->{_owner}->settled; 1 };
    my $error = $@;
    $self->{_finished} = 1;
    die $error unless $settled;
    return $self;
}

# Register callback to run on errors
sub on_error {
    my ($self, $callback) = @_;
    push @{$self->{_on_error}}, $callback;
    return $self;
}

# Keeps a Future the helper returned to its caller until it settles, so
# finished waits for it. Its failure is the caller's to see: the owner keeps
# only its completion. The callback also holds the caller's Future, so a
# caller may drop it.
sub _keep {
    my ($self, $future) = @_;
    my $completion = $future->else_done;
    my $held = $future;
    $completion->on_ready(sub { undef $held });
    $self->{_owner}->adopt($completion);
    return $future;
}

sub try_send_json { my $self = shift; return $self->_keep($self->_try_send_json(@_)) }

1;

__END__

=head1 NAME

PAGI::HTTPConnection::_Protocol - Private base class of PAGI::WebSocket and PAGI::SSE

=head1 DESCRIPTION

The state and lifetime L<PAGI::WebSocket> and L<PAGI::SSE> share, between
them and L<PAGI::HTTPConnection>: the constructor's argument checks and the
fields it builds (the send and receive coderefs, the connection state, the
on_close and on_error callbacks, the owner of the helper's work and the
Futures that settle C<finished>), the methods that read them, and the
C<pagi.transport> flow-control readers. Each subclass supplies its scope
type, its first connection state and how it refreshes from
C<pagi.connection>. The public methods are documented in each subclass.

This class is a private implementation detail. Application code must not
depend on its name or interface; it may change without a compatibility
layer.

=cut
