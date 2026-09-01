package PAGI::Middleware::ContentLength;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use PAGI::Middleware::BufferedResponse qw(buffer_whole_response);

=head1 NAME

PAGI::Middleware::ContentLength - Auto Content-Length header middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'ContentLength';
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::ContentLength automatically adds a Content-Length header
to responses that don't already have one. It buffers the response body
to calculate the length, then sends the complete response.

This middleware is useful when the application doesn't know the body
length upfront, but you want to avoid chunked encoding.

=head1 CONFIGURATION

=over 4

=item * auto_chunked (default: 0)

If true, skip adding Content-Length and let chunked encoding be used instead.
This is useful for large responses where buffering would be expensive.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{auto_chunked} = $config->{auto_chunked} // 0;
}

sub wrap {
    my ($self, $app) = @_;

    return buffer_whole_response($app,
        engage => sub {
            my ($status, $headers) = @_;
            return 0 if $self->{auto_chunked};
            # An application that set its own length owns it.
            return 0 if grep { lc($_->[0]) eq 'content-length' } @$headers;
            return 1;
        },
        transform => sub {
            my ($status, $headers, $body) = @_;
            push @$headers, ['content-length', length $body];
            return ($status, $headers, $body);
        },
    );
}


1;

__END__

=head1 NOTES

=over 4

=item * For streaming responses (multiple body events with more => 1),
this middleware switches to pass-through mode to avoid buffering.

=item * Responses that already have Content-Length are passed through unchanged.

=item * An app-set C<Transfer-Encoding> header has no effect on this middleware
and does not suppress Content-Length synthesis. Apps can no longer set
Transfer-Encoding meaningfully -- actual chunked framing is a server/transport
concern, and the server strips any app-supplied C<Transfer-Encoding> header
before the response reaches the wire -- so a single-shot body still gets an
accurate Content-Length even if the app also (harmlessly, and now
pointlessly) declared C<Transfer-Encoding: chunked>. To skip Content-Length
synthesis for a large or genuinely streamed response, use C<auto_chunked> or
send the body with C<< more => 1 >>.

=item * SSE and WebSocket responses should not use this middleware.

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
