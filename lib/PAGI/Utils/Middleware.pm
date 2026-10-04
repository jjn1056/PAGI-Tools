package PAGI::Utils::Middleware;

use strict;
use warnings;
use Carp qw(croak);
use Exporter qw(import);
use Future;
use Future::AsyncAwait;
use PAGI::Headers ();

our @EXPORT_OK = qw(clone_scope wrap_send wrap_receive wrap_response_headers);

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

# The response start's headers are edited on a private copy, and a new event is
# sent: the event this layer was given, and everything it references, belong
# to the layer that built it, which may send the same structures again.
sub wrap_response_headers {
    my ($send, $editor) = @_;
    croak 'wrap_response_headers send must be a coderef' unless ref($send) eq 'CODE';
    croak 'wrap_response_headers editor must be a coderef' unless ref($editor) eq 'CODE';
    return async sub {
        my ($event) = @_;
        if (($event->{type} // '') eq 'http.response.start') {
            my $headers = PAGI::Headers->new($event->{headers} // []);
            await Future->wrap($editor->($headers, $event));
            $event = { %$event, headers => $headers->to_pairs };
        }
        return await Future->wrap($send->($event));
    };
}

1;

__END__

=head1 NAME

PAGI::Utils::Middleware - Functional middleware authoring helpers

=head1 SYNOPSIS

    use Future::AsyncAwait;
    use PAGI::Utils::Middleware qw(clone_scope wrap_send wrap_receive
                                   wrap_response_headers);

    my $inner_scope = clone_scope($scope, { authenticated => 1 });

    my $wrapped_send = wrap_send($send, async sub {
        my ($event, $downstream) = @_;
        return if $event->{type} eq 'app.drop';
        await $downstream->({ %$event, inspected => 1 });
    });

    my $with_header = wrap_response_headers($send, sub {
        my ($headers) = @_;
        $headers->set('X-Served-By', 'web-1');
    });

=head1 DESCRIPTION

These optional exports support middleware written as plain functions. Wrapper
construction is synchronous and performs no I/O.

C<wrap_send> and C<wrap_receive> are general: the returned callbacks run only
when called and invoke only the supplied interceptor; they never delegate
automatically or inspect event types. An interceptor controls whether, when,
and how often it calls its downstream callback. Downstream completion and
backpressure remain attached to the wrapper only when the interceptor returns
or awaits that downstream result. These two are event-family neutral and may
observe any event family received by the enclosing middleware.

C<wrap_response_headers> is specific: it acts only on C<http.response.start>,
passing every other event straight on.

Whichever you use, never modify an event you are given, or the header list
and pairs it carries: they belong to the layer that built them, which may send
them again (see L<PAGI::Spec/Middleware>). Send a new event instead.

=head1 FUNCTIONS

=head2 clone_scope

    my $clone = clone_scope($scope, \%changes);

Returns a defensive shallow top-level clone. Changed keys override original
keys, while referenced values remain shared. It validates and changes only
local in-memory state at the point it is called. It constructs no callback,
starts no request, and emits or awaits no protocol event.

=head2 wrap_send

    my $wrapped = wrap_send($send, $interceptor);

Returns an async callback. On invocation, the interceptor receives the event
and original send callback. Its immediate or Future result is normalized and
awaited. Calling C<wrap_send> validates/builds that callback synchronously and
does no I/O. Later invocation runs the interceptor for whatever event family
the enclosing middleware receives. Only the interceptor can emit, replace,
suppress, or expand events by calling the downstream send; delegation is not
automatic. Returning or awaiting downstream keeps completion, backpressure,
and failures attached.

=head2 wrap_receive

    my $wrapped = wrap_receive($receive, $interceptor);

Returns an async callback. On invocation, the interceptor receives the original
receive callback. It can pull, replace, filter, or synthesize events. Its
immediate or Future result is normalized and awaited. Calling C<wrap_receive>
validates/builds that callback synchronously and performs no receive. Later
invocation runs the interceptor; I/O occurs only if it calls the downstream
receive. The interceptor may await once or repeatedly, return a replacement,
or synthesize an event without I/O. Delegation is not automatic, and immediate
values plus Future failures propagate through the wrapper.

=head2 wrap_response_headers

    use PAGI::Utils::Middleware qw(wrap_response_headers);

    my $wrapped_send = wrap_response_headers($send, sub {
        my ($headers, $event) = @_;
        $headers->set('X-Runtime', $elapsed);
    });

Returns a send that, for each C<http.response.start>, calls C<$editor> with a
L<PAGI::Headers> copy of the response's headers and the event, then sends a
new event carrying the edited headers. The event it was given, its header
list and the pairs in it are never changed: they belong to whoever built them,
who may send them again (see L<PAGI::Spec/Middleware>). The event is passed to
the editor to read only -- its status, for example; do not modify it. Use C<set> to replace a
header, C<add> for one that repeats (C<Set-Cookie>), C<set_default> to keep a
value the response already has, and C<add_vary> for C<Vary>. The editor may
return a Future. Other events pass through unchanged.

=cut
