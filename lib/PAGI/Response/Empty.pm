package PAGI::Response::Empty;

use strict;
use warnings;

use Carp qw(croak);
use parent 'PAGI::Response';

=encoding UTF-8

=head1 NAME

PAGI::Response::Empty - buffered zero-byte response

=head1 SYNOPSIS

    use PAGI::Response qw(response);
    my $response = response('Empty', status => 205);

    # The same, by class -- what response() calls:
    use PAGI::Response::Empty;
    my $same = PAGI::Response::Empty->new(status => 205);

=head1 DESCRIPTION

Owns a buffered zero-byte body. Status defaults to 204 and no Content-Type is
added or permitted. C<headers> are accepted in any shape L<PAGI::Response/new>
takes; framing fields forbidden by a
1xx, 204, or 304 status are omitted on emission.

=cut

sub new {
    my ($class, @pairs) = @_;
    my $options = PAGI::Response::_parse_options(@pairs);
    croak 'Empty response does not permit Content-Type'
        if exists $options->{content_type};
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
    return $self->SUPER::_wire_headers($length);
}

1;
