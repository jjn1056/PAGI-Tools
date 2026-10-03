package PAGI::ErrorContext;

use strict;
use warnings;
use Carp qw(croak);
use Exporter 'import';
use Scalar::Util qw(blessed);
use PAGI::Response::Text ();
use PAGI::Utils::Scope ();

our @EXPORT = ();
our @EXPORT_OK = qw(error_context);
our %EXPORT_TAGS = (ALL => [@EXPORT_OK]);

# Reason phrases for 400-599 from the IANA HTTP Status Code Registry
# (RFC 9110 and the RFCs it lists).
my %REASON = (
    400 => 'Bad Request',                  401 => 'Unauthorized',
    402 => 'Payment Required',             403 => 'Forbidden',
    404 => 'Not Found',                    405 => 'Method Not Allowed',
    406 => 'Not Acceptable',               407 => 'Proxy Authentication Required',
    408 => 'Request Timeout',              409 => 'Conflict',
    410 => 'Gone',                         411 => 'Length Required',
    412 => 'Precondition Failed',          413 => 'Content Too Large',
    414 => 'URI Too Long',                 415 => 'Unsupported Media Type',
    416 => 'Range Not Satisfiable',        417 => 'Expectation Failed',
    421 => 'Misdirected Request',          422 => 'Unprocessable Content',
    423 => 'Locked',                       424 => 'Failed Dependency',
    425 => 'Too Early',                    426 => 'Upgrade Required',
    428 => 'Precondition Required',        429 => 'Too Many Requests',
    431 => 'Request Header Fields Too Large',
    451 => 'Unavailable For Legal Reasons',
    500 => 'Internal Server Error',        501 => 'Not Implemented',
    502 => 'Bad Gateway',                  503 => 'Service Unavailable',
    504 => 'Gateway Timeout',              505 => 'HTTP Version Not Supported',
    506 => 'Variant Also Negotiates',      507 => 'Insufficient Storage',
    508 => 'Loop Detected',                511 => 'Network Authentication Required',
);

sub error_context { return __PACKAGE__->new(@_) }

sub new {
    my ($class, @args) = @_;
    my $scope = PAGI::Utils::Scope::scope_from_source($class, @args);
    my $error = $scope->{'pagi.error'};
    croak "$class needs the scope of an ErrorHandler handler, which carries pagi.error"
        unless ref($error) eq 'HASH';
    return bless { error => $error }, $class;
}

sub exception       { $_[0]{error}{exception} }
sub status          { $_[0]{error}{status} }
sub is_client_error { my $s = $_[0]->status; $s >= 400 && $s < 500 ? 1 : 0 }
sub is_server_error { $_[0]->status >= 500 ? 1 : 0 }

sub reason {
    my ($self) = @_;
    my $status = $self->status;
    return $REASON{$status} // ($status < 500 ? 'Client Error' : 'Server Error');
}

# Only a method that promises client-safe text is shown, and only for the
# client's errors: Perl exceptions commonly carry an internal `message`.
sub message {
    my ($self) = @_;
    return $self->reason unless $self->is_client_error;
    my $exception = $self->exception;
    my $text;
    eval {
        $text = $exception->client_message
            if blessed($exception) && $exception->can('client_message');
        1;
    };
    return defined($text) && !ref($text) && length($text) ? $text : $self->reason;
}

sub detail {
    my ($self) = @_;
    return undef unless $self->{error}{development};
    my $text;
    return eval { $text = '' . $self->exception; 1 } ? $text : undef;
}

sub default {
    my ($self) = @_;
    my $body = $self->message;
    my $detail = $self->detail;
    $body .= "\n\n$detail" if defined($detail) && length($detail);
    return PAGI::Response::Text->new($body,
        status  => $self->status,
        headers => ['Cache-Control' => 'no-store'],
    );
}

1;

__END__

=head1 NAME

PAGI::ErrorContext - The error an ErrorHandler handler is answering

=head1 SYNOPSIS

    use PAGI::ErrorContext qw(error_context);

    middleware('ErrorHandler', handler => sub {
        my ($request) = @_;
        my $error = error_context($request);
        return $error->default if $error->is_server_error;
        return response('JSON', { error => $error->message });
    });

=head1 DESCRIPTION

L<PAGI::Middleware::ErrorHandler> puts the error it is handling in the scope
it gives its C<handler>, as C<pagi.error>. This class reads it. It is not an
exception class: nothing throws it.

=head1 FUNCTIONS

=head2 error_context

    my $error = error_context($request);   # or ($scope), or any object with ->scope

The same as C<< PAGI::ErrorContext->new(...) >>. Exported on request.

=head1 CONSTRUCTOR

=head2 new

    my $error = PAGI::ErrorContext->new($scope);
    my $error = PAGI::ErrorContext->new($request);   # any object with ->scope

Dies when the scope carries no C<pagi.error>: an error context exists only
inside an ErrorHandler handler.

=head1 METHODS

=head2 exception

What was thrown, unchanged.

=head2 status

The status ErrorHandler chose, 400-599: the exception's C<status_code> when it
claims one in that range, otherwise ErrorHandler's C<status> option.

=head2 reason

The status's reason phrase (C<Bad Request>); C<Client Error> or C<Server Error>
for an unregistered status.

=head2 message

Text safe to send to the client. For a 4xx, the exception's C<client_message>
when it has one that returns a non-empty string; otherwise, and for every 5xx,
C<reason>. An exception's C<message> is never shown: Perl exceptions commonly
carry an internal one.

=head2 detail

In development mode, the stringified exception; otherwise undef.

=head2 is_client_error, is_server_error

True for 400-499 and 500-599.

=head2 default

ErrorHandler's built-in answer, as a L<PAGI::Response::Text>: C<message>,
followed in development by a blank line and C<detail>, with the status and
C<Cache-Control: no-store>. A handler returns it to leave an error to the
built-in answer.

=head1 SEE ALSO

L<PAGI::Middleware::ErrorHandler>

=cut
