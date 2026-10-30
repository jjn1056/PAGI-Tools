package PAGI::Middleware::Cookie;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use PAGI::Utils::_SetCookie ();
use PAGI::HTTPConnection ();
use PAGI::Utils ();

=head1 NAME

PAGI::Middleware::Cookie - Cookie parsing middleware

=head1 SYNOPSIS

    use PAGI::Tools qw(compose middleware response route);

    my $app = compose(
        routes     => [route('/' => sub { response('Text', 'hello') })],
        middleware => [middleware('Cookie')],
    );

The parsed cookies are in the scope:

    # In your app:
    async sub app {
        my ($scope, $receive, $send) = @_;

        my $cookies = $scope->{'pagi.cookies'};
        my $session_id = $cookies->{session_id};
    }

C<middleware('Cookie')> also goes in a Router's, Mount's or Route's
C<middleware> list. It constructs the middleware and wraps the application
inside it, which you can do yourself:

    use PAGI::Middleware::Cookie;

    my $wrapped = PAGI::Middleware::Cookie->new->wrap($native_app);

Without Compose, L<PAGI::Middleware::Builder> composes middleware the way
Plack::Builder does.

=head1 DESCRIPTION

PAGI::Middleware::Cookie parses the Cookie header and makes the parsed
cookies available in C<< $scope->{'pagi.cookies'} >> as a hashref, read as
L<PAGI::HTTPConnection/cookies> reads them: from every Cookie field, quotes
removed, never percent-decoded, the last of a repeated name winning.

It also provides a helper for setting response cookies.

=head1 CONFIGURATION

An option not listed here dies at construction.

=over 4

=item * secret (optional)

Secret key for signed cookies. Required for C<get_signed>/C<set_signed>.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{secret} = $config->{secret};
    PAGI::Utils::_reject_unknown_options('Cookie', $config,
        qw(secret));
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Every Cookie field, as PAGI::HTTPConnection reads them
        my $cookies = PAGI::HTTPConnection->new($scope)->cookies;

        # Create cookie jar for setting response cookies
        my @response_cookies;
        my $cookie_jar = PAGI::Middleware::Cookie::Jar->new(
            \@response_cookies,
            sub { $self->_format_set_cookie(@_) },
        );

        # Add cookies and jar to scope
        my $new_scope = $self->modify_scope($scope, {
            'pagi.cookies'    => $cookies,
            'pagi.cookie_jar' => $cookie_jar,
        });

        # Wrap send to add Set-Cookie headers
        my $wrapped_send = async sub  {
        my ($event) = @_;
            if ($event->{type} eq 'http.response.start' && @response_cookies) {
                my @headers = @{$event->{headers} // []};
                for my $cookie (@response_cookies) {
                    push @headers, ['Set-Cookie', $cookie];
                }
                await $send->({
                    %$event,
                    headers => \@headers,
                });
            } else {
                await $send->($event);
            }
        };

        await $app->($new_scope, $receive, $wrapped_send);
    };
}

sub _format_set_cookie {
    my ($self, $name, $value, %opts) = @_;

    my %cookie_opts = (path => $opts{path} // '/');
    $cookie_opts{domain}    = $opts{domain}   if defined $opts{domain};
    $cookie_opts{expires}   = $opts{expires}  if defined $opts{expires};
    $cookie_opts{'max-age'} = $opts{max_age}  if defined $opts{max_age};
    $cookie_opts{secure}    = $opts{secure}   if $opts{secure};
    $cookie_opts{httponly}  = $opts{httponly} if $opts{httponly};
    $cookie_opts{samesite}  = $opts{samesite} if defined $opts{samesite};
    return PAGI::Utils::_SetCookie::set_cookie_string($name, $value, %cookie_opts);
}

# Simple cookie jar class for method-style access
package PAGI::Middleware::Cookie::Jar;

use strict;
use warnings;

# A croak from the cookie writer blames the jar's caller, not this hand-off.
our @CARP_NOT = qw(PAGI::Middleware::Cookie);

sub new {
    my ($class, $cookies_ref, $formatter) = @_;

    return bless {
        cookies   => $cookies_ref,
        formatter => $formatter,
    }, $class;
}

sub set {
    my ($self, $name, $value, %opts) = @_;

    push @{$self->{cookies}}, $self->{formatter}->($name, $value, %opts);
}

sub delete {
    my ($self, $name, %opts) = @_;

    my %cookie_opts = (
        expires => 0,  # Epoch 0 = expired
        path    => $opts{path} // '/',
    );
    $cookie_opts{domain} = $opts{domain} if defined $opts{domain};
    push @{$self->{cookies}}, PAGI::Utils::_SetCookie::set_cookie_string($name, '', %cookie_opts);
}

package PAGI::Middleware::Cookie;

1;

__END__

=head1 SCOPE EXTENSIONS

This middleware adds the following to $scope:

=over 4

=item * pagi.cookies

Hashref of parsed cookies from the Cookie header.

=item * pagi.cookie_jar

Object with methods for setting response cookies:

    $scope->{'pagi.cookie_jar'}->set('name', 'value',
        path     => '/',
        httponly => 1,
        secure   => 1,
        samesite => 'Strict',
        max_age  => 3600,
    );

    $scope->{'pagi.cookie_jar'}->delete('name');

C<set> writes the value as is, so it must be RFC 6265 cookie-octets:
printable ASCII except space, C<">, C<,>, C<;> and C<\>. Any other
character croaks, naming it, with "encode it first (Base64, say)"; nothing
is percent-encoded. The name must be a non-empty RFC 6265 token (letters,
digits and C<!#$%&'*+-.^_`|~>), else it croaks too, and an undefined value
croaks. A C<samesite> option that is given must be C<Lax>, C<Strict> or
C<None> (any case, the whole word), else it croaks; without it no SameSite
attribute is written.
L<PAGI::Response/cookie> follows the same rules.

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::Session> - Session management using cookies

=cut

