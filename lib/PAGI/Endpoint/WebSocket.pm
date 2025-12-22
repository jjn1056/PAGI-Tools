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

1;
