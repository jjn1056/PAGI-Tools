package PAGI::Middleware::Head;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use PAGI::Routing::HeadBoundary;

=head1 NAME

PAGI::Middleware::Head - HEAD request handling middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'Head';
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::Head handles HEAD requests by suppressing the response
body while preserving all headers. The inner application runs normally
(as if it were a GET request), allowing Content-Length and other headers
to be calculated, but the body is not sent to the client.

This middleware changes the method from HEAD to GET before passing to the
inner app, then suppresses the body in the response.

=head1 CONFIGURATION

No configuration options.

=cut

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;

        # Wire-level suppression is delegated to the shared boundary (the
        # same one Compose and automatic routing HEAD handling use). For
        # non-HTTP or non-HEAD scopes, and for a scope already owned by an
        # outer boundary, prepare() returns the original arguments unchanged.
        my ($inner_scope, $wire_send)
            = PAGI::Routing::HeadBoundary->prepare($scope, $send);

        # Unlike the shared boundary (which preserves HEAD so custom HEAD
        # routes can see it), this middleware changes the method to GET so
        # the inner app can compute the full representation normally.
        if (($inner_scope->{type} // '') eq 'http'
            && ($inner_scope->{method} // '') eq 'HEAD') {
            $inner_scope = $self->modify_scope($inner_scope, { method => 'GET' });
        }

        await $app->($inner_scope, $receive, $wire_send);
    };
}

1;

__END__

=head1 NOTES

=over 4

=item * HEAD requests are converted to GET for the inner app, so the
app can calculate Content-Length normally.

=item * The body is suppressed in the response, but headers are preserved.

=item * This middleware should be placed BEFORE ContentLength middleware
in the stack, so Content-Length is calculated from the GET response.

=item * Trailers are also suppressed for HEAD requests.

=item * Wire suppression is delegated to L<PAGI::Routing::HeadBoundary>, the
same boundary L<PAGI::Compose> and automatic routing HEAD handling use.
Enabling this middleware under a Compose-managed stack is harmless but
redundant: the shared boundary's scope marker means only the first owner
wires suppression, so nothing is suppressed twice. This middleware still
unconditionally rewrites the request method from HEAD to GET before running
the inner app, though, so placing it in front of a router with an explicit
HEAD route can still bypass that route; prefer Compose's or Routing's
automatic HEAD handling there instead.

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::ContentLength> - Auto Content-Length header

=cut
