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
            my $pages_scope = $self->_pages_scope_for_authority_error($scope);
            await $self->_send_error($pages_scope, $receive, $send, 400);
            return;
        }

        # Check if host is allowed
        if (!defined $host || $host eq '') {
            if ($self->{allow_empty}) {
                await $app->($scope, $receive, $send);
                return;
            }
            await $self->_send_error($scope, $receive, $send, 400);
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
            await $self->_send_error($scope, $receive, $send, 400);
        }
    };
}

sub _pages_scope_for_authority_error {
    my ($self, $scope) = @_;
    my $pairs = exists $scope->{headers} ? $scope->{headers} : [];
    my $structurally_valid = ref($pairs) eq 'ARRAY';

    if ($structurally_valid) {
        for my $pair (@$pairs) {
            unless (ref($pair) eq 'ARRAY' && @$pair == 2
                    && defined($pair->[0]) && !ref($pair->[0])
                    && defined($pair->[1]) && !ref($pair->[1])) {
                $structurally_valid = 0;
                last;
            }
        }
    }
    return $scope if $structurally_valid;

    my @accept;
    if (ref($pairs) eq 'ARRAY') {
        for my $pair (@$pairs) {
            next unless ref($pair) eq 'ARRAY' && @$pair == 2
                && defined($pair->[0]) && !ref($pair->[0])
                && defined($pair->[1]) && !ref($pair->[1]);
            my $name = $pair->[0];
            $name =~ tr/A-Z/a-z/;
            push @accept, [$pair->[0], $pair->[1]] if $name eq 'accept';
        }
    }

    my $safe_scope = {
        %$scope,
        headers => \@accept,
    };
    delete $safe_scope->{'pagi.request.headers'};
    return $safe_scope;
}

async sub _send_error {
    my ($self, $scope, $receive, $send, $status) = @_;
    die "PAGI::Middleware::TrustedHosts does not own status $status"
        unless $status == 400;
    my $response = PAGI::Pages->bad_request($scope);
    await Future->wrap($response->respond($scope, $receive, $send));
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

If the raw header container itself is malformed, the built-in Pages response
uses a request-local shallow scope containing only structurally valid Accept
pairs. Any inherited request-header cache is discarded from that copy. The
original scope and malformed header data are not mutated. Structurally valid
missing, duplicate, malformed-authority, and allowlist-rejected Host branches
continue to pass their original scope to Pages.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
