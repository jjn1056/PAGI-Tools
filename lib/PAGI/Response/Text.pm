package PAGI::Response::Text;

use strict;
use warnings;

use Encode qw(encode FB_CROAK);
use Exporter qw(import);
use parent 'PAGI::Response';

=encoding UTF-8

=head1 NAME

PAGI::Response::Text - buffered UTF-8 plain-text response

=head1 SYNOPSIS

    use PAGI::Response::Text qw(text_response);
    my $response = PAGI::Response::Text->new("Hello, \x{263A}");
    my $same = text_response("Hello, \x{263A}");

=head1 DESCRIPTION

Buffers one defined character scalar as strict UTF-8 bytes with
C<text/plain; charset=utf-8>. Common C<status>, flat C<headers>, and
C<content_type> options are accepted. Use byte-oriented L<PAGI::Response> when
the caller must choose another encoding explicitly.

=cut

our @EXPORT_OK = qw(text_response);

sub text_response {
    return PAGI::Response::Text->new(@_);
}

sub default_content_type { 'text/plain; charset=utf-8' }

sub render {
    my ($self, $value) = @_;
    die 'Text response body must be a defined Unicode scalar'
        unless defined $value && !ref($value);
    return encode('UTF-8', $value, FB_CROAK);
}

1;
