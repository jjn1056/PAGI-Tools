package PAGI::Response::Text;

use strict;
use warnings;

use Carp ();

use Encode qw(encode FB_CROAK);
use parent 'PAGI::Response';

=encoding UTF-8

=head1 NAME

PAGI::Response::Text - buffered UTF-8 plain-text response

=head1 SYNOPSIS

    use PAGI::Response qw(response);
    my $response = response('Text', "Hello, \x{263A}");

    # The same, by class -- what response() calls:
    use PAGI::Response::Text;
    my $same = PAGI::Response::Text->new("Hello, \x{263A}");

=head1 DESCRIPTION

Buffers one defined character scalar, or an object that stringifies to one
(L<PAGI::Response/VALUES FROM OTHER CODE>), as strict UTF-8 bytes with
C<text/plain; charset=utf-8>. Common C<status>, C<headers> (any shape
L<PAGI::Response/new> takes), and C<content_type> options are accepted. Use byte-oriented L<PAGI::Response> when
the caller must choose another encoding explicitly.


=head2 Content type

The body is always UTF-8, so a custom content type without a charset gets
C<; charset=utf-8>, however it is given (the C<content_type> option, a
Content-Type pair in C<headers>, C<content_type> or C<header> later):
C<< response('Text', $s, content_type => 'text/csv') >> sends
C<text/csv; charset=utf-8>. A type that already names a charset is kept as
given, and JSON types (C<application/json>, C<*+json>) get none, since JSON is
UTF-8 by definition.

=cut

sub default_content_type { 'text/plain; charset=utf-8' }

# The body is always UTF-8, so a custom content type declares it.
sub content_type {
    my ($self, @type) = @_;
    # Stringified before the charset is added; the caller's own undef still
    # means the default type, but an object that gives no string croaks.
    if (@type && defined $type[0]) {
        defined($type[0] = PAGI::Utils::_string_value($type[0]))
            or Carp::croak('Content-Type must be a scalar');
    }
    @type = (PAGI::Response::_with_utf8_charset($type[0]))
        if @type && defined $type[0] && !ref $type[0];
    return $self->SUPER::content_type(@type);
}

sub render {
    my ($self, $value) = @_;
    $value = PAGI::Utils::_stringified($value);
    die 'Text response body must be a defined Unicode scalar'
        unless defined $value && !ref($value);
    return encode('UTF-8', $value, FB_CROAK);
}

1;
