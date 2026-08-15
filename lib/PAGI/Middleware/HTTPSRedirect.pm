package PAGI::Middleware::HTTPSRedirect;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use PAGI::Authority;
use PAGI::Pages;

=head1 NAME

PAGI::Middleware::HTTPSRedirect - Force HTTPS redirect middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'HTTPSRedirect';
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::HTTPSRedirect redirects HTTP requests to HTTPS. Redirect
authority comes from the validated Host header when present, otherwise from the
scope server tuple. It never invents a C<localhost> authority; duplicate or
malformed Host data and unusable server fallbacks receive a generic HTTP 400
response. Useful for enforcing secure connections in production.

Redirect and invalid-authority responses are rendered by L<PAGI::Pages> from
the original request scope. Incoming raw query data is preserved without
re-encoding and is inserted before the first fragment in the redirect target.
Authority selection, exclusions, secure-request pass-through, and HSTS remain
owned by this middleware; there is no Pages configuration option.

Non-HTTP scopes continue to pass through unchanged without authority handling.

=head1 CONFIGURATION

=over 4

=item * redirect_code (default: 301)

HTTP status code for redirects. The supported values are exactly 301, 302, 303,
307, and 308. Invalid values croak during construction. Use 302 for a temporary
redirect.

=item * exclude (optional)

Arrayref of paths to exclude from redirect (e.g., health checks).

=item * hsts (default: 0)

If true, add Strict-Transport-Security header.

=item * hsts_max_age (default: 31536000)

HSTS max-age in seconds (1 year default).

=back

=cut

sub _init {
    my ($self, $config) = @_;

    my $redirect_code = exists($config->{redirect_code})
        ? $config->{redirect_code} : 301;
    my %supported_redirect_code = map { $_ => 1 } qw(301 302 303 307 308);
    my ($canonical_redirect_code, $normalized_redirect_code);
    if (defined($redirect_code) && !ref($redirect_code)) {
        $canonical_redirect_code = "$redirect_code";
        $normalized_redirect_code = 0 + $redirect_code
            if $supported_redirect_code{$canonical_redirect_code};
    }
    croak 'HTTPSRedirect redirect_code must be one of 301, 302, 303, 307, or 308'
        unless defined($normalized_redirect_code)
            && $supported_redirect_code{$normalized_redirect_code}
            && "$normalized_redirect_code" eq $canonical_redirect_code;
    $self->{redirect_code} = $normalized_redirect_code;
    $self->{exclude} = $config->{exclude} // [];
    $self->{hsts} = $config->{hsts} // 0;
    $self->{hsts_max_age} = $config->{hsts_max_age} // 31536000;
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        my $scheme = $scope->{scheme} // 'http';

        # Already HTTPS
        if ($scheme eq 'https') {
            # Add HSTS header if enabled
            if ($self->{hsts}) {
                my $wrapped_send = async sub  {
        my ($event) = @_;
                    if ($event->{type} eq 'http.response.start') {
                        my @headers = @{$event->{headers} // []};
                        push @headers, [
                            'Strict-Transport-Security',
                            "max-age=$self->{hsts_max_age}; includeSubDomains"
                        ];
                        await $send->({
                            %$event,
                            headers => \@headers,
                        });
                        return;
                    }
                    await $send->($event);
                };
                await $app->($scope, $receive, $wrapped_send);
            } else {
                await $app->($scope, $receive, $send);
            }
            return;
        }

        # Check exclusions
        if ($self->_is_excluded($scope->{path})) {
            await $app->($scope, $receive, $send);
            return;
        }

        my ($authority, $authority_error);
        {
            local $@;
            $authority = eval { PAGI::Authority->from_scope($scope) };
            $authority_error = $@;
        }
        if ($authority_error) {
            await $self->_send_error($scope, $send, 400);
            return;
        }

        my $path = $scope->{path} // '/';
        my $url = "https://$authority$path";

        await $self->_send_redirect($scope, $send, $url);
    };
}

sub _is_excluded {
    my ($self, $path) = @_;

    for my $pattern (@{$self->{exclude}}) {
        if (ref $pattern eq 'Regexp') {
            return 1 if $path =~ $pattern;
        } else {
            return 1 if $path eq $pattern;
        }
    }
    return 0;
}

async sub _send_redirect {
    my ($self, $scope, $send, $location) = @_;
    my $response = PAGI::Pages->redirect(
        $scope,
        $location,
        status         => $self->{redirect_code},
        preserve_query => 1,
    );
    await Future->wrap($response->respond($send));
}

async sub _send_error {
    my ($self, $scope, $send, $status) = @_;
    croak "HTTPSRedirect does not own status $status" unless $status == 400;
    my $response = PAGI::Pages->bad_request($scope);
    await Future->wrap($response->respond($send));
}

1;

__END__

=head1 NOTES

This middleware checks C<$scope-E<gt>{scheme}> to determine if the request
is already using HTTPS. Make sure your server sets this correctly, especially
when behind a reverse proxy (use ReverseProxy middleware).

Host validation and server fallback are only used when constructing an HTTP
redirect. Existing HTTPS, excluded paths, and non-HTTP scopes retain their
pass-through behavior. In redirect branches, Pages owns the negotiated body,
Location construction, fragment-safe raw-query preservation, and response
validation. HSTS is still added only to responses from an already-secure
request when enabled.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::ReverseProxy> - Handle X-Forwarded headers

=cut
