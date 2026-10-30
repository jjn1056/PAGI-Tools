package PAGI::Middleware::RequestId;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use PAGI::Utils::Random qw(secure_random_bytes);
use PAGI::HTTPConnection ();
use PAGI::Utils ();

=head1 NAME

PAGI::Middleware::RequestId - Unique request ID middleware

=head1 SYNOPSIS

    use PAGI::Tools qw(compose middleware response route);

    my $app = compose(
        routes     => [route('/' => sub { response('Text', 'hello') })],
        middleware => [
            middleware('RequestId', header => 'X-Request-ID', trust_incoming => 0),
        ],
    );

C<middleware('RequestId', ...)> also goes in a Router's, Mount's or Route's
C<middleware> list. It constructs the middleware and wraps the application
inside it, which you can do yourself:

    use PAGI::Middleware::RequestId;

    my $wrapped = PAGI::Middleware::RequestId->new(
        header => 'X-Request-ID', trust_incoming => 0,
    )->wrap($native_app);

Without Compose, L<PAGI::Middleware::Builder> composes middleware the way
Plack::Builder does.

=head1 DESCRIPTION

PAGI::Middleware::RequestId generates unique request IDs and adds them
to both the scope and response headers. This is useful for request
tracing and log correlation.

=head1 CONFIGURATION

An option not listed here dies at construction.

=over 4

=item * header (default: 'X-Request-ID')

The header name to use for the request ID.

=item * trust_incoming (default: 0)

If true, use an existing request ID from the incoming request headers
instead of generating a new one. An ID header sent more than once counts as
absent, so a new ID is generated.

=item * generator (default: built-in UUID generator)

A coderef that generates unique IDs. Receives the scope as argument.

=back

=cut

# Simple counter for uniqueness within process
my $counter = 0;

sub _init {
    my ($self, $config) = @_;

    $self->{header}         = $config->{header} // 'X-Request-ID';
    $self->{trust_incoming} = $config->{trust_incoming} // 0;
    $self->{generator}      = $config->{generator} // \&_generate_id;
    PAGI::Utils::_reject_unknown_options('RequestId', $config,
        qw(generator header trust_incoming));
}

sub _generate_id {
    my ($scope) = @_;

    # Generate a UUID-like ID: timestamp + PID + counter + secure random
    my $time = time();
    $counter = ($counter + 1) % 0xFFFF;
    my $rand_bytes = secure_random_bytes(6);
    return sprintf('%08x-%04x-%04x-%s',
        $time,
        $$ & 0xFFFF,
        $counter,
        unpack('H12', $rand_bytes),
    );
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        # Only handle HTTP requests
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # The incoming request ID, if trust_incoming is enabled; a repeated
        # one is absent, so a new one is generated.
        my $request_id;
        if ($self->{trust_incoming}) {
            $request_id = PAGI::HTTPConnection->new($scope)->headers->get_single($self->{header});
        }

        # Generate new ID if none found
        $request_id //= $self->{generator}->($scope);

        # Add request ID to scope
        my $modified_scope = $self->modify_scope($scope, {
            'pagi.request_id' => $request_id,
        });

        # Add the request ID to the response, on a copy of the event: an
        # application may reuse its headers arrayref, and an ID pushed onto
        # it would accumulate across requests.
        my $wrapped_send = async sub {
            my ($event) = @_;
            if ($event->{type} eq 'http.response.start') {
                $event = {
                    %$event,
                    headers => [@{$event->{headers} // []}, [$self->{header}, $request_id]],
                };
            }
            await $send->($event);
        };

        await $app->($modified_scope, $receive, $wrapped_send);
    };
}

1;

__END__

=head1 GENERATED IDS

The default ID generator creates IDs in the format:

    TTTTTTTT-PPPP-CCCC-RRRRRRRRRRRR

Where:
- TTTTTTTT: Unix timestamp (hex)
- PPPP: Process ID (hex, lower 16 bits)
- CCCC: Counter (hex)
- RRRRRRRRRRRR: Cryptographically secure random bytes (hex)

This ensures uniqueness across processes and restarts. The random
component uses C<PAGI::Utils::Random::secure_random_bytes> for
unpredictability.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
