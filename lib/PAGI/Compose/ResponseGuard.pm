package PAGI::Compose::ResponseGuard;

use strict;
use warnings;
use Carp qw(croak);
use Future;
use Future::AsyncAwait;
use PAGI::Exception::IncompleteResponse ();

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
        my $terminal = 0;
        my $body_before_start;
        my $observing_send = sub {
            my ($event) = @_;
            my $type = $event->{type} // '';
            if ($type eq 'http.response.start') {
                $started = 1;
            }
            elsif ($type eq 'http.response.body') {
                unless ($started) {
                    $body_before_start ||=
                        PAGI::Exception::IncompleteResponse->new(
                            stage   => 'body_before_start',
                            message => 'HTTP application sent a response body before response start',
                        );
                    die $body_before_start;
                }
                $terminal = 1 unless $event->{more};
            }
            return $send->($event);
        };

        my $returned = $app->($scope, $receive, $observing_send);
        await Future->wrap($returned);

        if ($body_before_start) {
            die $body_before_start;
        }
        unless ($started) {
            die PAGI::Exception::IncompleteResponse->new(
                stage   => 'before_start',
                message => 'HTTP application completed without starting a response',
            );
        }
        unless ($terminal) {
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

This private wrapper observes HTTP response lifecycle events without copying or
rewriting them. It rejects a response body sent before response start without
forwarding that invalid event. After normal application completion it throws a
typed incomplete-response exception unless response start and a terminal body
were observed. Inner application exceptions pass through unchanged. Non-HTTP
scopes are delegated with their original channels.

=cut
