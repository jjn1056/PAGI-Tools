package PAGI::Endpoint::SSE;

use strict;
use warnings;

use Future;
use Future::AsyncAwait;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use PAGI::SSE;
use PAGI::Utils::Scope ();

# Keepalive interval in seconds (0 = disabled)
sub keepalive_interval { 0 }

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

async sub handle {
    my ($self, $sse) = @_;

    # Configure keepalive if specified. This runs before the stream has
    # started, so keepalive() defers rather than sending immediately --
    # sse.keepalive is illegal pre-start (DEVIATION D-1); PAGI::SSE records
    # it here and arms it (sends the real event) itself once start() runs,
    # whether that's on_connect's default start below or a start triggered
    # from inside on_connect. keepalive() is still async (it may send), so
    # await it rather than leaving a fire-and-forget Future (PAGI
    # applications must await all $send calls).
    my $keepalive = $self->keepalive_interval;
    if ($keepalive > 0) {
        await $sse->keepalive($keepalive);
    }

    # Register disconnect callback
    if ($self->can('on_disconnect')) {
        $sse->on_close(sub {
            $self->on_disconnect($sse);
            return;
        });
    }

    # Call on_connect if defined
    if ($self->can('on_connect')) {
        await Future->wrap($self->on_connect($sse));
    } else {
        # Default: just start the stream
        await $sse->start;
    }

    # If on_connect already ended the exchange (e.g. $sse->decline for an
    # auth-gate 401), there is no stream to wait on: run() would no-op on
    # its own (it's gated on is_closed too), but guard explicitly so intent
    # is clear and a post-decline sse.start can never be sent from here.
    return if $sse->is_closed;

    # Wait for disconnect
    await $sse->run;
}

sub to_app {
    my ($invocant) = @_;
    my $endpoint = blessed($invocant) ? $invocant : $invocant->new;

    return async sub {
        my ($scope, $receive, $send) = @_;

        my $type = $scope->{type} // '';
        croak "Expected sse scope, got '$type'" unless $type eq 'sse';

        PAGI::Utils::Scope::_compatible_cached_scope_object(
            $scope, 'pagi.sse', 'PAGI::SSE',
        );
        my $sse = PAGI::SSE->new($scope, $receive, $send);

        await $endpoint->handle($sse);
        return;
    };
}

1;

__END__

=head1 NAME

PAGI::Endpoint::SSE - Class-based Server-Sent Events endpoint handler

=head1 SYNOPSIS

    package MyApp::Notifications;
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;

    sub keepalive_interval { 30 }

    async sub on_connect {
        my ($self, $sse) = @_;
        my $user_id = $sse->scope->{user_id};

        await $sse->send_event(
            event => 'connected',
            data  => { user_id => $user_id },
        );
    }

    sub on_disconnect {
        my ($self, $sse) = @_;
        # Cleanup subscriptions
    }

    # Use with PAGI server
    my $app = MyApp::Notifications->to_app;

=head1 DESCRIPTION

PAGI::Endpoint::SSE provides a class-based approach to handling
Server-Sent Events connections with lifecycle hooks.

C<to_app> constructs a class receiver once immediately, or retains an
instance receiver exactly as supplied. Configuration and long-lived
dependencies may therefore live on the endpoint object. Each C<PAGI::SSE>
protocol object and all connection-local state must stay local to C<handle>,
because one endpoint instance can serve concurrent connections.

=head1 LIFECYCLE METHODS

=head2 on_connect

    async sub on_connect {
        my ($self, $sse) = @_;
        await $sse->send_event(data => 'Hello!');
    }

Called before the SSE stream starts -- I<not> after. C<handle()> calls
C<on_connect> in place of its own default (which just calls C<< $sse->start
>>), so the stream is B<not> already running when C<on_connect> runs; it
starts lazily the first time you call C<start>, C<send>, C<send_json>, or
C<send_event> inside it (or explicitly via C<< await $sse->start >>).
Use this to send initial events and set up subscriptions.

