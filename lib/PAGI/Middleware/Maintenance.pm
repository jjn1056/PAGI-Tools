package PAGI::Middleware::Maintenance;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future;
use Future::AsyncAwait;
use PAGI::Response::Text ();
use PAGI::Utils ();
use PAGI::Utils::Middleware ();

=head1 NAME

PAGI::Middleware::Maintenance - Serve maintenance page when enabled

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'Maintenance',
            enabled => $ENV{MAINTENANCE_MODE},
            bypass_ips => ['10.0.0.0/8'],
            retry_after => 3600;
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::Maintenance answers every HTTP request with a 503 while
maintenance mode is enabled -- by default the plain text
C<Service Unavailable> -- except for bypassed client addresses and paths.
WebSocket and SSE connections pass through.

=head1 CONFIGURATION

An option not listed here dies at construction.

=over 4

=item * enabled (default: 0)

Enable maintenance mode. Can be a coderef for dynamic checking.

=item * bypass_ips (default: [])

Arrayref of IPs or CIDR ranges that bypass maintenance mode.

=item * bypass_paths (default: [])

Arrayref of paths that bypass maintenance mode (e.g., health checks).

=item * retry_after (optional)

Seconds until maintenance expected to end. Sets Retry-After header, on
whatever answers: it replaces any Retry-After a C<response> carries.

=item * response

The maintenance response instead of the plain-text default: an application --
a Request handler (a coderef called with one
L<PAGI::Request>, returning a Response or an application) or an object
with C<to_app>, which
includes every L<PAGI::Response>. Give it the 503 status yourself:

    enable 'Maintenance', enabled => 1, retry_after => 3600,
        response => response('HTML', $maintenance_page, status => 503);

    enable 'Maintenance', enabled => 1,
        response => PAGI::Pages->service_unavailable;   # negotiated

Any plain value dies, as do the C<body> and C<content_type> options that
C<response> replaces.

A native C<($scope, $receive, $send)> application is passed as
C<as_app_object($app)>. Objects -- every Response and L<PAGI::Pages> value --
mean the same in every slot, and are the portable form for anything also
given to middleware outside PAGI-Tools.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    for my $option (qw(body content_type)) {
        die "Maintenance '$option' is replaced by 'response': "
            . "response => response('HTML', \$page, status => 503)"
            if exists $config->{$option};
    }
    $self->{response} = PAGI::Utils::_application_option(
        'Maintenance', $config, 'response',
    ) // PAGI::Response::Text->new('Service Unavailable', status => 503)->to_app;
    $self->{enabled} = $config->{enabled} // 0;
    $self->{bypass_ips} = $config->{bypass_ips} // [];
    $self->{bypass_paths} = $config->{bypass_paths} // [];
    $self->{retry_after} = $config->{retry_after};
    PAGI::Utils::_reject_unknown_options('Maintenance', $config,
        qw(bypass_ips bypass_paths enabled response retry_after));
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        # Check if maintenance is enabled
        my $enabled = ref $self->{enabled} eq 'CODE'
            ? $self->{enabled}->()
            : $self->{enabled};

        unless ($enabled) {
            await $app->($scope, $receive, $send);
            return;
        }

        # Check bypass conditions
        if ($self->_should_bypass($scope)) {
            await $app->($scope, $receive, $send);
            return;
        }

        # Serve maintenance page
        await $self->_send_maintenance($scope, $receive, $send);
    };
}

sub _should_bypass {
    my ($self, $scope) = @_;

    # Check bypass paths
    my $path = $scope->{path} // '';
    for my $bypass_path (@{$self->{bypass_paths}}) {
        if (ref $bypass_path eq 'Regexp') {
            return 1 if $path =~ $bypass_path;
        } else {
            return 1 if $path eq $bypass_path;
        }
    }

    # Check bypass IPs
    my $client_ip = exists $scope->{client} ? ($scope->{client}[0] // '') : '';
    for my $bypass_ip (@{$self->{bypass_ips}}) {
        if ($bypass_ip =~ m{/}) {
            # CIDR notation
            return 1 if $self->_ip_in_cidr($client_ip, $bypass_ip);
        } else {
            # Exact match
            return 1 if $client_ip eq $bypass_ip;
        }
    }

    return 0;
}

sub _ip_in_cidr {
    my ($self, $ip, $cidr) = @_;

    my ($network, $bits) = split m{/}, $cidr;

    # Simple IPv4 check
    return 0 unless $ip =~ /^[\d.]+$/ && $network =~ /^[\d.]+$/;

    my $ip_num = $self->_ip_to_num($ip);
    my $net_num = $self->_ip_to_num($network);

    return 0 unless defined $ip_num && defined $net_num;

    my $mask = ~((1 << (32 - $bits)) - 1) & 0xFFFFFFFF;
    return ($ip_num & $mask) == ($net_num & $mask);
}

sub _ip_to_num {
    my ($self, $ip) = @_;

    my @octets = split /\./, $ip;
    return unless @octets == 4;
    return unless _all_valid_octets(@octets);
    return ($octets[0] << 24) + ($octets[1] << 16) + ($octets[2] << 8) + $octets[3];
}

sub _all_valid_octets {
    for (@_) {
        return 0 unless /^\d+$/ && $_ >= 0 && $_ <= 255;
    }
    return 1;
}

async sub _send_maintenance {
    my ($self, $scope, $receive, $send) = @_;
    my $retry_after = $self->{retry_after};
    await $self->{response}->($scope, $receive, !defined $retry_after ? $send
        : PAGI::Utils::Middleware::wrap_response_headers($send, sub {
            $_[0]->set('Retry-After', $retry_after);
        }));
}

1;

__END__

=head1 DYNAMIC ENABLING

The C<enabled> option can be a coderef for dynamic maintenance mode:

    enable 'Maintenance',
        enabled => sub {
            return -e '/tmp/maintenance.flag';
        };

This allows enabling/disabling maintenance mode without restarting
the server.

=head1 BYPASS EXAMPLES

    enable 'Maintenance',
        enabled => 1,
        bypass_ips => [
            '127.0.0.1',      # localhost
            '10.0.0.0/8',     # internal network
        ],
        bypass_paths => [
            '/health',        # health checks
            qr{^/api/status}, # status API
        ];

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::Healthcheck> - Health check endpoints

=cut
