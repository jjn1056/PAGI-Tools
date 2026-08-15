package PAGI::App::Proxy;

use strict;
use warnings;
use Future;
use Future::AsyncAwait;
use IO::Socket::INET;
use PAGI::Pages;

=head1 NAME

PAGI::App::Proxy - HTTP reverse proxy (DEMO ONLY - NOT FOR PRODUCTION)

=head1 SYNOPSIS

    use PAGI::App::Proxy;

    my $app = PAGI::App::Proxy->new(
        backend => 'http://localhost:8080',
    )->to_app;

=cut

sub new {
    my ($class, %args) = @_;

    my $backend = $args{backend} // 'http://localhost:8080';
    my ($host, $port) = $backend =~ m{://([^:/]+)(?::(\d+))?};
    $port //= 80;

    return bless {
        host    => $host,
        port    => $port,
        timeout => $args{timeout} // 30,
        headers => $args{headers} // {},
    }, $class;
}

sub to_app {
    my ($self) = @_;

    my $host = $self->{host};
    my $port = $self->{port};
    my $timeout = $self->{timeout};
    my $extra_headers = $self->{headers};

    return async sub  {
        my ($scope, $receive, $send) = @_;
        die "Unsupported scope type: $scope->{type}" if $scope->{type} ne 'http';

        # Build request
        my $method = $scope->{method};
        my $path = $scope->{path};
        $path .= "?$scope->{query_string}" if $scope->{query_string};

        # Collect body
        my $body = '';
        while (1) {
            my $event = await $receive->();
            last if $event->{type} ne 'http.request';
            $body .= $event->{body} // '';
            last unless $event->{more};
        }

        # Build headers
        my @headers;
        for my $h (@{$scope->{headers} // []}) {
            next if lc($h->[0]) eq 'host';  # Replace host
            push @headers, "$h->[0]: $h->[1]";
        }
        push @headers, "Host: $host:$port";

        # Add X-Forwarded headers
        push @headers, "X-Forwarded-For: $scope->{client}[0]" if $scope->{client};
        push @headers, "X-Forwarded-Proto: $scope->{scheme}" if $scope->{scheme};

        # Add extra headers
        for my $name (keys %$extra_headers) {
            push @headers, "$name: $extra_headers->{$name}";
        }

        if (length $body) {
            push @headers, "Content-Length: " . length($body);
        }

        my $request = "$method $path HTTP/1.1\r\n" . join("\r\n", @headers) . "\r\n\r\n" . $body;

        # Connect to backend
        my $sock = $self->_connect_backend($host, $port, $timeout);

        unless ($sock) {
            await $self->_send_bad_gateway($scope, $send);
            return;
        }

        print $sock $request;

        # Read response
        my $response = '';
        while (my $chunk = <$sock>) {
            $response .= $chunk;
        }
        close $sock;

        # Parse response (simple parsing)
        my ($status_line, $rest) = split /\r?\n/, $response, 2;
        my ($proto, $status, $reason) = split / /, $status_line, 3;

        my ($header_block, $resp_body) = split /\r?\n\r?\n/, $rest, 2;
        my @resp_headers;
        for my $line (split /\r?\n/, $header_block // '') {
            my ($name, $value) = split /:\s*/, $line, 2;
            next unless $name;
            push @resp_headers, [lc($name), $value];
        }

        await $send->({
            type => 'http.response.start',
            status => $status,
            headers => \@resp_headers,
        });
        await $send->({ type => 'http.response.body', body => $resp_body // '', more => 0 });
    };
}

sub _connect_backend {
    my ($self, $host, $port, $timeout) = @_;

    return IO::Socket::INET->new(
        PeerHost => $host,
        PeerPort => $port,
        Timeout  => $timeout,
    );
}

async sub _send_bad_gateway {
    my ($self, $scope, $send) = @_;

    my $response = PAGI::Pages->bad_gateway($scope);
    await Future->wrap($response->respond($send));
}

1;

__END__

=head1 DESCRIPTION

Simple HTTP reverse proxy for development and demonstration purposes.

If the backend connection cannot be opened, the application sends a generic
502 Bad Gateway response through L<PAGI::Pages>. The response negotiates HTML,
problem JSON, or plain text from the original HTTP request. Responses received
from a backend remain literal proxy output; there is no Pages configuration
surface on this demonstration application.

B<WARNING: NOT FOR PRODUCTION USE>

This module has known security and performance issues:

=over 4

=item * B<SSRF Vulnerability> - No validation of backend URLs. Attackers could
potentially target internal services (localhost, private IPs).

=item * B<Blocking I/O> - Uses synchronous C<IO::Socket::INET>, which blocks
the entire event loop during backend requests. This defeats the purpose of
async and severely limits throughput.

=item * B<No Connection Pooling> - Creates a new connection for every request.

=item * B<Limited Error Handling> - A negotiated generic 502 response is the
only local connection-failure handling.

=back

For production reverse proxy needs, consider:

=over 4

=item * L<nginx|https://nginx.org/> or L<HAProxy|http://www.haproxy.org/> as a
dedicated reverse proxy

=item * A proper async HTTP client like L<Net::Async::HTTP> with PAGI

=item * L<Plack::App::Proxy> if migrating from PSGI

=back

This module is included as a simple demonstration of the PAGI interface for
proxy-style applications.

=head1 OPTIONS

=over 4

=item * C<backend> - Backend URL (default: 'http://localhost:8080')

=item * C<timeout> - Connection timeout in seconds (default: 30)

=item * C<headers> - Hashref of additional headers to add to requests

=back

=cut
