package PAGITest::OwnLoopApp;

# An application committed to an event loop of its own: every wait is a timer
# on an IO::Async loop it holds, never Future::IO. Paths that reply late wait
# on the loop before the reply: /late-accept and /late-start before the
# handshake, /late-send between the handshake and the first message; /stuck
# never answers.

use strict;
use warnings;
use Exporter 'import';
use Future::AsyncAwait;
use IO::Async::Loop;

our @EXPORT_OK = qw(own_loop_app);

sub own_loop_app {
    my $loop = IO::Async::Loop->new;
    my $tick = sub { $loop->delay_future(after => 0.1) };

    return async sub {
        my ($scope, $receive, $send) = @_;
        my ($type, $path) = @{$scope}{qw(type path)};

        if ($type eq 'lifespan') {
            await $receive->();
            await $tick->();
            await $send->({ type => 'lifespan.startup.complete' });
            await $receive->();
            await $send->({ type => 'lifespan.shutdown.complete' });
        }
        elsif ($type eq 'http') {
            await($path eq '/stuck' ? $loop->delay_future(after => 60) : $tick->());
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'late' });
        }
        elsif ($type eq 'websocket') {
            await $receive->();
            await $tick->() if $path eq '/late-accept';
            await $send->({ type => 'websocket.accept' });
            await $tick->();
            await $send->({ type => 'websocket.send', text => 'late' });
            await $receive->();
        }
        elsif ($type eq 'sse') {
            await $tick->() if $path eq '/late-start';
            await $send->({ type => 'sse.start', status => 200, headers => [] });
            await $tick->();
            await $send->({ type => 'sse.send', data => 'late' });
            await $receive->();
        }
    };
}

1;
