package PAGI::Middleware::TrustedHosts;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future;
use Future::AsyncAwait;
use PAGI::Authority;
use PAGI::Pages;

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
matching its raw, validated value against a list of allowed hosts. Duplicate or
malformed Host headers, missing required hosts, and allowlist rejections receive
a generic HTTP 400 response negotiated through L<PAGI::Pages>. Structural
validation and allowlist decisions remain authoritative in this middleware.
This helps prevent host header injection attacks.

Non-HTTP scopes continue to pass through unchanged without Host validation or
Pages rendering.

=head1 CONFIGURATION

=over 4

=item * hosts (required)

Array of allowed host patterns. Patterns can include:
- Exact hostnames: 'example.com'
- Wildcard subdomains: '*.example.com'
- Port specifications: 'example.com:8080'

=item * allow_empty (default: 0)

If true, allow requests without a Host header.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{hosts}       = $config->{hosts} // die "TrustedHosts requires 'hosts' option";
    $self->{allow_empty} = $config->{allow_empty} // 0;

    # Compile host patterns to regexes
    $self->{_patterns} = [map { $self->_compile_pattern($_) } @{$self->{hosts}}];
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
            await $self->_send_error($scope, $send, 400);
            return;
        }

        # Check if host is allowed
        if (!defined $host || $host eq '') {
            if ($self->{allow_empty}) {
                await $app->($scope, $receive, $send);
                return;
            }
            await $self->_send_error($scope, $send, 400);
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
            await $self->_send_error($scope, $send, 400);
        }
    };
}

async sub _send_error {
    my ($self, $scope, $send, $status) = @_;
    die "PAGI::Middleware::TrustedHosts does not own status $status"
        unless $status == 400;
    my $response = PAGI::Pages->bad_request($scope);
    await Future->wrap($response->respond($send));
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

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
