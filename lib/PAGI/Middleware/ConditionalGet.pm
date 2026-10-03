package PAGI::Middleware::ConditionalGet;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use PAGI::Headers ();
use PAGI::Utils::Headers qw(etag_matches);
use PAGI::Utils ();

=head1 NAME

PAGI::Middleware::ConditionalGet - Conditional GET/HEAD request handling

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'ETag';           # Generate ETags
        enable 'ConditionalGet'; # Handle If-None-Match
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::ConditionalGet returns 304 Not Modified for GET/HEAD
requests when the client's conditional headers match. Supports:

It takes no options; any option dies at construction.

- If-None-Match: weakly compare every field value against a valid ETag;
  wildcard matches an eligible representation even without an ETag
- If-Modified-Since: compare against Last-Modified only when
  If-None-Match is absent

Malformed If-None-Match fields are ignored as a whole. Only eligible 2xx
representation responses on exact HTTP GET/HEAD requests can become 304;
204 and 205, errors, redirects, and other protocols pass through.

=cut

sub _init {
    my ($self, $config) = @_;
    PAGI::Utils::_reject_unknown_options('ConditionalGet', $config);
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Only handle GET and HEAD requests
        my $method = $scope->{method};
        unless (defined($method) && !ref($method)
                && ($method eq 'GET' || $method eq 'HEAD')) {
            await $app->($scope, $receive, $send);
            return;
        }

        # Get conditional request headers
        my $request_headers = PAGI::Headers->new($scope->{headers} // []);
        my $has_if_none_match = $request_headers->has('If-None-Match');
        my $if_modified_since = $request_headers->get('If-Modified-Since');

        # No conditional headers? Pass through
        unless ($has_if_none_match || defined $if_modified_since) {
            await $app->($scope, $receive, $send);
            return;
        }

        # Capture response headers
        my $response_status;
        my $response_headers;
        my $sent_304 = 0;

        my $wrapped_send = async sub  {
        my ($event) = @_;
            # Once we've sent our own 304, the wrapped app's remaining
            # events (any further body chunks, or declared trailers) are
            # for a representation the client never receives -- swallow
            # all of them instead of forwarding a stray post-terminal send.
            return if $sent_304;

            if ($event->{type} eq 'http.response.start') {
                $response_status = $event->{status};
                $response_headers = $event->{headers};

                # Only successful responses with a selected representation.
                if ($response_status >= 200 && $response_status < 300
                        && $response_status != 204 && $response_status != 205) {
                    my $headers = PAGI::Headers->new($response_headers // []);
                    my $etag = $headers->get_single('ETag');
                    $etag = undef if defined($etag) && !defined($headers->etag);
                    my $last_modified = $headers->get('Last-Modified');

                    my $not_modified = 0;

                    # Check If-None-Match
                    if ($has_if_none_match) {
                        my $condition = $request_headers->if_none_match;
                        if (defined $condition) {
                            $not_modified = $condition->{any} ? 1
                                : defined($etag)
                                    ? etag_matches($condition, $etag, weak => 1)
                                    : 0;
                        }
                    }
                    # Check If-Modified-Since (only if no If-None-Match)
                    elsif (defined $if_modified_since && defined $last_modified) {
                        $not_modified = $self->_not_modified_since($if_modified_since, $last_modified);
                    }

                    if ($not_modified) {
                        # Send 304 response
                        my @headers_304 = $self->_filter_headers_for_304($response_headers);
                        await $send->({
                            type    => 'http.response.start',
                            status  => 304,
                            headers => \@headers_304,
                        });
                        await $send->({
                            type => 'http.response.body',
                            body => '',
                            more => 0,
                        });
                        $sent_304 = 1;
                        return;
                    }
                }

                await $send->($event);
            }
            elsif ($event->{type} eq 'http.response.body') {
                await $send->($event);
            }
            else {
                await $send->($event);
            }
        };

        await $app->($scope, $receive, $wrapped_send);
    };
}

sub _not_modified_since {
    my ($self, $if_modified_since, $last_modified) = @_;

    # Parse HTTP dates and compare
    # This is a simplified comparison - both should be HTTP-date format

    my $parse_date = sub  {
        my ($date_str) = @_;
        # Try to parse common HTTP date formats
        # RFC 1123: Sun, 06 Nov 1994 08:49:37 GMT
        # RFC 850:  Sunday, 06-Nov-94 08:49:37 GMT
        # asctime:  Sun Nov  6 08:49:37 1994

        require HTTP::Date;
        return HTTP::Date::str2time($date_str);
    };

    my $client_time = eval { $parse_date->($if_modified_since) };
    my $server_time = eval { $parse_date->($last_modified) };

    return 0 unless defined $client_time && defined $server_time;
    return $server_time <= $client_time;
}

sub _filter_headers_for_304 {
    my ($self, $headers) = @_;

    # RFC 7232: 304 response MUST include certain headers
    my @allowed = qw(
        cache-control content-location date etag expires
        last-modified vary
    );
    my %allowed = map { $_ => 1 } @allowed;

    my @filtered;
    for my $h (@{$headers // []}) {
        push @filtered, $h if $allowed{lc($h->[0])};
    }
    return @filtered;
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::ETag> - Generate ETag headers

=cut