Because the stream has not started yet, C<on_connect> is also the supported
place to reject the request outright with a real HTTP response instead of
streaming -- an auth gate, for example:

    use PAGI::Response qw(text_response);

    async sub on_connect {
        my ($self, $sse) = @_;

        unless (authorized($sse)) {
            await $sse->decline(
                text_response('Unauthorized', status => 401),
            );
            return;
        }

        await $sse->send_event(event => 'connected', data => { ok => 1 });
    }

See L<PAGI::SSE/decline>. C<handle()> checks C<< $sse->is_closed >> after
C<on_connect> returns and skips waiting for disconnect when it's already
true, so declining is a clean, single response -- C<sse.start> is never
sent.

=head2 on_disconnect

    sub on_disconnect {
        my ($self, $sse) = @_;
        # Cleanup subscriptions
    }

Called when connection closes. This is synchronous (not async).

=head1 CLASS METHODS

=head2 keepalive_interval

    sub keepalive_interval { 30 }

Seconds between keepalive pings. Set to 0 to disable (default).

C<handle> requests this keepalive before the stream has started (before
C<on_connect> runs), which is otherwise illegal on the wire -- see
L<PAGI::SSE/keepalive>'s deferred-arm behavior, which is what makes this
safe. If C<on_connect> declines instead of starting the stream, the request
is silently dropped rather than sent (see L<PAGI::SSE/decline>).

=head2 to_app

    my $app = MyEndpoint->to_app;

    my $endpoint = MyEndpoint->new(hub => $hub);
    my $app = $endpoint->to_app;

Returns a PAGI-compatible async coderef. Calling it on a class constructs one
endpoint immediately; calling it on an instance retains that exact instance
for every connection.

=head1 RECIPES

=head2 Multi-Process Broadcasting with Redis

The simple in-memory subscriber pattern only works with a single process:

    my %subscribers;  # Lost when worker dies, not shared between workers

For multi-process deployments (e.g., C<pagi-server --workers 4>), use Redis
pub/sub as a message bus between workers. Each worker keeps its own local
subscriber hash with real connection objects, and Redis broadcasts messages
between workers.

    package MyApp::Events;
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;
    use JSON::MaybeXS qw(encode_json decode_json);

    my %subscribers;  # Local to this process
    my $redis;        # Redis connection

    # Call this once at server startup (e.g., in lifespan handler)
    sub setup_redis {
        my ($redis_url) = @_;
        $redis = Redis::Async->new(server => $redis_url);

        # Subscribe to channel - forward to local connections
        $redis->subscribe('events', sub {
            my ($message) = @_;
            my $data = decode_json($message);
            _local_broadcast($data);
        });
    }

    # Broadcast to local process connections only
    sub _local_broadcast {
        my ($message) = @_;
        for my $sse (values %subscribers) {
            $sse->try_send_json($message);
        }
    }

    # Public API: publish to Redis (all workers receive it)
    sub broadcast {
        my ($message) = @_;
        $redis->publish('events', encode_json($message));
    }

    # Track local connections
    my $sub_id = 0;

    async sub on_connect {
        my ($self, $sse) = @_;
        my $id = ++$sub_id;
        $subscribers{$id} = $sse;

        await $sse->send_event(
            event => 'connected',
            data  => { subscriber_id => $id },
        );
    }

    sub on_disconnect {
        my ($self, $sse) = @_;
        delete $subscribers{$_} for grep { $subscribers{$_} == $sse } keys %subscribers;
    }

Now when any worker calls C<broadcast()>, the message goes to Redis, and
every worker (including itself) receives it and forwards to their local
SSE connections.

Setup Redis in your lifespan handler:

    my $app = async sub {
        my ($scope, $receive, $send) = @_;

        if ($scope->{type} eq 'lifespan') {
            my $event = await $receive->();
            if ($event->{type} eq 'lifespan.startup') {
                MyApp::Events::setup_redis('redis://localhost:6379');
                await $send->({ type => 'lifespan.startup.complete' });
            }
            # ... shutdown handling
            return;
        }

        # ... route to SSE endpoint
    };

=head1 SEE ALSO

L<PAGI::SSE>, L<PAGI::Endpoint::HTTP>,
L<PAGI::Endpoint::WebSocket>

=cut
