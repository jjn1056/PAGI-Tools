package PAGI::Middleware::ETag;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Digest::MD5 qw(md5_hex);
use PAGI::Middleware::BufferedResponse qw(buffer_whole_response);
use PAGI::Utils::Headers qw(format_etag);
use PAGI::Utils ();

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

An option not listed here dies at construction.

=over 4

=item * weak (default: 0)

If true, generate weak ETags (W/"...").

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{weak} = $config->{weak} // 0;
    PAGI::Utils::_reject_unknown_options('ETag', $config,
        qw(weak));
}

sub wrap {
    my ($self, $app) = @_;

    return buffer_whole_response($app,
        engage => sub {
            my ($status, $headers) = @_;
            # An application that set its own ETag owns it.
            return 0 if grep { lc($_->[0]) eq 'etag' } @$headers;
            # A 206 body is a range, not the representation. Hashing it would
            # label the resource with a validator identifying only the
            # fragment, so a cache could later serve the fragment as the
            # whole. See PAGI::Spec::Www, "An intermediary must not
            # invalidate what the head promised".
            return 0 if ($status // 0) == 206;
            return 0 if grep { lc($_->[0]) eq 'content-range' } @$headers;
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

    return format_etag(md5_hex($body), weak => $self->{weak} ? 1 : 0);
}

1;

__END__

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Middleware::ConditionalGet> - Use with ETag for 304 responses

=cut
