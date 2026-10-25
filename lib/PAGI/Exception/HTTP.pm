package PAGI::Exception::HTTP;

use strict;
use warnings;
use Carp qw(croak);
use PAGI::ErrorContext ();
use PAGI::Utils ();
use overload
    '""'     => sub { $_[0]->_as_string },
    bool     => sub { 1 },
    fallback => 1;

sub new {
    my ($class, $status, $client_message, @options) = @_;
    croak 'PAGI::Exception::HTTP status must be an integer from 400 to 599'
        unless defined($status) && !ref($status) && $status =~ /\A[45][0-9][0-9]\z/;
    croak 'PAGI::Exception::HTTP options must be name => value pairs' if @options % 2;
    my %options = @options;
    my $headers = exists $options{headers} ? delete $options{headers} : [];
    croak 'Unknown PAGI::Exception::HTTP option: ' . join(', ', sort keys %options) if %options;
    my ($pairs, $refused) = PAGI::Utils::_sendable_headers('PAGI::Exception::HTTP', $headers);
    croak $refused if $refused;
    return bless {
        status_code    => 0 + $status,
        client_message => $client_message,
        headers        => $pairs,
    }, $class;
}

sub throw { my $class = shift; die $class->new(@_) }

sub status_code    { $_[0]{status_code} }
sub client_message { $_[0]{client_message} }
sub headers        { [ map { [@$_] } @{ $_[0]{headers} } ] }

sub _as_string {
    my ($self) = @_;
    my $text = $self->{client_message};
    $text = PAGI::ErrorContext::_reason_phrase($self->{status_code})
        unless defined($text) && length($text);
    return "$self->{status_code} $text";
}

1;

__END__

=head1 NAME

PAGI::Exception::HTTP - An HTTP error to throw from deep in an application

=head1 SYNOPSIS

    use PAGI::Exception::HTTP;

    sub find_note {
        my ($id) = @_;
        return $NOTES{$id} // PAGI::Exception::HTTP->throw(404, "no such note: $id");
    }

=head1 DESCRIPTION

Prefer returning a response: C<return response('JSON', ..., status => 404)>.
Throwing is the escape hatch for code far from the handler, such as a model
that finds nothing.

This class carries a status and an optional client-safe message, and nothing
about how the error looks. L<PAGI::Middleware::ErrorHandler>, which every
L<PAGI::Compose> application has at its root, answers it with that status:
its stock page shows the message for a 4xx and the reason phrase for a 5xx,
since server errors carry no client text; an ErrorHandler C<catch> entry for
this class or for the status answers it otherwise. A thrown HTTP error is
handled -- by an entry, or by the built-in answer -- and is not re-raised,
whatever its status, as Starlette's C<ExceptionMiddleware> handles an
C<HTTPException>. An ErrorHandler C<handler> answers only unhandled errors
and never sees one.

There are no per-status subclasses: the status is an argument.

=head1 CONSTRUCTOR

=head2 new, throw

    my $error = PAGI::Exception::HTTP->new(409, 'That name is taken.');
    PAGI::Exception::HTTP->throw(403);
    PAGI::Exception::HTTP->throw(401, 'Sign in first.',
        headers => ['WWW-Authenticate' => 'Bearer realm="notes"']);

C<new> croaks unless the status is an integer from 400 to 599. The message is
optional; it is shown to the client, so keep it free of internal detail.
C<throw> takes the same arguments and dies with the new object.

The one option, C<headers>, takes any of the three shapes
L<PAGI::Response/new> takes (a flat list, C<[[name, value], ...]> pairs, or a
L<PAGI::Headers> object), with names that are HTTP tokens and values that are
bytes; a malformed one croaks here. ErrorHandler's built-in answer sends
them, and with them it can answer a status that must carry a field (401
C<WWW-Authenticate>, 405 C<Allow>, 407 C<Proxy-Authenticate>, 426
C<Upgrade>), which otherwise needs a C<handler>.

=head1 ACCESSORS

=head2 status_code

The status, 400-599.

=head2 client_message

The message given to C<new>, or undef.

=head2 headers

The headers given to C<new>, as a new C<[[name, value], ...]> list each
call; an empty list without them.

=head1 STRINGIFICATION

The object stringifies as the status and the message, or the status's reason
phrase without one: C<409 That name is taken.>, C<403 Forbidden>. That is
what a log or an C<on_error> tracker shows.

=head1 WRITING YOUR OWN

ErrorHandler recognises an HTTP error by what it can do, not by its class:
any thrown object with a C<status_code> method returning 400-599 is one, and
a C<client_message> method, when present, supplies the client-safe text,
and a C<headers> method, when present, the headers to send (any shape
C<new> takes); headers that cannot be sent make the answer a 500 with a
diagnostic.
L<PAGI::Exception::RequestBody> is the in-house example.

Exception classes written for Plack, such as L<HTTP::Exception> (which uses
C<code>) or ones relying on L<Plack::Middleware::HTTPExceptions>' C<as_psgi>
and C<location>, probably will not work as intended: they become a 500 unless
they implement C<status_code>, and their PSGI rendering is never used.

=head1 SEE ALSO

L<PAGI::Middleware::ErrorHandler>, L<PAGI::ErrorContext>,
L<PAGI::Exception::RequestBody>

=cut
