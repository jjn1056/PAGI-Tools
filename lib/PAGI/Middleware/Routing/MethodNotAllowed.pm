package PAGI::Middleware::Routing::MethodNotAllowed;

use strict;
use warnings;
use parent 'PAGI::Middleware::Routing::_Fallback';
use Future;
use PAGI::Utils ();

=encoding UTF-8

=head1 NAME

PAGI::Middleware::Routing::MethodNotAllowed - Conditional routing-aware 405 middleware

=head1 SYNOPSIS

    use PAGI::Compose qw(compose);
    use PAGI::Routing qw(router mount middleware);

    # Application-wide official policy
    my $app = compose(
        routes => \@routes,
        middleware => [
            middleware('Routing::MethodNotAllowed',
                handler => \&site_method_not_allowed),
        ],
    )->to_app;

    # Policy owned by one reusable Router
    my $api = router(
        routes => \@api_routes,
        middleware => [
            middleware('Routing::MethodNotAllowed',
                handler => \&api_method_not_allowed),
        ],
    );

    # Policy for one routing-aware mounted occurrence
    my $mounted = mount(
        '/api/v1',
        router     => $api,
        name       => 'v1',
        middleware => [
            middleware('Routing::MethodNotAllowed',
                handler => \&legacy_method_not_allowed),
        ],
    );

=head1 DESCRIPTION

This ordinary L<PAGI::Middleware> renders only after its enclosed HTTP routing
boundary completes normally without starting a response and publishes trusted
evidence that a path matched but the request method did not. The snapshot must
also contain a nonempty allowed-method union. Explicit responses, thrown
exceptions, started streams, silent native applications without evidence, and
non-HTTP scopes pass through unchanged.

The built-in response is a production-safe failsafe: status 405, UTF-8 plain
text C<Method Not Allowed>, C<Cache-Control: no-store>, and one authoritative
C<Allow> field. Development adds only safe request and bounded first-party
routing-attempt facts. Install a configured instance inside ordinary
application middleware for official application policy; the outer automatic
Compose default remains an emergency response.

=head1 CONSTRUCTION

    my $fallback = PAGI::Middleware::Routing::MethodNotAllowed->new(
        handler => sub {
            my ($context, $snapshot) = @_;
            return $context->json({
                error   => 'method not allowed',
                allowed => $snapshot->allowed_methods,
            });
        },
    );

The only option is C<handler>, which must be a coderef. It receives a
L<PAGI::Context::HTTP> built with the boundary's original receive and outer send
channels plus the read-only L<PAGI::Routing::Trace::Snapshot>. Its immediate or
Future-backed return must satisfy L<PAGI::Utils/is_response>. The Context's
cached response is seeded to 405, but no mutable C<Allow> value is seeded. An
explicit handler status wins.

The snapshot reports facts rather than a status decision. This middleware acts
only for a trusted decline with a complete path match, no method match, and a
nonempty method union. Context intentionally has no routing-fallback
convenience method; handlers receive the first-party snapshot explicitly.

=head1 AUTHORITATIVE ALLOW

When the emitted C<http.response.start> status is 405, every case-insensitive
renderer-provided C<Allow> pair is removed and exactly one field is appended
from C<< $snapshot->allowed_methods >> in deterministic first-seen order. This
happens at the local send-event boundary and works for every response-like
object accepted by C<is_response>; the returned object is never mutated.

For any other emitted status, the middleware neither adds the computed field
nor removes a renderer-provided one. A policy that intentionally conceals
supported methods can therefore return 404 instead of an inaccurate 405.

=head1 BOUNDARIES AND OWNERSHIP

Router middleware observes that Router's own method-partial exhaustion.
Middleware on a routing-aware Mount observes only the already-selected child
Router and owns that mounted occurrence's policy; the parent does not resume
scanning. Application middleware under Compose provides application-wide
policy.

Route middleware is legal syntax but has no fallback effect. A Route wrapper is
entered only after that Route fully matches, so it cannot observe the Router or
Mount search that exhausted. Put local fallback policy on the Router or Mount.

=head1 SEE ALSO

L<PAGI::Middleware::Routing::NotFound>, L<PAGI::Routing::Trace>,
L<PAGI::Compose>, L<PAGI::Routing>

=cut

sub _matches {
    my ($self, $snapshot) = @_;
    return 0 unless $snapshot->routing_declined;
    return 0 unless $snapshot->path_matched;
    return 0 if $snapshot->method_matched;
    return @{$snapshot->allowed_methods} ? 1 : 0;
}

sub _seed_context {
    my ($self, $context) = @_;
    $context->response->status(405);
    return;
}

sub _default_response {
    my ($self, $context, $snapshot) = @_;
    return $self->_plain_text_response($context, 'Method Not Allowed')
        unless PAGI::Utils::is_development();

    my @lines = (
        'PAGI automatic routing fallback: Method Not Allowed',
        'No application fallback handled this route.',
        'Method: ' . $self->_safe_fact($context->method),
        'Path: ' . $self->_safe_fact($context->path),
        'Allowed methods: ' . join(', ', @{$snapshot->allowed_methods}),
        $self->_attempt_diagnostics($snapshot),
        'Install application Routing::MethodNotAllowed middleware for official policy.',
    );
    return $self->_plain_text_response($context, join("\n", @lines));
}

sub _prepare_response {
    my ($self, $response, $snapshot) = @_;
    return PAGI::Middleware::Routing::MethodNotAllowed::_ResponseProxy->new(
        response => $response,
        allow    => join(', ', @{$snapshot->allowed_methods}),
    );
}

package PAGI::Middleware::Routing::MethodNotAllowed::_ResponseProxy;

use strict;
use warnings;
use Future;

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

sub respond {
    my ($self, $send) = @_;
    my $allow = $self->{allow};
    my $normalizing_send = sub {
        my ($event) = @_;
        return $send->($event)
            unless ($event->{type} // '') eq 'http.response.start'
                && defined($event->{status})
                && !ref($event->{status})
                && "$event->{status}" eq '405';

        my @headers = @{$event->{headers} || []};
        my @filtered = grep {
            my $name = ref($_) eq 'ARRAY' ? $_->[0] : undef;
            !(defined($name) && !ref($name) && lc($name) eq 'allow');
        } @headers;
        push @filtered, ['Allow' => $allow];
        return $send->({
            %$event,
            headers => \@filtered,
        });
    };

    my $returned = $self->{response}->respond($normalizing_send);
    return Future->wrap($returned);
}

1;
