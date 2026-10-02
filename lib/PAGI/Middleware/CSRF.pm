package PAGI::Middleware::CSRF;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future;
use Future::AsyncAwait;
use Digest::SHA qw(sha256_hex);
use PAGI::Utils::Random qw(secure_random_bytes);
use PAGI::Utils::SecureCompare qw(secure_compare);
use PAGI::Response::Text ();
use PAGI::Utils ();

=head1 NAME

PAGI::Middleware::CSRF - Cross-Site Request Forgery protection middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;
    use PAGI::CSRF qw(csrf);

    my $app = builder {
        enable 'CSRF',
            secret       => 'your-secret-key',
            token_header => 'X-CSRF-Token',
            cookie_name  => 'csrf_token',
            safe_methods => ['GET', 'HEAD', 'OPTIONS'];
        $my_app;
    };

    # Issue-only mode: the middleware never rejects; the app validates via
    # csrf($request)->verify once it has parsed the submitted form/JSON params.
    my $app2 = builder {
        enable 'CSRF', secret => 'your-secret-key', enforce => 'app';
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::CSRF provides protection against Cross-Site Request
Forgery attacks by validating tokens on state-changing requests. Its default
refusal is a plain 403 text response; C<invalid> replaces it, or lets the
application decide. L<PAGI::CSRF/SYNOPSIS> shows both, as complete
applications.

=head1 CONFIGURATION

=over 4

=item * secret (required)

Secret key used for token generation.

=item * token_header (default: 'X-CSRF-Token')

Header name to look for the CSRF token.

=item * cookie_name (default: 'csrf_token')

Cookie name for the CSRF token.

=item * safe_methods (default: ['GET', 'HEAD', 'OPTIONS', 'TRACE'])

HTTP methods that don't require CSRF validation.

=item * secure (default: 0)

Add the C<Secure> attribute to the CSRF cookie, restricting it to HTTPS
requests. Off by default so plain-HTTP development setups keep working;
for production HTTPS deployments, add C<< secure => 1 >>.

=item * invalid (default: a 403 text response)

What answers an unsafe request whose token check fails. Absent: a
C<403 text/plain> response, C<CSRF token validation failed>. An application
-- a C<($scope, $receive, $send)> coderef or an object with C<to_app>, which
includes every L<PAGI::Response> -- answers instead, and can read the reason
with C<< csrf($scope)->failure >>. Exactly C<0>: the middleware never refuses;
the request reaches the application with the outcome recorded for
C<< csrf($request)->valid >> and C<< ->failure >>. Any other plain value dies.

=item * enforce (default: 'header')

How unsafe methods (anything not in C<safe_methods>) are checked:

=over 4

=item * C<'header'> - the middleware itself validates: the request must
carry a C<token_header> whose value matches the cookie token, or the
middleware responds 403 and the app is never called. This only works for
requests that can set a custom header (typically AJAX/fetch); a plain HTML
form POST has no way to add one, so a server-rendered form under this mode
would always 403 -- see L</USAGE> for why.

=item * C<'app'> - issue-only. The middleware mints/persists the cookie
token exactly as it does for safe methods, on I<every> method, and never
auto-rejects. It stashes the cookie token (the existing one, or a freshly
minted one if none existed yet) into scope as C<csrf_token> for the app to
read with C<< csrf($request)->token >>. The app owns validation, by calling
C<< csrf($request)->verify($submitted) >> once it has parsed the request's
params, and decides the response for a failed check. Raw PAGI applications can
pass the scope directly as C<csrf($scope)>. This is what server-rendered form
POSTs need.

=back

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{secret}       = $config->{secret} // die "CSRF middleware requires 'secret' option";
    $self->{token_header} = $config->{token_header} // 'X-CSRF-Token';
    $self->{cookie_name}  = $config->{cookie_name} // 'csrf_token';
    $self->{safe_methods} = { map { $_ => 1 } @{$config->{safe_methods} // [qw(GET HEAD OPTIONS TRACE)]} };
    $self->{secure}       = $config->{secure} // 0;

    $self->{enforce} = $config->{enforce} // 'header';
    die "CSRF middleware 'enforce' must be 'header' or 'app', got '$self->{enforce}'"
        unless $self->{enforce} eq 'header' || $self->{enforce} eq 'app';

    # invalid: absent -> the default refusal; exactly 0 -> the application
    # decides; otherwise an application. Any other plain value (undef, '',
    # '0E0', a string) is a configuration mistake, never a quiet way to
    # switch protection off.
    if (!exists $config->{invalid}) {
        $self->{invalid} = $self->{enforce} eq 'app' ? undef : PAGI::Response::Text->new(
            'CSRF token validation failed', status => 403,
        )->to_app;
    }
    else {
        my $invalid = $config->{invalid};
        if (defined($invalid) && !ref($invalid) && $invalid eq '0') {
            $self->{invalid} = undef;
        }
        elsif (!ref($invalid)) {
            die "CSRF 'invalid' must be an application, or 0 to let the application decide";
        }
        else {
            $self->{invalid} = PAGI::Utils::to_app($invalid);
        }
    }
}

sub wrap {
    my ($self, $app) = @_;

    return async sub {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # The existing cookie token, never a regenerated one, so a token the
        # client already holds still has something to match.
        my $cookie_token = $self->_get_cookie_token($scope);
        my $token = $cookie_token // $self->_generate_token();
        my %recorded = (csrf_token => $token);
        unless ($self->{safe_methods}{$scope->{method}}) {
            my $failure = $self->_failure_for(
                $cookie_token, $self->_get_submitted_token($scope));
            $recorded{csrf_failure} = $failure if defined $failure;
        }

        # A minted token is set on whatever response leaves, a refusal
        # included, so the client's next attempt can carry it.
        my $wrapped_send = defined $cookie_token ? $send : async sub {
            my ($event) = @_;
            if ($event->{type} eq 'http.response.start') {
                my $cookie = "$self->{cookie_name}=$token; Path=/; HttpOnly; SameSite=Strict";
                $cookie .= "; Secure" if $self->{secure};
                push @{$event->{headers}}, ['Set-Cookie', $cookie];
            }
            await $send->($event);
        };

        my $target = exists($recorded{csrf_failure}) && $self->{invalid}
            ? $self->{invalid} : $app;
        await $target->($self->modify_scope($scope, \%recorded), $receive, $wrapped_send);
    };
}

# Why an unsafe request's header check fails, or undef when it passes.
# Compared in constant time.
sub _failure_for {
    my ($self, $cookie_token, $submitted) = @_;
    return 'missing_cookie' unless defined($cookie_token) && length($cookie_token);
    return 'missing_token' unless defined($submitted) && length($submitted);
    return 'mismatch' unless secure_compare($submitted, $cookie_token);
    return undef;
}

sub _generate_token {
    my ($self) = @_;

    # Use cryptographically secure random bytes
    my $random = secure_random_bytes(32);
    return sha256_hex($self->{secret} . time() . $random . $$);
}

sub _get_cookie_token {
    my ($self, $scope) = @_;

    my $cookie_header = $self->_get_header($scope, 'cookie');
    return unless $cookie_header;

    my $name = $self->{cookie_name};
    if ($cookie_header =~ /(?:^|;\s*)\Q$name\E=([^;]+)/) {
        return $1;
    }
    return;
}

sub _get_submitted_token {
    my ($self, $scope) = @_;
    return $self->_get_header($scope, $self->{token_header});
}

sub _get_header {
    my ($self, $scope, $name) = @_;

    $name = lc($name);
    for my $h (@{$scope->{headers} // []}) {
        return $h->[1] if lc($h->[0]) eq $name;
    }
    return;
}

1;

__END__

=head1 USAGE

The CSRF middleware always uses a double-submit cookie pattern: a token is
generated and stored in an C<HttpOnly> cookie, and a request is only valid if
it also carries that same token some other way -- because C<HttpOnly> means
client-side JavaScript cannot read the cookie itself (C<document.cookie>
won't show it, and neither would a hypothetical C<getCookie> helper). That
"some other way" is where the two C<enforce> modes diverge.

=head2 Header flow (enforce => 'header', the default)

Use this for JSON/AJAX APIs, where the client can set a custom request
header. The middleware validates the header itself; the app is never called
on a mismatch.

Render the token into the page once (a C<< <meta> >> tag is the usual spot),
reading it from the CSRF facade -- B<not> from the cookie, which
JavaScript cannot see:

    my $guard = csrf($request);
    my $token = $guard->token;

    <meta name="csrf-token" content="<%= $token %>">

Then have client-side script read the meta tag and send it back as the
configured header:

    const token = document.querySelector('meta[name="csrf-token"]').content;
    fetch('/api/resource', {
        method: 'POST',
        headers: { 'X-CSRF-Token': token },
    });

=head2 Form flow (enforce => 'app')

Use this for server-rendered HTML forms. A plain C<< <form> >> POST has no
way to add a custom header, so C<enforce => 'header'> would 403 every such
submission -- that's precisely why this mode exists: the middleware only
issues the token (on every method, including the POST itself) and never
auto-rejects; the app validates once it has parsed the submitted params.

Embed the token as a hidden field:

    my $guard = csrf($request);

    <input type="hidden" name="_csrf_token" value="<%= $guard->token %>">

Then, in the handler, verify the submitted value against the one the
middleware stashed in scope:

    use PAGI::Pages;

    return PAGI::Pages->forbidden(
        detail => 'CSRF token validation failed',
    )
        unless $guard->verify($params->{_csrf_token});

The same helper works in a raw-scope application:

    my $guard = csrf($scope);
    my $token = $guard->token;
    my $valid = $guard->verify($params->{_csrf_token});

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::CSRF> - request-first and raw-scope token access and verification

=cut
