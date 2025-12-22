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

1;
