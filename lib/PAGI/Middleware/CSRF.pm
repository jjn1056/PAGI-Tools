package PAGI::Middleware::CSRF;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future;
use Future::AsyncAwait;
use PAGI::Utils::Random qw(secure_random_bytes);
use PAGI::Utils::SecureCompare qw(secure_compare);
use PAGI::Response::Text ();
use PAGI::Utils ();

=head1 NAME

PAGI::Middleware::CSRF - Cross-Site Request Forgery protection middleware

=head1 SYNOPSIS

    use PAGI::Compose qw(compose);
    use PAGI::Response qw(response);
    use PAGI::Routing qw(middleware);

    # Refuse a failed check with a 403 text response (the default)
    middleware('CSRF');

    # Refuse it with your own application or Response
    middleware('CSRF',
        refuse => response('JSON', { detail => 'CSRF token validation failed' }, status => 403));

    # Let the application decide: every request reaches it, with the outcome
    # recorded for csrf($request)->valid and ->failure
    middleware('CSRF', refuse => 0);

L<PAGI::CSRF/SYNOPSIS> shows both modes in full, as complete applications.

=head1 DESCRIPTION

PAGI::Middleware::CSRF provides protection against Cross-Site Request
Forgery attacks by validating tokens on state-changing requests. Its default
refusal is a plain 403 text response; C<refuse> replaces it, or lets the
application decide. L<PAGI::CSRF/SYNOPSIS> shows both, as complete
applications.

=head1 CONFIGURATION

An option not listed here dies at construction.

=over 4

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

=item * httponly (default: 0)

Add C<HttpOnly> to the CSRF cookie, so scripts cannot read it. Off by
default: the double-submit pattern needs the page's script to send the
token back, and front-end libraries (Angular, Axios) read it from the
cookie. C<HttpOnly> adds no protection against cross-site requests; turn it
on if an audit requires it, and render C<< csrf($request)->token >> into
the page instead (see L</USAGE>).

=item * refuse (default: a 403 text response)

What answers an unsafe request whose token check fails. Absent: a
C<403 text/plain> response, C<CSRF token validation failed>. An application
-- a Request handler (a coderef called with one
L<PAGI::Request>, returning a Response or an application) or an object
with C<to_app>, which
includes every L<PAGI::Response> -- answers instead, and can read the reason
with C<< csrf($request)->failure >>. Exactly C<0>: the middleware never refuses;
the request reaches the application with the outcome recorded for
C<< csrf($request)->valid >> and C<< ->failure >>. Any other plain value dies.

A native C<($scope, $receive, $send)> application is passed as
C<as_app_object($app)>. Objects -- every Response and L<PAGI::Pages> value --
mean the same in every slot, and are the portable form for anything also
given to middleware outside PAGI-Tools.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    die "CSRF 'enforce' was removed: use refuse => 0 for the application to decide; the default refuses"
        if exists $config->{enforce};
    die 'CSRF no longer takes a secret: its tokens are random; for tokens bound to the session use session => 1'
        if exists $config->{secret};

    $self->{token_header} = $config->{token_header} // 'X-CSRF-Token';
    $self->{cookie_name}  = $config->{cookie_name} // 'csrf_token';
    $self->{safe_methods} = { map { $_ => 1 } @{$config->{safe_methods} // [qw(GET HEAD OPTIONS TRACE)]} };
    $self->{secure}       = $config->{secure} // 0;
    $self->{httponly}     = _flag($config, 'httponly');

    # Absent: the default refusal. Exactly 0: the application decides.
    my $refuse = PAGI::Utils::_refuse_option('CSRF', $config, 1);
    $self->{refuse} = !defined($refuse) ? PAGI::Response::Text->new(
            'CSRF token validation failed', status => 403,
        )->to_app
        : ref($refuse) ? $refuse
        : undef;
    PAGI::Utils::_reject_unknown_options('CSRF', $config,
        qw(cookie_name httponly refuse safe_methods secure token_header));
}

# A 0-or-1 option; absent is 0.
sub _flag {
    my ($config, $name) = @_;
    my $value = $config->{$name} // 0;
    die "CSRF $name must be 0 or 1"
        unless !ref($value) && ($value eq '0' || $value eq '1');
    return $value + 0;
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
        my %recorded = ('pagi.csrf_token' => $token);
        unless ($self->{safe_methods}{$scope->{method}}) {
            my $failure = $self->_failure_for(
                $cookie_token, $self->_get_submitted_token($scope));
            $recorded{'pagi.csrf_failure'} = $failure if defined $failure;
        }

        # A minted token is set on whatever response leaves, a refusal
        # included, so the client's next attempt can carry it. The event is
        # copied: an application may reuse its headers arrayref, and a
        # cookie added to it would reach every later client.
        my $wrapped_send = defined $cookie_token ? $send : async sub {
            my ($event) = @_;
            if ($event->{type} eq 'http.response.start') {
                my $cookie = "$self->{cookie_name}=$token; Path=/"
                    . ($self->{httponly} ? '; HttpOnly' : '')
                    . '; SameSite=Strict';
                $cookie .= "; Secure" if $self->{secure};
                $event = {
                    %$event,
                    headers => [@{$event->{headers} // []}, ['Set-Cookie', $cookie]],
                };
            }
            await $send->($event);
        };

        my $target = exists($recorded{'pagi.csrf_failure'}) && $self->{refuse}
            ? $self->{refuse} : $app;
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

# 32 bytes from the system's secure random source, as 64 hex characters.
sub _generate_token {
    return unpack('H*', secure_random_bytes(32));
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

The CSRF middleware uses a double-submit token: it issues a random token
in a cookie, and an unsafe request is valid only if it also carries the
same token another way -- a request header (the default) or a form field
(C<refuse =E<gt> 0>). The page's script can read the cookie, or the page
can carry the token itself (required under C<httponly> or C<session>).

=head2 Header flow (the default)

Use this for JSON/AJAX APIs, where the client can set a custom request
header. The middleware validates the header itself; the app is never called
on a mismatch.

Render the token into the page once (a C<< <meta> >> tag is the usual spot),
reading it from the CSRF facade (or let the script read the cookie, unless
C<httponly> is on):

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

=head2 Form flow (refuse => 0)

Use this for server-rendered HTML forms. A plain C<< <form> >> POST has no
way to add a custom header, so the default would 403 every such submission --
that's precisely why C<refuse =E<gt> 0> exists: the middleware issues the
token (on every method, including the POST itself) and records its header
check, but never refuses; the app validates once it has parsed the submitted
params.

Embed the token as a hidden field:

    my $guard = csrf($request);

    <input type="hidden" name="_csrf_token" value="<%= $guard->token %>">

Then, in the handler, verify the submitted value against the one the
middleware stashed in scope:

    use PAGI::Response qw(response);

    return response('Text', 'CSRF token validation failed', status => 403)
        unless $guard->verify($params->{_csrf_token});

The same helper works in a raw-scope application:

    my $guard = csrf($scope);
    my $token = $guard->token;
    my $valid = $guard->verify($params->{_csrf_token});

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::CSRF> - request-first and raw-scope token access and verification

=cut
