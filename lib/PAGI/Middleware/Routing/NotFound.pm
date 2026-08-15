package PAGI::Middleware::Routing::NotFound;

use strict;
use warnings;
use parent 'PAGI::Middleware::Routing::_Fallback';
use PAGI::Pages ();
use PAGI::Utils ();

=encoding UTF-8

=head1 NAME

PAGI::Middleware::Routing::NotFound - Conditional routing-aware 404 middleware

=head1 SYNOPSIS

    use PAGI::Compose qw(compose);
    use PAGI::Routing qw(router mount middleware);

    # Application-wide official policy
    my $app = compose(
        routes => \@routes,
        middleware => [
            middleware('Routing::NotFound',
                handler => \&site_not_found),
        ],
    )->to_app;

    # Policy owned by one reusable Router
    my $api = router(
        routes => \@api_routes,
        middleware => [
            middleware('Routing::NotFound',
                handler => \&api_not_found),
        ],
    );

    # Policy for one routing-aware mounted occurrence
    my $mounted = mount(
        '/api/v1',
        router     => $api,
        name       => 'v1',
        middleware => [
            middleware('Routing::NotFound',
                handler => \&legacy_not_found),
        ],
    );

=head1 DESCRIPTION

This ordinary L<PAGI::Middleware> renders only after its enclosed HTTP routing
boundary completes normally without starting a response and publishes trusted
routing evidence that no path candidate matched. Explicit responses, thrown
exceptions, started streams, silent native applications without evidence, and
non-HTTP scopes pass through unchanged.

The built-in response is a production-safe, C<no-store> L<PAGI::Pages> 404
that negotiates HTML, problem JSON, or text. In development it adds only the
request method, path, and bounded first-party routing-attempt facts. Install a
configured instance inside ordinary application middleware for the site's
official branded or structured policy; the outer automatic Compose default is
an emergency response and does not travel inward through author middleware.

=head1 CONSTRUCTION

    my $fallback = PAGI::Middleware::Routing::NotFound->new(
        handler => sub {
            my ($context, $snapshot) = @_;
            return $context->html('Missing', status => 404);
        },
    );

The only option is C<handler>, which must be a coderef. It receives a
L<PAGI::Context::HTTP> built with the boundary's original receive and outer send
channels plus the read-only L<PAGI::Routing::Trace::Snapshot>. Its immediate or
Future-backed return must satisfy L<PAGI::Utils/is_response>. The Context's
cached response is seeded to 404; an explicit handler status wins.

The snapshot reports matching facts, not status: the middleware acts when
C<routing_declined> is true and C<path_matched> is false. Context has no
routing-fallback convenience methods because not every Context application
uses the first-party routing Trace.

=head1 BOUNDARIES AND OWNERSHIP

Router middleware observes that Router's own exhaustion. Middleware on a
routing-aware Mount observes only the already-selected child Router and owns
that mounted occurrence's fallback; the parent does not resume scanning.
Application middleware under Compose provides application-wide policy.

Route middleware is legal syntax but has no fallback effect. A Route wrapper is
entered only after that Route fully matches, so it cannot observe the Router or
Mount search that exhausted. Put local fallback policy on the Router or Mount.

=head1 TERMINAL PAGES ENDPOINTS

This middleware is conditional: it interprets a trusted routing decline at an
enclosing boundary. For an unconditional terminal 404 endpoint, use Pages
directly and let Compose supply the final HTTP and protocol boundaries:

    use PAGI::Pages ();

    my $app = compose(
        app => PAGI::Pages->not_found,
    )->to_app;

The immediate form can also construct a response inside a selected handler:

    return PAGI::Pages->not_found($context);

=head1 SEE ALSO

L<PAGI::Middleware::Routing::MethodNotAllowed>, L<PAGI::Routing::Trace>,
L<PAGI::Pages>, L<PAGI::Compose>, L<PAGI::Routing>

=cut

sub _matches {
    my ($self, $snapshot) = @_;
    return $snapshot->routing_declined && !$snapshot->path_matched ? 1 : 0;
}

sub _seed_context {
    my ($self, $context) = @_;
    $context->response->status(404);
    return;
}

sub _default_response {
    my ($self, $context, $snapshot) = @_;
    my $detail = 'The requested resource was not found.';
    if (PAGI::Utils::is_development()) {
        my @lines = (
            'PAGI automatic routing fallback: Not Found',
            'No application fallback handled this route.',
            'Method: ' . $self->_safe_fact($context->method),
            'Path: ' . $self->_safe_fact($context->path),
            $self->_attempt_diagnostics($snapshot),
            'Install application Routing::NotFound middleware for official policy.',
        );
        $detail = join("\n", @lines);
    }
    return PAGI::Pages->not_found($context, detail => $detail);
}

1;
