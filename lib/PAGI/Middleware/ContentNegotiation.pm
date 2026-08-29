package PAGI::Middleware::ContentNegotiation;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future;
use Future::AsyncAwait;
use PAGI::Pages;
use PAGI::Request::Negotiate;

=head1 NAME

PAGI::Middleware::ContentNegotiation - HTTP content negotiation middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'ContentNegotiation',
            supported_types => ['application/json', 'text/html', 'text/plain'],
            default_type => 'application/json';
        $my_app;
    };

    # In your app:
    async sub app {
        my ($scope, $receive, $send) = @_;

        my $preferred = $scope->{'pagi.preferred_content_type'};
        if ($preferred eq 'application/json') {
            # Return JSON
        } else {
            # Return HTML
        }
    }

=head1 DESCRIPTION

PAGI::Middleware::ContentNegotiation parses the Accept header and determines
the best content type to return using the shared L<PAGI::Request::Negotiate>
matching rules. It adds the preferred type and parsed accepted types to the
scope for the application to use. In strict mode, an unmatched request is
answered directly with a negotiated L<PAGI::Pages> 406 response; the wrapped
application is not redispatched.

=head1 CONFIGURATION

=over 4

=item * supported_types (required)

Array of MIME types the application supports.

=item * default_type (optional)

Default type when no Accept header or no match. Defaults to first supported type.

=item * strict (default: 0)

If true, return 406 Not Acceptable when no supported type matches.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{supported_types} = $config->{supported_types}
        // die "ContentNegotiation requires 'supported_types' option";
    $self->{default_type} = $config->{default_type}
        // $self->{supported_types}[0];
    $self->{strict} = $config->{strict} // 0;
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Parse Accept header
        my $accept = $self->_get_header($scope, 'accept') // '*/*';
        my $preferred = PAGI::Request::Negotiate->best_match(
            $self->{supported_types}, $accept,
        );

        if (!$preferred && $self->{strict}) {
            await $self->_send_not_acceptable($scope, $receive, $send);
            return;
        }

        $preferred //= $self->{default_type};

        # Add preferred type to scope
        my @accepted = $self->_parse_accept($accept);
        my $new_scope = $self->modify_scope($scope, {
            'pagi.preferred_content_type' => $preferred,
            'pagi.accepted_types' => \@accepted,
        });

        await $app->($new_scope, $receive, $send);
    };
}

sub _parse_accept {
    my ($self, $accept) = @_;

    return map {
        +{ type => $_->[0], q => $_->[1] }
    } PAGI::Request::Negotiate->parse_accept($accept);
}

sub _get_header {
    my ($self, $scope, $name) = @_;

    $name = lc($name);
    my @values;
    for my $h (@{$scope->{headers} // []}) {
        push @values, $h->[1] if lc($h->[0]) eq $name;
    }
    return unless @values;
    return join(', ', @values);
}

async sub _send_not_acceptable {
    my ($self, $scope, $receive, $send) = @_;

    my $supported = join(', ', @{$self->{supported_types}});
    my $response = PAGI::Pages->not_acceptable(
        $scope,
        detail => "Not Acceptable. Supported types: $supported",
    );
    await Future->wrap($response->respond($scope, $receive, $send));
}

1;

__END__

=head1 SCOPE EXTENSIONS

This middleware adds the following to $scope:

=over 4

=item * pagi.preferred_content_type

The best matching MIME type from the supported types.

=item * pagi.accepted_types

Array of parsed Accept header entries in the shared preference order.

=back

=head1 ACCEPT HEADER PARSING

The Accept header is parsed by L<PAGI::Request::Negotiate>:

    Accept: text/html, application/json;q=0.9, */*;q=0.1

Each entry retains the existing C<< { type => $type, q => $quality } >> shape
and shared preference order. Higher quality values (q) indicate higher
preference. The default is q=1.0.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Pages> - Negotiated default responses

L<PAGI::Request::Negotiate> - Shared Accept matching

=cut
