package PAGI::Utils::Middleware;

use strict;
use warnings;
use Carp qw(croak);
use Exporter qw(import);
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(blessed);
use PAGI::Headers ();

our @EXPORT_OK = qw(clone_scope wrap_send wrap_receive wrap_response_headers record_receive);

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

# The reader records each event it delivers; the replay delivers the
# recording, then continues with the live receive. Reading once the replay
# has begun would interleave the two orders, so it fails instead.
sub record_receive {
    my ($receive, %options) = @_;
    croak 'record_receive receive must be a coderef' unless ref($receive) eq 'CODE';
    my $buffer = delete $options{buffer};
    croak "record_receive has unknown option '$_'" for sort keys %options;
    $buffer //= PAGI::Utils::Middleware::_EventList->new;
    croak 'record_receive buffer must be an object with append and take'
        unless blessed($buffer) && $buffer->can('append') && $buffer->can('take');

    my ($replay_begun, $recording_delivered);
    my $reading = async sub {
        croak 'record_receive: the recording receive was called after the replay began'
            if $replay_begun;
        my $event = await $receive->();
        await $buffer->append($event);
        return $event;
    };
    my $replaying = async sub {
        $replay_begun = 1;
        unless ($recording_delivered) {
            my $event = await $buffer->take;
            return $event if defined $event;
            $recording_delivered = 1;
        }
        return await $receive->();
    };
    return ($reading, $replaying);
}

# record_receive's default buffer: the events, in memory, in order.
package PAGI::Utils::Middleware::_EventList {
    sub new    { return bless [], $_[0] }
    sub append { push @{$_[0]}, $_[1]; return Future->done }
    sub take   { return Future->done(shift @{$_[0]}) }
}

1;

__END__

=head1 NAME

PAGI::Utils::Middleware - Functional middleware authoring helpers

=head1 SYNOPSIS

    use Future::AsyncAwait;
    use PAGI::Utils::Middleware qw(clone_scope wrap_send wrap_receive
                                   wrap_response_headers record_receive);

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

C<record_receive> is for middleware that reads the request body: it keeps
what the middleware reads, so the application can receive it again.

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

=head2 record_receive

    my ($reading, $replaying) = record_receive($receive);
    my ($reading, $replaying) = record_receive($receive, buffer => $buffer);

For middleware that reads the request body before the application runs --
to decide something from it, say -- and then hands the application the same
body. A body can be received only once, so a middleware that reads it and
then gives the application the same C<$receive> leaves the application
nothing to read: an application that reads it waits for an event the client
will never send. Read through C<$reading> instead, and give the application
C<$replaying>:

    my ($reading, $replaying) = record_receive($receive);
    my $form = await PAGI::Request->new($scope, $reading)->form_params;
    ...
    await $app->($scope, $replaying, $send);

C<$reading> receives from C<$receive> and keeps each event it delivers.
C<$replaying> delivers the kept events, in order, then continues with
C<$receive> -- so the application also gets the C<http.disconnect> when the
client goes. The application receives the whole body however much the
middleware read: all of it, part of it, or none. A disconnect the middleware
read is delivered again too. Each kept event is released as it is
delivered. Calling C<$reading> once C<$replaying> has been called fails: the
two would interleave.

The events are kept in memory. C<buffer> gives somewhere else: a
L<PAGI::Utils::ReceiveBuffer::TempFile>, which holds 64KB in memory and
spools the rest to a temporary file, or any object with its C<append> and
C<take> methods, such as one that keeps the events in Redis (see
L<PAGI::Utils::ReceiveBuffer::TempFile/WRITING A BUFFER>). Give each request
a buffer of its own.

Each middleware that reads the body records it again, from the replay it
was given. Events held in memory are handed on as the same hashes, so the
body is held once however many middleware record it; spooled events are
copies. When the application never calls C<$replaying> to the end -- it
answers without reading the body, say -- the buffer is released when the
request is over.

To hand the application a I<different> body, write the receive yourself
(examples/modify-form-post); to watch or change the body as it streams,
wrap C<$receive> instead of reading ahead
(L<PAGI::Middleware/Reading the request body>).

=head3 Why this helper exists

Reading the whole body in middleware and then handing the application a
receive that delivers it is a pattern the Starlette community teaches for
pure ASGI middleware. The sources, kept here so the reason for this helper
is not lost:

=over 4

=item * Aditya Raj, "How to use middleware in FastAPI and Starlette",
Honeybadger Developer Blog, 2026-08-28,
L<https://www.honeybadger.io/blog/starlette-middleware/>: "Pure ASGI
middlewares are also the preferred choice when you want to modify the
request or response body"; "we buffer it via C<receive>, then supply a
C<receive_wrapper> that replays the modified body downstream".

=item * examples/modify-form-post, ported from a Starlette
C<ModifyFormPostMiddleware> (its C<app.py>), which reads a whole form and
hands the application a receive with a rewritten body.

=back

The hand-written receives in both get details wrong that this
helper gets right: each returned the body on every call, so an application
waiting for C<http.disconnect> got the body again; the article's never
passes on the client's receive, so the disconnect never arrives; and it
leaves C<Content-Length> stale after changing the body. Starlette's
documentation also shows the other shape, a receive wrapped to watch or
change the events as the application reads them ("Inspecting or modifying
the request" in its middleware guide, citing msgpack-asgi); its
C<RequestBodyLimitMiddleware> checks the body that way.

=cut
