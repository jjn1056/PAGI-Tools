package PAGI::Compose::ResponseGuard;

use strict;
use warnings;
use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use PAGI::Exception::IncompleteResponse ();
use PAGI::Utils qw(request_ended_abnormally);

sub wrap {
    my ($class, $app) = @_;
    croak 'response guard app must be a coderef'
        unless ref($app) eq 'CODE';

    return async sub {
        my ($scope, $receive, $send) = @_;

        if (($scope->{type} // 'http') ne 'http') {
            my $returned = $app->($scope, $receive, $send);
            await Future->wrap($returned);
            return;
        }

        my $started = 0;
        my $trailers_declared = 0;
        my $body_terminal = 0;
        my $terminal = 0;
        my $body_before_start;
        my $observing_send = sub {
            my ($event) = @_;
            my $type = $event->{type} // '';
            if ($type eq 'http.response.start') {
                $started = 1;
                $trailers_declared = $event->{trailers} ? 1 : 0;
            }
            elsif ($type eq 'http.response.body') {
                unless ($started) {
                    $body_before_start ||=
                        PAGI::Exception::IncompleteResponse->new(
                            stage   => 'body_before_start',
                            message => 'HTTP application sent a response body before response start',
                        );
                    # Reject without forwarding, as a failed Future rather
                    # than a synchronous die -- contract parity with how the
                    # real server rejects an invalid send. The typed
                    # exception is still raised below once the application
                    # completes, in case it doesn't await/inspect this.
                    return Future->fail($body_before_start);
                }
                unless ($event->{more}) {
                    $body_terminal = 1;
                    $terminal = 1 unless $trailers_declared;
                }
            }
            elsif ($type eq 'http.response.trailers') {
                $terminal = 1;
            }
            return $send->($event);
        };

        my $returned = $app->($scope, $receive, $observing_send);
        await Future->wrap($returned);

        if ($body_before_start) {
            die $body_before_start;
        }

        # A request whose client already disconnected did not end because the
        # application misbehaved: it ended abnormally with its own disconnect
        # reason, and PAGI::Spec::Www exempts it from both incomplete-response
        # rules ("Application Left a Response Incomplete" and "Application
        # Produced No Response"). A streaming response deliberately omits its
        # terminal event in that case. A body sent before response start is a
        # protocol fault rather than an incompleteness, so it is rejected
        # above regardless.
        return if request_ended_abnormally($scope);

        unless ($started) {
            die PAGI::Exception::IncompleteResponse->new(
                stage   => 'before_start',
                message => 'HTTP application completed without starting a response',
            );
        }
        unless ($terminal) {
            if ($trailers_declared && $body_terminal) {
                die PAGI::Exception::IncompleteResponse->new(
                    stage   => 'awaiting_trailers',
                    message => 'HTTP application completed after declaring trailers without sending them',
                );
            }
            die PAGI::Exception::IncompleteResponse->new(
                stage   => 'after_start',
                message => 'HTTP application completed after response start without a terminal body',
            );
        }
        return;
    };
}

1;

__END__

=head1 NAME

PAGI::Compose::ResponseGuard - Internal Compose HTTP completion guard

=head1 DESCRIPTION

This private wrapper observes only the HTTP events actually sent by the inner
native application. It neither receives nor inspects Response objects or their
mutation state, and it does not buffer or rewrite a downstream response. It
rejects a response body sent before response start without forwarding that
invalid event -- the rejection is a failed C<Future> (the typed exception as
its failure), not a synchronous C<die>. After normal application completion it
throws a typed incomplete-response exception unless response start and a
terminal body were observed; if C<http.response.start> declared
C<trailers =E<gt> 1>, a terminal body is not enough on its own --
C<http.response.trailers> must also have been sent, or completion fails with
the C<awaiting_trailers> stage. Inner application exceptions pass through
unchanged. Non-HTTP scopes are delegated with their original channels.

=cut
