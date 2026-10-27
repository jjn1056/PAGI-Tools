package PAGI::Exception::RequestBody;

use strict;
use warnings;
use PAGI::Exception::HTTP ();
# An HTTP error: one catch entry for PAGI::Exception::HTTP answers it too.
our @ISA = ('PAGI::Exception::HTTP');
use overload
    '""'     => sub { $_[0]{message} },
    bool     => sub { 1 },
    fallback => 1;

sub new {
    my ($class, %args) = @_;
    return bless {
        status_code => $args{status_code} // 400,
        reason      => $args{reason},
        message     => $args{message},
        cause       => $args{cause},
        headers     => [],
    }, $class;
}

sub throw { my $class = shift; die $class->new(@_) }

sub status_code { $_[0]{status_code} }
sub reason      { $_[0]{reason} }
sub message     { $_[0]{message} }
sub client_message { $_[0]{message} }
sub cause       { $_[0]{cause} }

1;

__END__

=head1 NAME

PAGI::Exception::RequestBody - A request body the client got wrong

=head1 SYNOPSIS

    # Usually nothing: a Compose application answers 400 (or 413) by itself.
    my $data = await $request->json;

    # One handler choosing its own response:
    my $data;
    unless (eval { $data = await $request->json; 1 }) {
        my $error = $@;
        die $error unless ref $error && $error->isa('PAGI::Exception::RequestBody');
        return response('JSON', { error => 'Send a JSON object.' }, status => 400);
    }

=head1 DESCRIPTION

L<PAGI::Request>'s buffered body helpers -- C<json>, C<text> and
C<form_params> (with C<strict>), and the multipart parsing behind
C<form_params> and C<uploads> -- throw this object when the body itself is
wrong: it is the client's error, not the application's.

It is a L<PAGI::Exception::HTTP>, with no C<headers> of its own, so a
C<catch> entry for C<PAGI::Exception::HTTP> answers it too, and one for this
class answers it first. It has a C<status_code> method, so
L<PAGI::Middleware::ErrorHandler> -- which
every L<PAGI::Compose> application has at its root -- answers with that status
and its C<client_message> as plain text, and treats it as a handled outcome,
not a server error: it is not re-raised, and an ErrorHandler C<handler> never
sees it. An application can catch it in a handler, or give ErrorHandler a
C<catch> entry for this class; see L<PAGI::Tools::Cookbook/"Bad request
bodies">.

It stringifies to its C<message>, so code that matches the text of these
errors keeps working.

=head1 METHODS

=head2 status_code

400 for a body that cannot be read (C<invalid_json>, C<invalid_encoding>,
C<invalid_multipart>, and C<invalid_body> for one longer than its own
Content-Length); 413 for a body over a configured limit
(C<too_large>); 415 for text in a charset Perl does not know
(C<unsupported_charset>), or a body in a media type the route does not take
(C<unsupported_media_type>, thrown by the application, as in the Cookbook's
"Accept JSON and a form on one route").

=head2 reason

One of C<invalid_json>, C<invalid_encoding>, C<invalid_multipart>,
C<invalid_body>, C<too_large>, C<unsupported_charset>,
C<unsupported_media_type>.

=head2 message

A sentence safe to show the client.

=head2 client_message

The same sentence as C<message>, under the name L<PAGI::ErrorContext> shows
to clients: a sentence safe to send.

=head2 cause

The underlying error (for example the JSON decoder's message), for logs.
Undefined when the message says everything.

=head2 new, throw

    PAGI::Exception::RequestBody->throw(
        status_code => 400, reason => 'invalid_json',
        message => 'The request body is not valid JSON.', cause => $@,
    );

C<status_code> defaults to 400.

=head1 SEE ALSO

L<PAGI::Request>, L<PAGI::Middleware::ErrorHandler>

=cut
