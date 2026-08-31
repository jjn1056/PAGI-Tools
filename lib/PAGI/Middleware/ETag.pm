package PAGI::Middleware::ETag;

use strict;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use Digest::MD5 qw(md5_hex);
use PAGI::Utils qw(request_ended_abnormally);

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

    return async sub  {
        my ($scope, $receive, $send) = @_;
        if ($scope->{type} ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        my @body_parts;
        my $original_headers;
        my $status;
        my $is_streaming = 0;

        my $wrapped_send = async sub  {
        my ($event) = @_;
            if ($event->{type} eq 'http.response.start') {
                $status = $event->{status};
                $original_headers = $event->{headers};
                # Check if already has ETag
                for my $h (@{$original_headers // []}) {
                    if (lc($h->[0]) eq 'etag') {
                        # Already has ETag, pass through
                        await $send->($event);
                        $is_streaming = 1;  # Flag to pass through body
                        return;
                    }
                }
            }
            elsif ($event->{type} eq 'http.response.body') {
                if ($is_streaming) {
                    await $send->($event);
                    return;
                }

                # Opaque (file/fh) bodies have no body string to hash --
                # flush anything buffered so far as streaming chunks and
                # forward the opaque event verbatim, without an ETag.
                if (PAGI::Middleware::body_event_is_opaque($event)) {
                    # No start was ever observed -- don't invent one to carry it.
                    return unless defined $status;

                    $is_streaming = 1;
                    await $send->({
                        type    => 'http.response.start',
                        status  => $status,
                        headers => $original_headers // [],
                    });
                    for my $part (@body_parts) {
                        await $send->({
                            type => 'http.response.body',
                            body => $part,
                            more => 1,
                        });
                    }
                    @body_parts = ();
                    await $send->($event);
                    return;
                }

                push @body_parts, $event->{body} // '';

                # If streaming, can't generate ETag
                if ($event->{more}) {
                    # No start was ever observed (a malformed inner app sent
                    # a body chunk first) -- don't invent one to carry it.
                    return unless defined $status;

                    $is_streaming = 1;
                    await $send->({
                        type    => 'http.response.start',
                        status  => $status,
                        headers => $original_headers,
                    });
                    for my $part (@body_parts) {
                        await $send->({
                            type => 'http.response.body',
                            body => $part,
                            more => 1,
                        });
                    }
                    @body_parts = ();
                }
            }
            else {
                await $send->($event);
            }
        };

        await $app->($scope, $receive, $wrapped_send);

        return if $is_streaming;

        # The inner app never sent a start event at all -- don't invent a
        # response it never gave us; let the server's no-response backstop
        # fire with its accurate diagnostic.
        return unless defined $status;

        # A client that vanished mid-response leaves a partial body. Computing
        # a validator over it and emitting more => 0 would assert that those
        # bytes are the whole representation -- forbidden for any producer by
        # PAGI::Spec::Www, "Application Left a Response Incomplete".
        return if request_ended_abnormally($scope);

        # Generate ETag from body
        my $body = join('', @body_parts);
        my $etag = $self->_generate_etag($body);

        # Add ETag to headers
        my @new_headers = @{$original_headers // []};
        push @new_headers, ['ETag', $etag];

        await $send->({
            type    => 'http.response.start',
            status  => $status,
            headers => \@new_headers,
        });
        await $send->({
            type => 'http.response.body',
            body => $body,
            more => 0,
        });
    };
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
