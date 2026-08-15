package PAGI::Middleware::Rewrite;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use PAGI::Pages;

=head1 NAME

PAGI::Middleware::Rewrite - URL rewriting middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'Rewrite',
            rules => [
                { from => qr{^/old/(.*)}, to => '/new/$1' },
                { from => '/legacy', to => '/modern' },
            ];
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::Rewrite rewrites request paths before passing to the
inner application. Supports both exact matches and regex patterns. Redirect
mode renders through L<PAGI::Pages> using the original request scope, preserves
the incoming raw query without re-encoding, and places it before the first
target fragment. Rule selection and internal rewriting remain local, and there
is no Pages configuration option.

=head1 CONFIGURATION

=over 4

=item * rules (required)

Arrayref of rewrite rules. Each rule is a hashref with:

    { from => '/old-path', to => '/new-path' }
    { from => qr{^/user/(\d+)}, to => '/users/$1' }

=item * redirect (default: 0)

If true, send redirect response instead of rewriting internally.

=item * redirect_code (default: 301)

HTTP status code for redirects. The supported values are exactly 301, 302, 303,
307, and 308; invalid values croak during construction.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{rules} = $config->{rules}
        // die "Rewrite middleware requires 'rules' option";
    $self->{redirect} = $config->{redirect} // 0;
    my $redirect_code = exists($config->{redirect_code})
        ? $config->{redirect_code} : 301;
    my %supported_redirect_code = map { $_ => 1 } qw(301 302 303 307 308);
    my ($canonical_redirect_code, $normalized_redirect_code);
    if (defined($redirect_code) && !ref($redirect_code)) {
        $canonical_redirect_code = "$redirect_code";
        $normalized_redirect_code = 0 + $redirect_code
            if $supported_redirect_code{$canonical_redirect_code};
    }
    croak 'Rewrite redirect_code must be one of 301, 302, 303, 307, or 308'
        unless defined($normalized_redirect_code)
            && $supported_redirect_code{$normalized_redirect_code}
            && "$normalized_redirect_code" eq $canonical_redirect_code;
    $self->{redirect_code} = $normalized_redirect_code;
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        my $path = $scope->{path};
        my $new_path = $self->_apply_rules($path);

        # No rewrite needed
        if ($new_path eq $path) {
            await $app->($scope, $receive, $send);
            return;
        }

        # Redirect mode
        if ($self->{redirect}) {
            await $self->_send_redirect($scope, $send, $new_path);
            return;
        }

        # Internal rewrite
        my $new_scope = $self->modify_scope($scope, {
            path          => $new_path,
            original_path => $scope->{original_path} // $path,
        });

        await $app->($new_scope, $receive, $send);
    };
}

sub _apply_rules {
    my ($self, $path) = @_;

    for my $rule (@{$self->{rules}}) {
        my $from = $rule->{from};
        my $to = $rule->{to};

        if (ref $from eq 'Regexp') {
            if ($path =~ $from) {
                my @captures = ($path =~ $from);
                my $new_path = $to;
                for my $i (0 .. $#captures) {
                    my $n = $i + 1;
                    $new_path =~ s/\$$n/$captures[$i]/g;
                }
                return $new_path;
            }
        } else {
            if ($path eq $from) {
                return $to;
            }
            # Also check prefix match for directory-like rules
            if ($path =~ m{^\Q$from\E(/.*)?$}) {
                my $suffix = $1 // '';
                return $to . $suffix;
            }
        }
    }

    return $path;
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

1;

__END__

=head1 REWRITE PATTERNS

Regex patterns can use capture groups:

    { from => qr{^/blog/(\d{4})/(\d{2})}, to => '/archive/$1-$2' }

This would rewrite C</blog/2024/01> to C</archive/2024-01>.

Internal rewrite mode passes the rewritten scope to the inner application and
does not invoke Pages. Unmatched HTTP requests and all non-HTTP scopes retain
their existing pass-through behavior. Redirect mode passes the unmodified
logical rule target to Pages, which validates it and performs fragment-safe
query preservation before sending the response.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::HTTPSRedirect> - Force HTTPS redirects

=cut
