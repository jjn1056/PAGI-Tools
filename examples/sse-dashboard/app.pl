#!/usr/bin/env perl
#
# Live Dashboard using PAGI::SSE
#
# Demonstrates real-time server metrics streaming with:
# - Automatic keepalive for proxy compatibility
# - Reconnection support via Last-Event-ID
# - Multiple event types
#
# Run: pagi-server --app examples/sse-dashboard/app.pl --port 5000
# Open: http://localhost:5000/
#

use strict;
use warnings;
use Future::AsyncAwait;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use File::Basename qw(dirname);
use File::Spec;

use lib 'lib';
use PAGI::SSE;

# Shared state
my %subscribers;
my $next_id = 1;
my $event_id = 0;
my $loop;

# Metrics timer
my $metrics_timer;

sub start_metrics_broadcaster {
    return if $metrics_timer;

    $loop //= IO::Async::Loop->new;

    $metrics_timer = IO::Async::Timer::Periodic->new(
        interval => 2,
        on_tick  => sub {
            $event_id++;

            my $metrics = {
                cpu     => 20 + int(rand(60)),
                memory  => 40 + int(rand(40)),
                requests => int(rand(1000)),
                timestamp => time(),
            };

            for my $sub (values %subscribers) {
                $sub->{sse}->try_send_event(
                    event => 'metrics',
                    data  => $metrics,
                    id    => $event_id,
                );
            }
        },
    );

    $loop->add($metrics_timer);
    $metrics_timer->start;
}

sub stop_metrics_broadcaster {
    return unless $metrics_timer && !%subscribers;

    $metrics_timer->stop;
    $loop->remove($metrics_timer);
    $metrics_timer = undef;
}

# Static file serving
my $public_dir = File::Spec->catdir(dirname(__FILE__), 'public');

my %mime_types = (
    html => 'text/html; charset=utf-8',
    css  => 'text/css; charset=utf-8',
    js   => 'application/javascript; charset=utf-8',
);

async sub serve_static {
    my ($scope, $send, $path) = @_;

    $path = '/index.html' if $path eq '/';
    $path =~ s/\.\.//g;

    my $file_path = File::Spec->catfile($public_dir, $path);

    unless (-f $file_path && -r $file_path) {
        await $send->({ type => 'http.response.start', status => 404, headers => [] });
        await $send->({ type => 'http.response.body', body => 'Not Found' });
        return;
    }

    my ($ext) = $file_path =~ /\.(\w+)$/;
    my $content_type = $mime_types{lc($ext // '')} // 'text/plain';

    open my $fh, '<:raw', $file_path or die;
    local $/;
    my $content = <$fh>;
    close $fh;

    await $send->({
        type    => 'http.response.start',
        status  => 200,
        headers => [
            ['content-type', $content_type],
            ['content-length', length($content)],
        ],
    });
    await $send->({ type => 'http.response.body', body => $content });
}

# Main app
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    my $type = $scope->{type} // '';
    my $path = $scope->{path} // '/';

    # Handle lifespan
    if ($type eq 'lifespan') {
        while (1) {
            my $event = await $receive->();
            if ($event->{type} eq 'lifespan.startup') {
                await $send->({ type => 'lifespan.startup.complete' });
            }
            elsif ($event->{type} eq 'lifespan.shutdown') {
                await $send->({ type => 'lifespan.shutdown.complete' });
                last;
            }
        }
        return;
    }

    # SSE endpoint
    if ($type eq 'sse' && $path eq '/events') {
        my $sse = PAGI::SSE->new($scope, $receive, $send);

        my $sub_id = $next_id++;
        $subscribers{$sub_id} = { sse => $sse };

        # Enable keepalive
        $sse->keepalive(25);

        # Send welcome event
        await $sse->send_event(
            event => 'connected',
            data  => {
                subscriber_id => $sub_id,
                server_time   => time(),
            },
        );

        # Handle reconnection
        if (my $last_id = $sse->last_event_id) {
            await $sse->send_event(
                event => 'reconnected',
                data  => { last_id => $last_id },
            );
        }

        # Start broadcaster if first subscriber
        start_metrics_broadcaster();

        # Cleanup on disconnect
        $sse->on_close(sub {
            delete $subscribers{$sub_id};
            stop_metrics_broadcaster();
            print STDERR "SSE client $sub_id disconnected\n";
        });

        print STDERR "SSE client $sub_id connected\n";

        # Wait for disconnect
        await $sse->run;
        return;
    }

    # HTTP - serve static files
    if ($type eq 'http') {
        await serve_static($scope, $send, $path);
        return;
    }

    die "Unsupported scope type: $type";
};

$app;
