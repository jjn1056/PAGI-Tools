package PAGI::Response;

use strict;
use warnings;
use v5.32;
use feature 'signatures';
no warnings 'experimental::signatures';

use Future::AsyncAwait;
use Carp qw(croak);

our $VERSION = '0.01';

sub new ($class, $send = undef) {
    croak("send is required") unless $send;
    croak("send must be a coderef") unless ref($send) eq 'CODE';

    my $self = bless {
        send    => $send,
        _status => 200,
        _headers => [],
        _sent   => 0,
    }, $class;

    return $self;
}

sub status ($self, $code) {
    croak("Status must be a number between 100-599")
        unless defined $code && $code =~ /^\d+$/ && $code >= 100 && $code <= 599;
    $self->{_status} = $code;
    return $self;
}

sub header ($self, $name, $value) {
    push @{$self->{_headers}}, [$name, $value];
    return $self;
}

sub content_type ($self, $type) {
    # Remove existing content-type headers
    $self->{_headers} = [grep { lc($_->[0]) ne 'content-type' } @{$self->{_headers}}];
    push @{$self->{_headers}}, ['content-type', $type];
    return $self;
}

1;
