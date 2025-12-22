package PAGI::Endpoint::HTTP;

use strict;
use warnings;
use v5.32;
use feature 'signatures';
no warnings 'experimental::signatures';

use Future::AsyncAwait;
use Carp qw(croak);

our $VERSION = '0.01';

# Factory class methods - override in subclass for customization
sub request_class  { 'PAGI::Request' }
sub response_class { 'PAGI::Response' }

sub new ($class, %args) {
    return bless \%args, $class;
}

1;
