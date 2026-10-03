package PAGI::Middleware::Runtime;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use Time::HiRes qw(time);
use PAGI::Utils ();
use PAGI::Utils::Middleware ();

=head1 NAME

PAGI::Middleware::Runtime - Request timing middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'Runtime',
            header    => 'X-Runtime',
            precision => 6;
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::Runtime measures the time taken to process a request
and adds it as a response header. This is useful for performance
monitoring and debugging.

The header is added to a copy of the response's headers; the application's own
list is never changed. If the response already has the header, it is left as
it is, no second one is added, and a warning says so.

=head1 CONFIGURATION

An option not listed here dies at construction.

=over 4

=item * header (default: 'X-Runtime')

The header name to use for the runtime value.

=item * precision (default: 6)

Number of decimal places for the duration in seconds.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{header}    = $config->{header} // 'X-Runtime';
    $self->{precision} = $config->{precision} // 6;
    PAGI::Utils::_reject_unknown_options('Runtime', $config,
        qw(header precision));
}

sub wrap {
    my ($self, $app) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        # Only handle HTTP requests
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        my $start_time = time();

        # The header goes on a copy: the response's own header list belongs
        # to whoever built it, who may send it again. A value the response
        # already carries is the application's, and stays.
        my $wrapped_send = PAGI::Utils::Middleware::wrap_response_headers($send, sub {
            my ($headers) = @_;
            if ($headers->has($self->{header})) {
                warn "PAGI::Middleware::Runtime: the response already has an "
                    . "$self->{header} header; leaving it and adding none\n";
                return;
            }
            $headers->set($self->{header},
                sprintf('%.*f', $self->{precision}, time() - $start_time));
        });

        await $app->($scope, $receive, $wrapped_send);
    };
}

1;

__END__

=head1 EXAMPLE OUTPUT

The X-Runtime header contains the request processing time in seconds:

    X-Runtime: 0.001234

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::AccessLog> - Access logging middleware

=cut
