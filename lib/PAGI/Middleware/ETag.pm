package PAGI::Middleware::ETag;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Digest::MD5 qw(md5_hex);
use PAGI::Middleware::BufferedResponse qw(buffer_whole_response);

=head1 NAME

PAGI::Middleware::ETag - ETag generation middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'ETag';
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::ETag generates ETag headers for responses based on
the response body content. Works best with buffered (non-streaming) responses.

=head1 CONFIGURATION

=over 4

=item * weak (default: 0)

If true, generate weak ETags (W/"...").

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{weak} = $config->{weak} // 0;
}

sub wrap {
    my ($self, $app) = @_;

    return buffer_whole_response($app,
        engage => sub {
            my ($status, $headers) = @_;
            # An application that set its own ETag owns it.
            return 0 if grep { lc($_->[0]) eq 'etag' } @$headers;
            return 1;
        },
        transform => sub {
            my ($status, $headers, $body) = @_;
            push @$headers, ['ETag', $self->_generate_etag($body)];
            return ($status, $headers, $body);
        },
    );
}

sub _generate_etag {
    my ($self, $body) = @_;

    my $hash = md5_hex($body);
    if ($self->{weak}) {
        return qq{W/"$hash"};
    }
    return qq{"$hash"};
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::ConditionalGet> - Use with ETag for 304 responses

=cut
