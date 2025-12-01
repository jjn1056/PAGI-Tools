package PAGI::Middleware::Cookie;

use strict;
use warnings;
use experimental 'signatures';
use parent 'PAGI::Middleware';
use Future::AsyncAwait;

=head1 NAME

PAGI::Middleware::Cookie - Cookie parsing middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'Cookie';
        $my_app;
    };

    # In your app:
    async sub app ($scope, $receive, $send) {
        my $cookies = $scope->{'pagi.cookies'};
        my $session_id = $cookies->{session_id};
    }

=head1 DESCRIPTION

PAGI::Middleware::Cookie parses the Cookie header and makes the parsed
cookies available in C<$scope->{'pagi.cookies'}> as a hashref.

It also provides a helper for setting response cookies.

=head1 CONFIGURATION

=over 4

=item * secret (optional)

Secret key for signed cookies. Required for C<get_signed>/C<set_signed>.

=back

=cut

sub _init ($self, $config) {
    $self->{secret} = $config->{secret};
}

sub wrap ($self, $app) {
    return async sub ($scope, $receive, $send) {
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Parse cookies from Cookie header
        my $cookie_header = $self->_get_header($scope, 'cookie') // '';
        my $cookies = $self->_parse_cookies($cookie_header);

        # Create cookie jar for setting response cookies
        my @response_cookies;
        my $cookie_jar = PAGI::Middleware::Cookie::Jar->new(
            \@response_cookies,
            sub { $self->_format_set_cookie(@_) },
        );

        # Add cookies and jar to scope
        my $new_scope = {
            %$scope,
            'pagi.cookies'    => $cookies,
            'pagi.cookie_jar' => $cookie_jar,
        };

        # Wrap send to add Set-Cookie headers
        my $wrapped_send = async sub ($event) {
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

sub _parse_cookies ($self, $header) {
    my %cookies;

    for my $pair (split /\s*;\s*/, $header) {
        my ($name, $value) = split /=/, $pair, 2;
        next unless defined $name && $name ne '';

        $name =~ s/^\s+//;
        $name =~ s/\s+$//;
        $value //= '';
        $value =~ s/^\s+//;
        $value =~ s/\s+$//;

        # Remove surrounding quotes if present
        $value =~ s/^"(.*)"$/$1/;

        $cookies{$name} = $value;
    }

    return \%cookies;
}

sub _format_set_cookie ($self, $name, $value, %opts) {
    my $cookie = "$name=$value";

    if (defined $opts{expires}) {
        $cookie .= "; Expires=$opts{expires}";
    }
    if (defined $opts{max_age}) {
        $cookie .= "; Max-Age=$opts{max_age}";
    }
    if (defined $opts{domain}) {
        $cookie .= "; Domain=$opts{domain}";
    }
    if (defined $opts{path}) {
        $cookie .= "; Path=$opts{path}";
    } else {
        $cookie .= "; Path=/";
    }
    if ($opts{secure}) {
        $cookie .= "; Secure";
    }
    if ($opts{httponly}) {
        $cookie .= "; HttpOnly";
    }
    if (defined $opts{samesite}) {
        $cookie .= "; SameSite=$opts{samesite}";
    }

    return $cookie;
}

sub _get_header ($self, $scope, $name) {
    $name = lc($name);
    for my $h (@{$scope->{headers} // []}) {
        return $h->[1] if lc($h->[0]) eq $name;
    }
    return;
}

# Simple cookie jar class for method-style access
package PAGI::Middleware::Cookie::Jar;

use strict;
use warnings;
use experimental 'signatures';

sub new ($class, $cookies_ref, $formatter) {
    return bless {
        cookies   => $cookies_ref,
        formatter => $formatter,
    }, $class;
}

sub set ($self, $name, $value, %opts) {
    push @{$self->{cookies}}, $self->{formatter}->($name, $value, %opts);
}

sub delete ($self, $name, %opts) {
    push @{$self->{cookies}}, $self->{formatter}->(
        $name, '',
        expires => 'Thu, 01 Jan 1970 00:00:00 GMT',
        %opts
    );
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

=back

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::Session> - Session management using cookies

=cut
