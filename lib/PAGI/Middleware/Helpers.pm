package PAGI::Middleware::Helpers;

use strict;
use warnings;
use Carp qw(croak);
use Exporter qw(import);
use Future;
use Future::AsyncAwait;

our @EXPORT_OK = qw(clone_scope wrap_send wrap_receive);

sub clone_scope {
    my ($scope, $changes) = @_;

    croak 'clone_scope scope must be a hash reference'
        unless ref($scope) eq 'HASH';
    croak 'clone_scope changes must be a hash reference'
        unless ref($changes) eq 'HASH';

    return { %$scope, %$changes };
}

sub wrap_send {
    my ($send, $interceptor) = @_;

    croak 'wrap_send send must be a coderef'
        unless ref($send) eq 'CODE';
    croak 'wrap_send interceptor must be a coderef'
        unless ref($interceptor) eq 'CODE';

    return async sub {
        my ($event) = @_;
        my $returned = $interceptor->($event, $send);
        return await Future->wrap($returned);
    };
}

sub wrap_receive {
    my ($receive, $interceptor) = @_;

    croak 'wrap_receive receive must be a coderef'
        unless ref($receive) eq 'CODE';
    croak 'wrap_receive interceptor must be a coderef'
        unless ref($interceptor) eq 'CODE';

    return async sub {
        my $returned = $interceptor->($receive);
        return await Future->wrap($returned);
    };
}

1;

__END__

=head1 NAME

PAGI::Middleware::Helpers - Functional middleware authoring helpers

=head1 SYNOPSIS

    use Future::AsyncAwait;
    use PAGI::Middleware::Helpers qw(clone_scope wrap_send wrap_receive);

    my $inner_scope = clone_scope($scope, { authenticated => 1 });

    my $wrapped_send = wrap_send($send, async sub {
        my ($event, $downstream) = @_;
        return if $event->{type} eq 'app.drop';
        await $downstream->({ %$event, inspected => 1 });
    });

=head1 DESCRIPTION

These optional exports support middleware written as plain functions. Wrapper
construction is synchronous and performs no I/O. The returned callbacks run
only when called and invoke only the supplied interceptor; they never delegate
automatically or inspect event types.

An interceptor controls whether, when, and how often it calls its downstream
callback. Downstream completion and backpressure remain attached to the
wrapper only when the interceptor returns or awaits that downstream result.
The wrappers are event-family neutral and may observe any event family received
by the enclosing middleware.

=head1 FUNCTIONS

=head2 clone_scope

    my $clone = clone_scope($scope, \%changes);

Returns a defensive shallow top-level clone. Changed keys override original
keys, while referenced values remain shared.

=head2 wrap_send

    my $wrapped = wrap_send($send, $interceptor);

Returns an async callback. On invocation, the interceptor receives the event
and original send callback. Its immediate or Future result is normalized and
awaited.

=head2 wrap_receive

    my $wrapped = wrap_receive($receive, $interceptor);

Returns an async callback. On invocation, the interceptor receives the original
receive callback. It can pull, replace, filter, or synthesize events. Its
immediate or Future result is normalized and awaited.

=cut
