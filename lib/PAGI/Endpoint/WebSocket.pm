package PAGI::Endpoint::WebSocket;

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
sub websocket_class { 'PAGI::WebSocket' }

# Encoding: 'text', 'bytes', or 'json'
sub encoding { 'text' }

sub new ($class, %args) {
    return bless \%args, $class;
}

async sub handle ($self, $ws) {
    # Call on_connect if defined
    if ($self->can('on_connect')) {
        await $self->on_connect($ws);
    } else {
        # Default: accept the connection
        await $ws->accept;
    }

    # Register disconnect callback
    if ($self->can('on_disconnect')) {
        $ws->on_close(sub ($code, $reason = undef) {
            $self->on_disconnect($ws, $code, $reason);
        });
    }

    # Handle messages based on encoding
    if ($self->can('on_receive')) {
        my $encoding = $self->encoding;

        if ($encoding eq 'json') {
            await $ws->each_json(async sub ($data) {
                await $self->on_receive($ws, $data);
            });
        } elsif ($encoding eq 'bytes') {
            await $ws->each_bytes(async sub ($data) {
                await $self->on_receive($ws, $data);
            });
        } else {
            # Default: text
            await $ws->each_text(async sub ($data) {
                await $self->on_receive($ws, $data);
            });
        }
    } else {
        # No on_receive, just wait for disconnect
        await $ws->run;
    }
}

1;
