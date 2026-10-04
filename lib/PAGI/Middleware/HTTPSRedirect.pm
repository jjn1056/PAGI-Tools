package PAGI::Middleware::HTTPSRedirect;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use PAGI::Authority;
use PAGI::Response::Redirect ();
use PAGI::Response::Text ();
use PAGI::Utils ();
use PAGI::Utils::Scope ();

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
scope server tuple. It never invents a C<localhost> authority: a duplicate or
malformed Host, or no Host and an unusable server tuple, is refused with a
plain-text 400, C<Invalid Host header>, and a request target that is not a
path (C<GET http://evil/x>) with C<Invalid request target>, since a redirect
built from it could name another host. C<refuse> replaces the refusal.

Redirect targets use L<PAGI::Response::Redirect>. The redirect target is
C<https://>, the authority, and L<PAGI::Request/request_uri>: the path and
query the client requested, still encoded, including any mount prefix.
Authority selection, exclusions, secure-request pass-through, and HSTS remain
owned by this middleware.

Use it when PAGI::Server itself accepts plain HTTP from clients. Behind a
TLS-terminating proxy or load balancer, the proxy usually does this redirect,
and every request reaches the application as C<http>: without
L<PAGI::Middleware::ReverseProxy> placed before this middleware to restore the
scheme from C<X-Forwarded-Proto>, it redirects every request, forever.

Non-HTTP scopes continue to pass through unchanged without authority handling.

=head1 CONFIGURATION

An option not listed here dies at construction.

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

=item * refuse (default: a 400 text response)

An application that answers a refused request instead of the plain-text
default: a Request handler (a coderef called with one
L<PAGI::Request>, returning a Response or an application) or an object
with C<to_app>, which includes every L<PAGI::Response>:

    middleware('HTTPSRedirect',
        refuse => response('JSON', { detail => 'Cannot redirect to HTTPS' }, status => 400));

For a malformed Host it receives a scope holding only the request's
well-formed C<Accept> headers. A refused request is never passed on over
plain HTTP, so there is no C<0> form; leave paths on HTTP with C<exclude>.
Any plain value dies.

A native C<($scope, $receive, $send)> application is passed as
C<as_app_object($app)>. Objects -- every Response and L<PAGI::Pages> value --
mean the same in every slot, and are the portable form for anything also
given to middleware outside PAGI-Tools.

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

    # The caller's refusing application, or plain-text defaults built once.
    $self->{refuse} = PAGI::Utils::_refuse_option('HTTPSRedirect', $config);
    $self->{_default_refusal} = {
        host   => PAGI::Response::Text->new('Invalid Host header', status => 400)->to_app,
        target => PAGI::Response::Text->new('Invalid request target', status => 400)->to_app,
    };
    PAGI::Utils::_reject_unknown_options('HTTPSRedirect', $config,
        qw(exclude hsts hsts_max_age redirect_code refuse));
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
            await $self->_refuse($self->_refusal_scope_for_authority_error($scope),
                $receive, $send, 'host');
            return;
        }

        # The URI the client requested, still encoded: the mount prefix
        # stays, and a client's %3F or %23 cannot become a query or fragment.
        # Only a path can follow the authority: anything else ("@evil/x")
        # would name another host. OPTIONS * has nothing to redirect.
        my $target = PAGI::Utils::Scope::request_uri($scope);
        if ($target eq '*') {
            await $app->($scope, $receive, $send);
            return;
        }
        if (substr($target, 0, 1) ne '/') {
            await $self->_refuse($scope, $receive, $send, 'target');
            return;
        }
        my $url = "https://$authority$target";

        await $self->_send_redirect($scope, $receive, $send, $url);
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
    my ($self, $scope, $receive, $send, $location) = @_;
    my $response = PAGI::Response::Redirect->new(
        $location,
        status => $self->{redirect_code},
    );
    await PAGI::Utils::invoke_app($response, $scope, $receive, $send);
}

async sub _refuse {
    my ($self, $scope, $receive, $send, $reason) = @_;
    my $refusal = $self->{refuse} // $self->{_default_refusal}{$reason};
    await $refusal->($scope, $receive, $send);
}

1;

__END__

=head1 NOTES

This middleware checks C<$scope-E<gt>{scheme}> to determine if the request
is already using HTTPS. Make sure your server sets this correctly, especially
when behind a reverse proxy (use ReverseProxy middleware).

Host validation and server fallback are only used when constructing an HTTP
redirect. Existing HTTPS, excluded paths, and non-HTTP scopes retain their
pass-through behavior. In redirect branches, this middleware constructs the
final Location and Redirect validates and renders it. HSTS is still added
only to responses from an already-secure request when enabled.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::ReverseProxy> - Handle X-Forwarded headers

=cut
