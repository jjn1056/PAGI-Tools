package PAGI::Response::HTML;

use strict;
use warnings;

use Encode qw(encode FB_CROAK);
use parent 'PAGI::Response';

=encoding UTF-8

=head1 NAME

PAGI::Response::HTML - buffered UTF-8 HTML response

=head1 SYNOPSIS

    use PAGI::Response qw(response);
    my $response = response('HTML', '<p>Hello</p>');

    # The same, by class -- what response() calls:
    use PAGI::Response::HTML;
    my $same = PAGI::Response::HTML->new('<p>Hello</p>');

=head1 DESCRIPTION

Buffers one defined character scalar as strict UTF-8 bytes with
C<text/html; charset=utf-8>. Common C<status>, flat C<headers>, and
C<content_type> options are accepted. The class encodes markup but does not
escape or sanitize it.


=head2 Content type

The body is always UTF-8, so a custom content type without a charset gets
C<; charset=utf-8>, whether it is given to the constructor or set later:
C<< response('HTML', $s, content_type => 'text/csv') >> sends
C<text/csv; charset=utf-8>. A type that already names a charset is kept as
given, and JSON types (C<application/json>, C<*+json>) get none, since JSON is
UTF-8 by definition.

=cut

sub default_content_type { 'text/html; charset=utf-8' }

# The body is always UTF-8, so a custom content type declares it.
sub content_type {
    my ($self, @type) = @_;
    @type = (PAGI::Response::_with_utf8_charset($type[0]))
        if @type && defined $type[0] && !ref $type[0];
    return $self->SUPER::content_type(@type);
}

sub render {
    my ($self, $value) = @_;
    die 'HTML response body must be a defined Unicode scalar'
        unless defined $value && !ref($value);
    return encode('UTF-8', $value, FB_CROAK);
}

1;
