package PAGI::Auth::Challenge;

use strict;
use warnings;
use Hash::Util qw(lock_hashref);

sub _new {
    my ($class, %fields) = @_;
    my $self = bless \%fields, $class;
    lock_hashref($self);
    return $self;
}

sub scheme       { return $_[0]{scheme} }
sub header_value { return $_[0]{header_value} }
sub _kind        { return $_[0]{kind} }
sub _error       { return $_[0]{error} }

1;
