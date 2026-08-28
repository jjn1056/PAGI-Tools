package PAGI::Response::Empty;

use strict;
use warnings;

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
    push @pairs, status => 204 unless exists $options->{status};
    return $class->SUPER::new('', @pairs);
}

sub default_content_type { undef }

1;
