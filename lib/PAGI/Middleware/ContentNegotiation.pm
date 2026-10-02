package PAGI::Middleware::ContentNegotiation;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future;
use Future::AsyncAwait;
use PAGI::Response::Text ();
use PAGI::Request::Negotiate;
use PAGI::Utils ();

=head1 NAME

PAGI::Middleware::ContentNegotiation - HTTP content negotiation middleware

=head1 SYNOPSIS

    use PAGI::Response qw(response);
    use PAGI::Routing qw(middleware mount);

    # An API that only speaks JSON: anything else is refused with a 406
    # before a handler runs.
    mount('/api', routes => [...], middleware => [
        middleware('ContentNegotiation', supported_types => ['application/json']),
    ]);

    # Two representations; handlers read the choice from the scope.
    middleware('ContentNegotiation', supported_types => ['application/json', 'text/html'])

    async sub show ($request) {
        my $type = $request->scope->{'pagi.preferred_content_type'};
        return $type eq 'text/html' ? response('HTML', render($item))
                                    : response('JSON', $item);
    }

    # Refuse your own way
    middleware('ContentNegotiation', supported_types => ['application/json'],
        refuse => response('JSON', { detail => 'This API only speaks JSON' }, status => 406))

=head1 DESCRIPTION

PAGI::Middleware::ContentNegotiation picks the best of C<supported_types>
for the request's C<Accept> header, using the shared
L<PAGI::Request::Negotiate> rules, and puts it in the scope for the wrapped
application. A request without C<Accept> accepts anything and gets the first
supported type, so the order of C<supported_types> is the default.

A request that accepts none of them is refused with C<406 text/plain>,
C<Not Acceptable. Supported types: ...> -- the list RFC 9110 suggests a 406
carry -- and the wrapped application does not run. C<refuse> replaces the
refusal, or with C<0> lets the application decide.

To negotiate inside one handler without a middleware, use
L<PAGI::Request/preferred_type>.

=head1 CONFIGURATION

=over 4

=item * supported_types (required)

Array of MIME types this part of the application can produce, most preferred
first.

=item * refuse (default: a 406 text response)

An application that answers an unmatched request instead of the plain-text
default: a C<($scope, $receive, $send)> coderef or an object with C<to_app>,
which includes every L<PAGI::Response>. It receives the scope with
C<pagi.accepted_types>.

Exactly C<0>: the middleware never refuses. An unmatched request reaches the
application with C<pagi.preferred_content_type> undef, and choosing a
fallback is the application's call:

    my $type = $request->scope->{'pagi.preferred_content_type'} // 'application/json';

Any other plain value dies. C<strict> and C<default_type> were removed:
refusing is the default, and C<refuse =E<gt> 0> replaces C<strict =E<gt> 0>;
passing either dies.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    die "ContentNegotiation 'strict' was removed: it refuses an unmatched request by default; refuse => 0 lets the application decide"
        if exists $config->{strict};
    die "ContentNegotiation 'default_type' was removed: a request without Accept gets the first supported type; with refuse => 0 an unmatched request has no preferred type"
        if exists $config->{default_type};

    $self->{supported_types} = $config->{supported_types}
        // die "ContentNegotiation requires 'supported_types' option";

    # Absent: a plain-text 406 listing the supported types, as RFC 9110
    # suggests. Exactly 0: the application decides.
    my $refuse = PAGI::Utils::_refuse_option('ContentNegotiation', $config, 1);
    my $supported = join(', ', @{$self->{supported_types}});
    $self->{refuse} = !defined($refuse) ? PAGI::Response::Text->new(
            "Not Acceptable. Supported types: $supported", status => 406,
        )->to_app
        : ref($refuse) ? $refuse
        : undef;
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Parse Accept header
        my $accept = $self->_get_header($scope, 'accept') // '*/*';
        my $preferred = PAGI::Request::Negotiate->best_match(
            $self->{supported_types}, $accept,
        );

        # The preferred type is undef when nothing matched.
        my @accepted = $self->_parse_accept($accept);
        my $new_scope = $self->modify_scope($scope, {
            'pagi.preferred_content_type' => $preferred,
            'pagi.accepted_types' => \@accepted,
        });

        my $target = !defined($preferred) && $self->{refuse} ? $self->{refuse} : $app;
        await $target->($new_scope, $receive, $send);
    };
}

sub _parse_accept {
    my ($self, $accept) = @_;

    return map {
        +{ type => $_->[0], q => $_->[1] }
    } PAGI::Request::Negotiate->parse_accept($accept);
}

sub _get_header {
    my ($self, $scope, $name) = @_;

    $name = lc($name);
    my @values;
    for my $h (@{$scope->{headers} // []}) {
        push @values, $h->[1] if lc($h->[0]) eq $name;
    }
    return unless @values;
    return join(', ', @values);
}

1;

__END__

=head1 SCOPE EXTENSIONS

This middleware adds the following to $scope:

=over 4

=item * pagi.preferred_content_type

The best matching MIME type from the supported types; undef when nothing
matched (only reachable with C<refuse =E<gt> 0>).

=item * pagi.accepted_types

Array of parsed Accept header entries in the shared preference order.

=back

=head1 ACCEPT HEADER PARSING

The Accept header is parsed by L<PAGI::Request::Negotiate>:

    Accept: text/html, application/json;q=0.9, */*;q=0.1

Each entry retains the existing C<< { type => $type, q => $quality } >> shape
and shared preference order. Higher quality values (q) indicate higher
preference. The default is q=1.0.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Request::Negotiate> - Shared Accept matching

=cut
