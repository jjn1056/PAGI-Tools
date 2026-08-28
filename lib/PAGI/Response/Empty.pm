package PAGI::Response::Empty;

use strict;
use warnings;

use Carp qw(croak);
use Exporter qw(import);
use parent 'PAGI::Response';

=encoding UTF-8

=head1 NAME

PAGI::Response::Empty - buffered zero-byte response

=head1 SYNOPSIS

    my $response = PAGI::Response::Empty->new;

=head1 DESCRIPTION

Owns a zero-byte body.  Its HTTP status defaults to 204 and it does not add a
default Content-Type header.

=cut

our @EXPORT_OK = qw(empty_response);

sub empty_response {
    return PAGI::Response::Empty->new(@_);
}

sub new {
    my ($class, @pairs) = @_;
    my $options = PAGI::Response::_parse_options(@pairs);
    croak 'Empty response does not permit Content-Type'
        if exists $options->{content_type};
    _reject_content_type_header($options->{headers}) if exists $options->{headers};
    push @pairs, status => 204 unless exists $options->{status};
    return $class->SUPER::new('', @pairs);
}

sub default_content_type { undef }

sub _allows_body_forbidden_status { 1 }

sub header {
    my ($self, $name, $value) = @_;
    return $self->SUPER::header($name) if @_ == 2;
    croak 'Empty response does not permit Content-Type'
        if defined($name) && !ref($name) && lc($name) eq 'content-type';
    return $self->SUPER::header($name, $value);
}

sub content_type {
    my ($self, $value) = @_;
    return $self->SUPER::content_type if @_ == 1;
    croak 'Empty response does not permit Content-Type' if defined $value;
    return $self->SUPER::content_type(undef);
}

sub _wire_headers {
    my ($self, $length) = @_;
    croak 'Empty response does not permit Content-Type' if $self->has_content_type;
    my $headers = $self->SUPER::_wire_headers($length);
    my $status = $self->status;
    return $headers unless $status >= 100 && $status < 200 || $status == 204 || $status == 304;
    @$headers = grep {
        my $name = lc $_->[0];
        $name ne 'content-length' && $name ne 'transfer-encoding';
    } @$headers;
    return $headers;
}

sub _reject_content_type_header {
    my ($headers) = @_;
    return unless ref($headers) eq 'ARRAY' && @$headers % 2 == 0;
    for (my $index = 0; $index < @$headers; $index += 2) {
        my $name = $headers->[$index];
        croak 'Empty response does not permit Content-Type'
            if defined($name) && !ref($name) && lc($name) eq 'content-type';
    }
    return;
}

1;
