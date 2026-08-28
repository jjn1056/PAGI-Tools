package PAGI::Response::HTML;

use strict;
use warnings;

use Encode qw(encode FB_CROAK);
use Exporter qw(import);
use parent 'PAGI::Response';

=encoding UTF-8

=head1 NAME

PAGI::Response::HTML - buffered UTF-8 HTML response

=head1 SYNOPSIS

    my $response = PAGI::Response::HTML->new('<p>Hello</p>');

=head1 DESCRIPTION

Renders one character scalar as strict UTF-8 bytes with an HTML UTF-8 content
type.

=cut

our @EXPORT_OK = qw(html_response);

sub html_response {
    return PAGI::Response::HTML->new(@_);
}

sub default_content_type { 'text/html; charset=utf-8' }

sub render {
    my ($self, $value) = @_;
    die 'HTML response body must be a defined Unicode scalar'
        unless defined $value && !ref($value);
    return encode('UTF-8', $value, FB_CROAK);
}

1;
