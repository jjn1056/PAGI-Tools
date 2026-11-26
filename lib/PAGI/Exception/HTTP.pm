package PAGI::Exception::HTTP;

use v5.24;
use warnings;
use Carp ();
use Class::Tiny;   # new, BUILDARGS and BUILD; the fields are this class's own
# Its string is also its truth: never empty, never "0", as it starts with
# the status, so it's always true and can fail a Future.
use overload
    '""'     => \&_as_string,
    fallback => 1;

my %ARGUMENT = map { $_ => 1 } qw(status_code client_message headers cause);

# The arguments, checked, then kept: headers as a copy, so the list you
# gave can change without changing the error.
sub BUILD {
    my ($self, $args) = @_;
    my @unknown = sort grep { !$ARGUMENT{$_} } keys %$args;
    Carp::croak('unknown argument: ' . join(', ', @unknown)
        . '; give status_code, client_message, headers or cause') if @unknown;
    my $status = $args->{status_code};
    Carp::croak('status_code is required: an HTTP error status from 400 to 599') unless defined $status;
    Carp::croak("status_code must be an integer from 400 to 599, not '$status'")
        unless $status =~ /\A[45][0-9][0-9]\z/;
    $self->{status_code}    = 0 + $status;
    $self->{client_message} = $args->{client_message};
    $self->{headers}        = [ map { [@$_] } @{ $args->{headers} // [] } ];
    $self->{cause}          = $args->{cause};
    return;
}

sub throw {
    my $class = shift;
    die $class->new(@_);
}

sub status_code    { $_[0]{status_code} }
sub client_message { $_[0]{client_message} }
sub cause          { $_[0]{cause} }

# A new copy each time, so changing it changes nothing here.
sub headers { [ map { [@$_] } @{ $_[0]{headers} } ] }

# What a log shows: the status, the message or the reason phrase, then the
# cause, without its trailing newline.
sub _as_string {
    my ($self) = @_;
    my $message = $self->{client_message};
    $message = _reason_phrase($self->{status_code}) unless defined $message && length $message;
    my $string = "$self->{status_code} $message";
    if (defined $self->{cause}) {
        (my $cause = "$self->{cause}") =~ s/\n\z//;
        $string .= " (cause: $cause)";
    }
    return $string;
}

# RFC 9110's 4xx and 5xx reason phrases, and the common extras. ErrorHandler
# uses this for an answer without a message.
my %REASON = (
    400 => 'Bad Request',                     401 => 'Unauthorized',
    402 => 'Payment Required',                403 => 'Forbidden',
    404 => 'Not Found',                       405 => 'Method Not Allowed',
    406 => 'Not Acceptable',                  407 => 'Proxy Authentication Required',
    408 => 'Request Timeout',                 409 => 'Conflict',
    410 => 'Gone',                            411 => 'Length Required',
    412 => 'Precondition Failed',             413 => 'Content Too Large',
    414 => 'URI Too Long',                    415 => 'Unsupported Media Type',
    416 => 'Range Not Satisfiable',           417 => 'Expectation Failed',
    418 => "I'm a teapot",                    421 => 'Misdirected Request',
    422 => 'Unprocessable Content',           423 => 'Locked',
    424 => 'Failed Dependency',               425 => 'Too Early',
    426 => 'Upgrade Required',                428 => 'Precondition Required',
    429 => 'Too Many Requests',               431 => 'Request Header Fields Too Large',
    451 => 'Unavailable For Legal Reasons',
    500 => 'Internal Server Error',           501 => 'Not Implemented',
    502 => 'Bad Gateway',                     503 => 'Service Unavailable',
    504 => 'Gateway Timeout',                 505 => 'HTTP Version Not Supported',
    506 => 'Variant Also Negotiates',         507 => 'Insufficient Storage',
    508 => 'Loop Detected',                   510 => 'Not Extended',
    511 => 'Network Authentication Required',
);

sub _reason_phrase { $REASON{ $_[0] } // 'Error' }

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::Exception::HTTP - An HTTP error to throw from deep in an application

=head1 SYNOPSIS

    use v5.40;
    use PAGI::Exception::HTTP;

    sub find_note ($id) {
        return $NOTES{$id} // PAGI::Exception::HTTP->throw(status_code => 404, client_message => "No note $id.");
    }

    PAGI::Exception::HTTP->throw(status_code => 401, client_message => 'Sign in first.',
        headers => [['www-authenticate', 'Bearer']]);

    PAGI::Exception::HTTP->throw(status_code => 503, client_message => 'Notes are resting; try again soon.',
        cause => $@);

=head1 INHERITANCE

    PAGI::Exception::HTTP
      Class::Tiny::Object

=head1 DESCRIPTION

An HTTP error status, with what the client is told and what the log is
told, thrown to end a request from code far from the one answering it: a
model that finds nothing, say. Where you can, return a response instead; a
throw is for when the code that knows what went wrong can't.

It carries a status and nothing about how the error looks.
L<PAGI::Middleware::ErrorHandler> answers it, by default as plain text.

C<client_message> is sent to the client, so it says what they need and
nothing about your internals. Those go in C<cause>, which the client never
sees: from 500 up, ErrorHandler answers and then hands the error on to the
server, whose log shows the error's string, the cause included.

There is one class, with the status as an argument, not a class for each
status.

=head1 CONSTRUCTOR ARGUMENTS

    my $error = PAGI::Exception::HTTP->new(status_code => 409, client_message => 'That name is taken.');
    PAGI::Exception::HTTP->throw(status_code => 404);

C<new> builds the error; C<throw> takes the same arguments and dies with it.
An argument not listed here dies.

=over 4

=item status_code

Required: an integer from 400 to 599.

=item client_message

Optional: a sentence the client is shown. Without one, the answer is the
status's reason phrase (C<Not Found>).

=item headers

Optional: headers the answer carries, as C<[[name, value], ...]>, the way
L<PAGI::Response> takes them. Some statuses need one: a 401 a
C<WWW-Authenticate>, a 405 an C<Allow>, a 429 or 503 often a C<Retry-After>.

=item cause

Optional: the error underneath, a decoder's message or a database
exception say, for the log. It's never sent to the client.

=back

=head1 ACCESSORS

=head2 status_code

The status, 400-599.

=head2 client_message

The message given, or undef.

=head2 headers

The headers given, as a new C<[[name, value], ...]> list each call, so
changing it changes nothing; an empty list without them.

=head2 cause

The cause given, or undef.

=head1 STRINGIFICATION

The error is its string in a log or a C<die> message: the status, the
message or else the reason phrase, then the cause, without its trailing
newline:

    404 Not Found
    409 That name is taken.
    503 Service Unavailable (cause: database: connection refused)

It's always true in boolean context, so it can fail a L<Future>.

=head1 SEE ALSO

L<PAGI::Middleware::ErrorHandler>

=cut
