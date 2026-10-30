package PAGI::Utils::_ProtocolHelpers;
use strict;
use warnings;
use Carp qw(croak);
use Future;
use Scalar::Util qw(blessed);
use PAGI::Utils ();
use PAGI::Routing::RequestResponse;

# Every send a protocol helper makes comes through here. PAGI::Spec::Www 0.7
# ("Sends Are Sequential") has the server keep a scope's sends in the order
# they were called, so each goes to the server at once and several producers
# on one connection need no queue. A send that dies is a failed Future, as
# from any send. Cancelling the returned Future leaves the server's send
# alone: PAGI::Spec advises against cancelling a send.
sub forward_send {
    my ($owner, $event) = @_;
    my $sent = eval { Future->wrap($owner->{send}->($event)) } // Future->fail($@);
    return $sent->without_cancel;
}

# Admission and helper cleanup use these public capabilities. A version string
# is diagnostic context, not proof that the connection implements the contract.
sub require_connection {
    my ($scope, $operation) = @_;
    my $connection = $scope->{'pagi.connection'};
    my $version = $scope->{pagi}{spec_version} // 'unspecified';
    my @required = qw(response_started is_connected on_end disconnect_reason disconnect_detail);
    push @required, qw(close_code close_reason) if $scope->{type} eq 'websocket';
    push @required, qw(end_future) if $scope->{type} eq 'sse';   # every() races it
    my @missing = blessed($connection)
        ? grep { !$connection->can($_) } @required : @required;
    croak "$operation requires pagi.connection capabilities " . join(', ', @missing)
        . " (server reports spec_version $version; current connection contract required)"
        if @missing;
    return $connection;
}

# A helper claims the connection the moment it issues its accept or start
# ('answering'), before it awaits that send: ownership is not when the send
# completes. It claims 'refusing' when it invokes its refusal application
# (see refuse), and is refusing once that refusal's response has started.
# These answer for a connection still open; once it has ended, each helper
# keeps the behaviour it has for an ended connection.
sub refusing {
    my ($helper) = @_;
    my $connection = $helper->{scope}{'pagi.connection'};
    return ($helper->{_claim} // '') eq 'refusing'
        && $connection->is_connected && $connection->response_started;
}

sub answered_by_another {
    my ($helper) = @_;
    my $connection = $helper->{scope}{'pagi.connection'};
    return !$helper->{_claim}
        && $connection->is_connected && $connection->response_started;
}

# Why this helper may not drive the connection, or undef when it may.
sub ownership_refusal {
    my ($helper) = @_;
    return 'this helper is refusing the connection' if refusing($helper);
    return 'this connection was answered by another helper; use that one'
        if answered_by_another($helper);
    return undef;
}

sub prepare_refusal {
    my ($helper, $label, @targets) = @_;
    my $connection = require_connection($helper->{scope}, $label);
    croak "$label requires exactly one Request handler or app object"
        unless @targets == 1;
    my ($target) = @targets;
    PAGI::Utils::_validate_app_value($target, $label, 'Request handler');
    my $refused = ownership_refusal($helper);
    croak $refused if $refused;
    croak "$label requires a live connection with no response started"
        unless $connection->is_connected && !$connection->response_started;
    return ref($target) eq 'CODE'
        ? PAGI::Routing::RequestResponse->new(handler => $target)
        : $target;
}

# Runs a helper's refusal application on the original scope, receive and
# send, and returns its Future. The helper claims 'refusing' from here; a
# refusal that settles with no response started answered nothing, so its
# claim is dropped and the helper may try again.
sub refuse {
    my ($helper, $app) = @_;
    my $connection = $helper->{scope}{'pagi.connection'};
    $helper->{_claim} = 'refusing';
    my $refusal = PAGI::Utils::invoke_app(
        $app, $helper->{scope}, $helper->{receive}, $helper->{send},
    );
    $refusal->on_ready(sub {
        delete $helper->{_claim}
            if ($helper->{_claim} // '') eq 'refusing' && !$connection->response_started;
    });
    return $refusal;
}
1;

__END__

=head1 NAME

PAGI::Utils::_ProtocolHelpers - Private plumbing shared by PAGI::WebSocket and PAGI::SSE

=head1 DESCRIPTION

The functions L<PAGI::WebSocket> and L<PAGI::SSE> share: forwarding their
sends to the server, checking the connection supports what they need,
deciding whether a helper may drive the connection, and preparing and
running a refusal.

This package is a private implementation detail. Application code must not
depend on its name or interface; it may change without a compatibility
layer.

=head1 FUNCTIONS

=head2 forward_send

    await PAGI::Utils::_ProtocolHelpers::forward_send($helper, $event);

Sends C<$event> through C<< $helper->{send} >> at once (the server keeps a
scope's sends in call order) and returns a Future for it. A send that dies
is a failed Future; cancelling the returned Future never cancels the send
the server holds.

=head2 require_connection

    my $connection = PAGI::Utils::_ProtocolHelpers::require_connection($scope, $operation);

Returns C<< $scope->{'pagi.connection'} >>, or croaks naming C<$operation>
and the capabilities it lacks.

=head2 refusing, answered_by_another, ownership_refusal

    my $refused = PAGI::Utils::_ProtocolHelpers::ownership_refusal($helper);

A helper's C<_claim> is C<'answering'> from the moment it issues its
C<websocket.accept> or C<sse.start>, before that send completes, and
C<'refusing'> while it runs its refusal application (see L</refuse>).
C<refusing> is true while the connection is open, its response has started
and the helper's claim is C<'refusing'>; C<answered_by_another> is true
while the connection is open, its response has started, and the helper
holds no claim.
C<ownership_refusal> returns the message a helper croaks with in either
case ("this helper is refusing the connection", "this connection was
answered by another helper; use that one"), or C<undef> when the helper may
drive the connection.

=head2 prepare_refusal

    my $app = PAGI::Utils::_ProtocolHelpers::prepare_refusal($helper, $label, $target);

Checks that C<$helper> can still send a refusal (it is not refusing already,
no other helper answered, the connection is live and no response started)
and returns C<$target> as an application: a code reference becomes a
Request handler.

=head2 refuse

    await PAGI::Utils::_ProtocolHelpers::refuse($helper, $app);

Runs C<$app> on the helper's original scope, receive and send and returns
its Future, with the helper's claim C<'refusing'>. A refusal that settles
(or is cancelled) with no response started drops the claim, so the helper
may try again.

=cut
