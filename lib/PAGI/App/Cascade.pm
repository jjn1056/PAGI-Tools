package PAGI::App::Cascade;

use strict;
use warnings;
use Future;
use Future::AsyncAwait;
use PAGI::Exception::IncompleteResponse ();
use PAGI::Utils qw(request_ended_abnormally);

=head1 NAME

PAGI::App::Cascade - Try apps in sequence until success

=head1 SYNOPSIS

    use PAGI::App::Cascade;
    use Future::AsyncAwait;
    use PAGI::Pages ();
    use PAGI::Utils qw(invoke_app);

    my $not_found = async sub {
        my ($scope, $receive, $send) = @_;
        await invoke_app(
            PAGI::Pages->not_found(as => 'text'),
            $scope, $receive, $send,
        );
    };

    my $app = PAGI::App::Cascade->new(
        apps => [$static_app, $not_found],
        catch => [404, 405],
    )->to_app;

=cut

sub new {
    my ($class, %args) = @_;

    return bless {
        apps  => [map { PAGI::Utils::to_app($_) } @{$args{apps} // []}],
        catch => { map { $_ => 1 } @{$args{catch} // [404, 405]} },
    }, $class;
}

sub add {
    my ($self, $app) = @_;

    push @{$self->{apps}}, PAGI::Utils::to_app($app);
    return $self;
}

sub to_app {
    my ($self) = @_;

    my @apps = @{$self->{apps}};
    my %catch = %{$self->{catch}};

    return async sub  {
        my ($scope, $receive, $send) = @_;

        if (($scope->{type} // 'http') ne 'http') {
            return unless @apps;

            if (@apps == 1) {
                my $returned = $apps[0]->($scope, $receive, $send);
                await Future->wrap($returned);
                return;
            }

            my @captured_events;
            my $capture_send = sub {
                push @captured_events, $_[0];
                return Future->done;
            };
            my $returned = $apps[0]->($scope, $receive, $capture_send);
            await Future->wrap($returned);
            for my $event (@captured_events) {
                await Future->wrap($send->($event));
            }
            return;
        }

        unless (@apps) {
            die PAGI::Exception::IncompleteResponse->new(
                stage   => 'before_start',
                message => 'HTTP Cascade completed without starting a response',
            );
        }

        for my $i (0 .. $#apps) {
            my $app = $apps[$i];
            my $is_last = ($i == $#apps);
            my $start_seen = 0;
            my $terminal_seen = 0;
            my $caught = 0;
            my $forwarded_start = 0;
            my $body_before_start;

            my $observing_send = sub {
                my ($event) = @_;
                my $type = $event->{type} // '';
                if ($type eq 'http.response.start') {
                    unless ($start_seen) {
                        $start_seen = 1;
                        $caught = 1
                            if !$is_last
                                && defined($event->{status})
                                && !ref($event->{status})
                                && exists $catch{$event->{status}};
                        $forwarded_start = 1 unless $caught;
                    }
                    return Future->done if $caught;
                }
                elsif ($type eq 'http.response.body') {
                    unless ($start_seen) {
                        $body_before_start ||=
                            PAGI::Exception::IncompleteResponse->new(
                                stage   => 'body_before_start',
                                message => 'HTTP application sent a response body before response start',
                            );
                        die $body_before_start;
                    }
                    $terminal_seen = 1 unless $event->{more};
                    return Future->done if $caught;
                }
                elsif ($caught) {
                    return Future->done;
                }
                return $send->($event);
            };

            my $completed = eval {
                my $returned = $app->(
                    $scope,
                    $receive,
                    $observing_send,
                );
                await Future->wrap($returned);
                1;
            };
            my $error = $@ unless $completed;
            die $error unless $completed;
            die $body_before_start if $body_before_start;

            if ($start_seen) {
                unless ($terminal_seen || request_ended_abnormally($scope)) {
                    die PAGI::Exception::IncompleteResponse->new(
                        stage   => 'after_start',
                        message => 'HTTP application completed after response start without a terminal body',
                    );
                }
                if ($caught) {
                    next;
                }
                return if $forwarded_start;
            }

            die PAGI::Exception::IncompleteResponse->new(
                stage   => 'before_start',
                message => 'HTTP application completed without starting a response',
            );
        }

        die PAGI::Exception::IncompleteResponse->new(
            stage   => 'before_start',
            message => 'HTTP Cascade completed without starting a response',
        );
    };
}

1;

__END__

=head1 DESCRIPTION

Cascade tries applications in order. For HTTP, C<catch> lists ordinary response
statuses that advance to the next child. On a non-final child, Cascade inspects
C<http.response.start>; a listed status suppresses that complete response and
advances. The caught child is awaited through its terminal body before the next
child begins. A final response always passes through unchanged, even when its
status is listed in C<catch>. Exceptions and applications that complete without
starting a response never advance; silence throws
L<PAGI::Exception::IncompleteResponse>.

Response starts and body chunks from a non-caught child are forwarded as they
arrive rather than buffered until completion. Caught events are suppressed.
Body-before-start and incomplete started responses are typed lifecycle errors,
and failures after a forwarded start propagate so the server can abort the
stream.

WebSocket, SSE, lifespan, and extension scopes retain the historical native
Cascade behavior and do not use HTTP catch or lifecycle logic. Routers now emit
their own HTTP 404 and 405 responses, so they participate in the same C<catch>
contract as any other HTTP application.

Cascade is status-driven application coordination, not Router decline or Mount
composition. A selected Router 404/405 may advance only because its status is
listed in C<catch>; parent route scanning never resumes.

    my $routing = PAGI::App::Cascade->new(
        apps => [
            $static_app,          # explicit caught 404 may advance
            $api_router->to_app,  # Router 404/405 may advance
            $site_router->to_app, # final Router response passes through
        ],
    );

    my $app = compose(app => $routing)->to_app;

=head1 OPTIONS

=over 4

=item * C<apps> - Arrayref of apps to try in order.
Entries in C<apps> (and arguments to C<add>) accept anything
L<PAGI::Utils/to_app> accepts: a coderef or an instantiated component object
with a C<to_app> method. Package-name strings are rejected.

=item * C<catch> - Arrayref of explicit HTTP response status codes to catch on
non-final children (default: [404, 405]).

=back

=head1 METHODS

=head2 add($app)

Add an app to the cascade.

=head1 SEE ALSO

L<PAGI::Compose>, L<PAGI::Routing>, L<PAGI::Routing::Mount>,
L<PAGI::Exception::IncompleteResponse>

=cut
