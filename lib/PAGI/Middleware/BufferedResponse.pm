package PAGI::Middleware::BufferedResponse;

use strict;
use warnings;
use Exporter qw(import);
use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use PAGI::Middleware ();

our @EXPORT_OK = qw(buffer_whole_response);

sub buffer_whole_response {
    my ($app, %opts) = @_;
    croak 'buffer_whole_response requires a coderef app'
        unless ref($app) eq 'CODE';
    my $engage    = $opts{engage} || sub { 1 };
    my $transform = $opts{transform} or croak 'transform is required';

    return async sub {
        my ($scope, $receive, $send) = @_;
        if (($scope->{type} // '') ne 'http') {
            await $app->($scope, $receive, $send);
            return;
        }

        my ($status, $headers);
        my @body_parts;
        my $passing       = 0;
        my $terminal_seen = 0;

        # Flush the withheld head plus whatever we buffered, as non-terminal
        # chunks, then hand the rest of the response straight through.
        my $flush_as_stream = async sub {
            await $send->({ type    => 'http.response.start',
                            status  => $status,
                            headers => $headers // [] });
            for my $part (@body_parts) {
                await $send->({ type => 'http.response.body',
                                body => $part, more => 1 });
            }
            @body_parts = ();
            $passing = 1;
        };

        my $wrapped_send = async sub {
            my ($event) = @_;
            my $type = $event->{type} // '';

            if ($passing) { await $send->($event); return }

            if ($type eq 'http.response.start') {
                $status = $event->{status};
                # Our own copy: the arrayref belongs to the application, which
                # may build it once and reuse it across requests.
                $headers = [ @{ $event->{headers} // [] } ];
                unless ($engage->($status, $headers)) {
                    $passing = 1;
                    await $send->($event);
                }
                return;
            }

            if ($type eq 'http.response.body') {
                # Never invent a start the application did not send.
                return unless defined $status;

                # An opaque (file/fh) body has no string to transform. Flush
                # what we withheld and hand over.
                if (PAGI::Middleware::body_event_is_opaque($event)) {
                    await $flush_as_stream->();
                    await $send->($event);
                    return;
                }

                push @body_parts, $event->{body} // '';

                # `more` defaults to 0, so an omitted `more` is terminal.
                if ($event->{more}) {
                    await $flush_as_stream->();
                    return;
                }
                $terminal_seen = 1;
                return;
            }

            await $send->($event);
        };

        await $app->($scope, $receive, $wrapped_send);

        return if $passing;
        return unless defined $status;   # nothing withheld, nothing to emit

        # No terminal event arrived, so the application never claimed this
        # response was complete. Emit the head it did produce -- swallowing it
        # would tell every outer observer that no response was ever started --
        # and stop. transform() is deliberately not called, which is what
        # makes completeness-dependent metadata over a partial buffer
        # unrepresentable rather than merely discouraged. See PAGI::Spec::Www,
        # "Application Left a Response Incomplete".
        unless ($terminal_seen) {
            await $send->({ type    => 'http.response.start',
                            status  => $status,
                            headers => $headers // [] });
            for my $part (@body_parts) {
                await $send->({ type => 'http.response.body',
                                body => $part, more => 1 });
            }
            return;
        }

        my ($out_status, $out_headers, $out_body) =
            $transform->($status, $headers // [], join('', @body_parts));

        await $send->({ type    => 'http.response.start',
                        status  => $out_status,
                        headers => $out_headers // [] });
        await $send->({ type => 'http.response.body',
                        body => $out_body // '', more => 0 });
        return;
    };
}

1;

__END__

=head1 NAME

PAGI::Middleware::BufferedResponse - safe buffer-and-re-emit for middleware

=head1 SYNOPSIS

    use PAGI::Middleware::BufferedResponse qw(buffer_whole_response);

    sub wrap {
        my ($self, $app) = @_;
        return buffer_whole_response($app,
            engage    => sub { my ($status, $headers) = @_; $status == 200 },
            transform => sub {
                my ($status, $headers, $body) = @_;
                push @$headers, ['ETag', '"' . md5_hex($body) . '"'];
                return ($status, $headers, $body);
            },
        );
    }

=head1 DESCRIPTION

Middleware that computes a response header from the whole body -- an C<ETag>,
a C<Content-Length>, a digest -- must buffer the body before it can emit
anything. That pattern has one dangerous case: the event stream can end
without its terminal event, because the client disconnected or because the
application stopped early. A middleware that synthesizes its header anyway
asserts that the bytes it happened to observe are the complete
representation, which
L<PAGI::Spec::Www/"Application Left a Response Incomplete"> forbids to every
producer, not only to servers.

This helper owns that case. Your C<transform> callback runs B<only> when a
terminal body event was actually received, so a validator over a partial body
is not something you can accidentally write. When the stream ends early, the
helper emits the C<http.response.start> the application produced -- unmodified,
with no computed metadata -- followed by any buffered chunks tagged
C<< more => 1 >>, and no terminal event. The response stays observably
incomplete, and outer observers still see that a response was started.

=head2 buffer_whole_response

    my $wrapped = buffer_whole_response($app, engage => \&engage, transform => \&transform);

=over

=item * C<engage> (optional, defaults to always true)

Called once with C<< ($status, $headers) >> when C<http.response.start>
arrives. Return false to pass this response through untouched. C<$headers> is
the helper's own copy, so C<engage> may modify it freely.

=item * C<transform> (required)

Called with C<< ($status, $headers, $body) >> and must return the same triple.
Runs only for a response that reached its terminal body event. C<$headers> is
a copy; the application's own arrayref is never modified, so an application
that builds its headers once and reuses them across requests is safe.

=back

Responses that turn out to be streaming (a body event with C<< more => 1 >>)
or opaque (a C<file> or C<fh> body) are flushed and passed through;
C<transform> does not run for them, because there is no whole body to give it.

=head1 SEE ALSO

L<PAGI::Middleware> - Base class for middleware

L<PAGI::Spec::Www> - "Application Left a Response Incomplete"

=cut
