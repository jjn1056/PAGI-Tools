package PAGI::App::Cascade;

use strict;
use warnings;
use Future;
use Future::AsyncAwait;
use PAGI::Exception::IncompleteResponse ();
use PAGI::Utils ();

my $DISCARD_TRACE_WINDOW;
BEGIN {
    require PAGI::Routing::Trace;
    PAGI::Routing::Trace->_claim_cascade_discard_factory(sub {
        ($DISCARD_TRACE_WINDOW) = @_;
    });
}

=head1 NAME

PAGI::App::Cascade - Try apps in sequence until success

=head1 SYNOPSIS

    use PAGI::App::Cascade;

    my $app = PAGI::App::Cascade->new(
        apps => [$static_app, PAGI::App::NotFound->new(body => 'nope')],
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

        my ($http_scope, $trace)
            = PAGI::Routing::Trace->_ensure_http_scope($scope);
        unless (@apps) {
            die PAGI::Exception::IncompleteResponse->new(
                stage   => 'before_start',
                message => 'HTTP Cascade completed without starting a response',
            );
        }

        for my $i (0 .. $#apps) {
            my $app = $apps[$i];
            my $is_last = ($i == $#apps);
            my $checkpoint = $trace->checkpoint;
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
                    $http_scope,
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
                unless ($terminal_seen) {
                    die PAGI::Exception::IncompleteResponse->new(
                        stage   => 'after_start',
                        message => 'HTTP application completed after response start without a terminal body',
                    );
                }
                if ($caught) {
                    $DISCARD_TRACE_WINDOW->($trace, $checkpoint);
                    next;
                }
                return if $forwarded_start;
            }

            my $snapshot = $trace->snapshot($checkpoint);
            if ($snapshot->routing_declined) {
                next unless $is_last;
                return;
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

Cascade tries applications in order. For HTTP it is also a routing component:
an unanswered child that publishes a trusted routing decline advances to the
next child, while a final trusted decline remains unanswered for an enclosing
L<PAGI::Middleware::Routing::NotFound>,
L<PAGI::Middleware::Routing::MethodNotAllowed>, or L<PAGI::Compose> boundary.
An arbitrary application that completes without either starting a response or
publishing a trusted decline instead throws
L<PAGI::Exception::IncompleteResponse>.

The C<catch> list is a separate response rule. On a non-final child, Cascade
inspects C<http.response.start>; a listed status suppresses that complete
response and advances. The caught child is awaited through its terminal body
before the next child begins. A final explicit response always passes through
unchanged, even when its status is listed in C<catch>. Exceptions never become
declines or caught responses.

Response starts and body chunks from a non-caught child are forwarded as they
arrive rather than buffered until completion. Caught events are suppressed.
Body-before-start and incomplete started responses are typed lifecycle errors,
and failures after a forwarded start propagate so the server can abort the
stream. Routing evidence belonging only to a successfully completed caught
response is hidden from later enclosing snapshots; earlier snapshots remain
unchanged.

WebSocket, SSE, lifespan, and extension scopes retain the historical native
Cascade behavior and do not use HTTP catch, lifecycle, or routing-trace logic.
An HTTP Cascade intended as a deployed root should be enclosed by an explicit
routing fallback policy or L<PAGI::Compose> so a final Router decline receives
an application response.

    my $routing = PAGI::App::Cascade->new(
        apps => [
            $static_app,          # explicit caught 404 may advance
            $api_router->to_app,  # trusted Router decline may advance
            $site_router->to_app, # final decline passes outward
        ],
    );

    my $app = compose(app => $routing)->to_app;

The status catch and trusted-decline paths are intentionally distinct. Cascade
does not turn a caught response into routing evidence, and it does not require
a Router to manufacture 404 merely to advance.

=head1 OPTIONS

=over 4

=item * C<apps> - Arrayref of apps to try in order.
Entries in C<apps> (and arguments to C<add>) accept anything L<PAGI::Utils/to_app> accepts: a coderef, a component object with a C<to_app> method, or a class name.

=item * C<catch> - Arrayref of explicit HTTP response status codes to catch on
non-final children (default: [404, 405]). Trusted routing declines are detected
independently of this list.

=back

=head1 METHODS

=head2 add($app)

Add an app to the cascade.

=head1 SEE ALSO

L<PAGI::Compose>, L<PAGI::Routing::Trace>,
L<PAGI::Middleware::Routing::NotFound>,
L<PAGI::Middleware::Routing::MethodNotAllowed>,
L<PAGI::Exception::IncompleteResponse>

=cut
