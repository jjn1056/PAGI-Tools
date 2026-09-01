package PAGI::Middleware::GZip;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use PAGI::Middleware::BufferedResponse qw(stream_transform_response);
use Compress::Raw::Zlib qw(WANT_GZIP Z_OK Z_SYNC_FLUSH Z_FINISH);

=head1 NAME

PAGI::Middleware::GZip - Response compression middleware

=head1 SYNOPSIS

    use PAGI::Middleware::Builder;

    my $app = builder {
        enable 'GZip',
            min_size => 1024,
            mime_types => ['text/*', 'application/json'];
        $my_app;
    };

=head1 DESCRIPTION

PAGI::Middleware::GZip compresses response bodies using gzip when the
client supports it (Accept-Encoding: gzip).

=head1 CONFIGURATION

=over 4

=item * min_size (default: 1024)

Minimum response size to compress (bytes).

=item * mime_types (default: text/*, application/json, application/javascript)

MIME types to compress.

=back

=cut

sub _init {
    my ($self, $config) = @_;

    $self->{min_size} = $config->{min_size} // 1024;
    $self->{mime_types} = $config->{mime_types} // [
        'text/html', 'text/plain', 'text/css', 'text/javascript',
        'application/json', 'application/javascript', 'application/xml',
    ];
}

sub wrap {
    my ($self, $app) = @_;

    my $inner = stream_transform_response($app, begin => sub {
        my ($status, $headers, $first_body) = @_;

        return undef if grep { lc($_->[0]) eq 'content-encoding' } @$headers;
        # A 206 body is a range whose bounds were computed against the
        # identity representation; encoding it would describe the transfer of
        # bytes the Content-Range no longer locates.
        return undef if ($status // 0) == 206;
        return undef if grep { lc($_->[0]) eq 'content-range' } @$headers;
        my ($ct) = map { $_->[1] }
                   grep { lc($_->[0]) eq 'content-type' } @$headers;
        return undef unless $self->_type_is_compressible($ct // '');

        # min_size can only be honoured when the size is knowable. A first
        # body event that is already terminal IS the whole representation, so
        # apply the threshold. A streaming response has no knowable size --
        # compressing it is the case this middleware previously gave up on
        # entirely, so the threshold does not apply there.
        if (!$first_body->{more}) {
            return undef
                if length($first_body->{body} // '') < $self->{min_size};
        }

        my ($deflate, $err) = Compress::Raw::Zlib::Deflate->new(
            WindowBits   => WANT_GZIP,
            AppendOutput => 1,
        );
        return undef unless $deflate && $err == Z_OK;

        # The compressed length is not known before the body is compressed,
        # so the response is chunked and carries no Content-Length.
        @$headers = grep { lc($_->[0]) ne 'content-length' } @$headers;
        push @$headers, ['Content-Encoding', 'gzip'], ['Vary', 'Accept-Encoding'];

        return {
            chunk => sub {
                my ($bytes) = @_;
                my $out = '';
                $deflate->deflate($bytes, $out);
                # Z_SYNC_FLUSH makes each chunk independently deliverable,
                # which is the whole point of streaming compression.
                $deflate->flush($out, Z_SYNC_FLUSH);
                return $out;
            },
            finish => sub {
                my $out = '';
                $deflate->flush($out, Z_FINISH);
                return $out;
            },
        };
    });

    # Accept-Encoding is a request header, so gate on the scope out here;
    # begin() only ever sees the response.
    return async sub {
        my ($scope, $receive, $send) = @_;
        if (($scope->{type} // '') ne 'http'
            || !$self->_client_accepts_gzip($scope)) {
            await $app->($scope, $receive, $send);
            return;
        }
        await $inner->($scope, $receive, $send);
        return;
    };
}

sub _client_accepts_gzip {
    my ($self, $scope) = @_;
    my $accept_encoding = $self->_get_header($scope, 'accept-encoding') // '';
    return $accept_encoding =~ /\bgzip\b/i ? 1 : 0;
}

sub _type_is_compressible {
    my ($self, $content_type) = @_;

    $content_type =~ s/;.*//;  # Remove charset etc.
    $content_type = lc($content_type);

    for my $type (@{$self->{mime_types}}) {
        return 1 if $content_type eq lc($type);
        if ($type =~ /\*$/) {
            my $prefix = substr($type, 0, -1);
            return 1 if index($content_type, lc($prefix)) == 0;
        }
    }
    return 0;
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

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

=cut
