package PAGI::Endpoint::SSE;

use strict;
use warnings;
use v5.32;
use feature 'signatures';
no warnings 'experimental::signatures';

use Future::AsyncAwait;
use Carp qw(croak);
use Module::Load qw(load);

our $VERSION = '0.01';

# Factory class method - override in subclass for customization
sub sse_class { 'PAGI::SSE' }

# Keepalive interval in seconds (0 = disabled)
sub keepalive_interval { 0 }

sub new ($class, %args) {
    return bless \%args, $class;
}

async sub handle ($self, $sse) {
    # Configure keepalive if specified
    my $keepalive = $self->keepalive_interval;
    if ($keepalive > 0) {
        $sse->keepalive($keepalive);
    }

    # Register disconnect callback
    if ($self->can('on_disconnect')) {
        $sse->on_close(sub {
            $self->on_disconnect($sse);
        });
    }

    # Call on_connect if defined
    if ($self->can('on_connect')) {
        await $self->on_connect($sse);
    } else {
        # Default: just start the stream
        await $sse->start;
    }

    # Wait for disconnect
    await $sse->run;
}

sub to_app ($class) {
    my $sse_class = $class->sse_class;
    load($sse_class);

    return async sub ($scope, $receive, $send) {
        my $endpoint = $class->new;
        my $sse = $sse_class->new($scope, $receive, $send);

        await $endpoint->handle($sse);
    };
}

1;
