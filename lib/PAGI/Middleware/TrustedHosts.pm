package PAGI::Middleware::TrustedHosts;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future;
use Future::AsyncAwait;
use PAGI::Authority;
use PAGI::Response::Text ();
use PAGI::Utils ();

=head1 NAME

PAGI::Middleware::TrustedHosts - Host header validation middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'TrustedHosts',
            hosts => ['example.com', 'www.example.com', '*.example.com'];
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::TrustedHosts structurally validates the Host header before
matching its raw, validated value against a list of allowed hosts. A missing
Host is refused with a plain-text 400, C<Missing Host header>; a duplicate or
malformed Host, or one no pattern allows, with C<Invalid Host header>. Neither
echoes the rejected value. C<refuse> replaces the refusal. Structural
validation and allowlist decisions remain authoritative in this middleware.
This helps prevent host header injection attacks.

Non-HTTP scopes continue to pass through unchanged without Host validation.

=head1 CONFIGURATION

=over 4

=item * hosts (required)

Array of allowed host patterns. Patterns can include:
- Exact hostnames: 'example.com'
- Wildcard subdomains: '*.example.com'
- Port specifications: 'example.com:8080'

=item * allow_empty (default: 0)

If true, allow requests without a Host header.

=item * refuse (default: a 400 text response)

An application that answers a refused request instead of the plain-text
default: a Request handler (a coderef called with one
L<PAGI::Request>, returning a Response or an application) or an object
with C<to_app>, which includes every L<PAGI::Response>:

    middleware('TrustedHosts', hosts => ['example.com'],
        refuse => response('JSON', { detail => 'Unknown host' }, status => 400));

For a malformed Host it receives a scope holding only the request's
well-formed C<Accept> headers, so it can read the request without tripping
over the header that caused the refusal. A bad Host is never passed on to the
wrapped application, so there is no C<0> form. Any plain value dies.

A native C<($scope, $receive, $send)> application is passed as
C<as_app_object($app)>. Objects -- every Response and L<PAGI::Pages> value --
mean the same in every slot, and are the portable form for anything also
given to middleware outside PAGI-Tools.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{hosts}       = $config->{hosts} // die "TrustedHosts requires 'hosts' option";
    $self->{allow_empty} = $config->{allow_empty} // 0;

    # Compile host patterns to regexes
    $self->{_patterns} = [map { $self->_compile_pattern($_) } @{$self->{hosts}}];

    # The caller's refusing application, or plain-text defaults built once.
    $self->{refuse} = PAGI::Utils::_refuse_option('TrustedHosts', $config);
    $self->{_default_refusal} = {
        missing => PAGI::Response::Text->new('Missing Host header', status => 400)->to_app,
        invalid => PAGI::Response::Text->new('Invalid Host header', status => 400)->to_app,
    };
}

sub _compile_pattern {
    my ($self, $pattern) = @_;

    # Escape regex special chars except *
    my $escaped = quotemeta($pattern);
    # Convert escaped * back to regex wildcard
    $escaped =~ s/\\\*/.*/g;
    return qr/^$escaped$/i;
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

        my ($host, $authority_error);
        {
            local $@;
            $host = eval { PAGI::Authority->host_from_scope($scope) };
            $authority_error = $@;
        }
        if ($authority_error) {
            my $refusal_scope = $self->_refusal_scope_for_authority_error($scope);
            await $self->_refuse($refusal_scope, $receive, $send, 'invalid');
            return;
        }

        # Check if host is allowed
        if (!defined $host || $host eq '') {
            if ($self->{allow_empty}) {
                await $app->($scope, $receive, $send);
                return;
            }
            await $self->_refuse($scope, $receive, $send, 'missing');
            return;
        }

        # Match the raw value after structural validation
        my $host_for_match = $host;

        # Check against patterns
        my $allowed = 0;
        for my $pattern (@{$self->{_patterns}}) {
            if ($host_for_match =~ $pattern) {
                $allowed = 1;
                last;
            }
        }

        if ($allowed) {
            await $app->($scope, $receive, $send);
        } else {
            await $self->_refuse($scope, $receive, $send, 'invalid');
        }
    };
}

async sub _refuse {
    my ($self, $scope, $receive, $send, $reason) = @_;
    my $refusal = $self->{refuse} // $self->{_default_refusal}{$reason};
    await $refusal->($scope, $receive, $send);
}

1;

__END__

=head1 HOST HEADER ATTACKS

Host header injection attacks can lead to:

=over 4

=item * Cache poisoning

=item * Password reset poisoning

=item * Server-Side Request Forgery (SSRF)

=item * SQL injection in some cases

=back

This middleware prevents these attacks by validating the Host header
against a whitelist of allowed hosts.

If the raw header container itself is malformed, a C<refuse> application
receives a request-local shallow scope containing only structurally valid
Accept pairs. Any inherited request-header cache is discarded from that copy.
The original scope and malformed header data are not mutated. Structurally
valid missing, duplicate, malformed-authority, and allowlist-rejected Host
branches pass their original scope.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
