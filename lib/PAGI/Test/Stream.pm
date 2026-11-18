package PAGI::Test::Stream;

use strict;
use warnings;
use Carp ();
use Future;
use Scalar::Util ();

use PAGI::Test::_Drive;
use PAGI::Test::ConnectionState ();
use PAGI::Test::Response ();

# Built by PAGI::Test::Client's stream: the request is made as get makes
# one, and the application is called and runs until it waits. Its ending is
# recorded when its Future is ready, whenever that is (inside another
# request, say), not when the test next looks.
sub _start {
    my ($class, %args) = @_;
    my $exchange = $args{exchange};
    my $self = bless {
        %$exchange,
        client => $args{client},
        read   => 0,    # how many chunks receive_chunk has returned
    }, $class;

    # The exchange and the application's Future hold these callbacks, and
    # the stream holds both, so the callbacks hold the stream weakly.
    my $weak = $self;
    Scalar::Util::weaken($weak);
    $self->{state}{on_capture} = sub { $weak->_captured if $weak };
    my $connection = $self->{scope}{'pagi.connection'};
    $connection->_set_abort_hook(sub { $weak->_wake if $weak });

    my $app = $self->{app_future} = Future->call($args{app}, @{$self}{qw(scope receive send)});
    $app->on_ready(sub { $weak->_app_ended($_[0]) if $weak });
    $connection->_deliver_notifications;
    $self->_raise_app_failure;
    return $self;
}

# The next body chunk's bytes, waiting for it if need be; undef once the
# response is over and every chunk has been read.
sub receive_chunk {
    my ($self, %opts) = @_;
    my $timeout = $opts{timeout} // 5;
    my @got = PAGI::Test::_Drive::wait_for($self, $timeout, sub {
        $self->{scope}{'pagi.connection'}->_deliver_notifications;
        my $chunks = $self->{response}{_chunks} // [];
        return $chunks->[ $self->{read}++ ] if $self->{read} < @$chunks;
        return undef if $self->is_closed;
        return;
    });
    $self->_raise_app_failure;
    Carp::croak('Timeout waiting for a response body chunk.' . PAGI::Test::_Drive::loop_hint()) unless @got;
    return $got[0];
}

# Everything sent so far, as a PAGI::Test::Response; undef before the start.
sub response {
    my ($self) = @_;
    return $self->{response}{_response_started} ? $self->{response} : undef;
}

# Over: complete, left by the client, aborted, or ended by the application.
sub is_closed {
    my ($self) = @_;
    return $self->{scope}{'pagi.connection'}->is_connected ? 0 : 1;
}

# The client leaves: the disconnect is delivered as the test client delivers
# one, then the application runs until it has reacted. One that's still
# running after the timeout is cancelled, so it can't resume in another
# test, and close dies saying so.
sub close {
    my ($self) = @_;
    unless ($self->is_closed) {
        my $connection = $self->{scope}{'pagi.connection'};
        $connection->_mark_disconnected('client_closed');
        $self->_wake;
        my $app = $self->{app_future};
        unless (PAGI::Test::_Drive::drive($app, $PAGI::Test::_Drive::TIMEOUT)) {
            $app->cancel;
            Carp::croak("PAGI application did not end within $PAGI::Test::_Drive::TIMEOUT seconds after the client left."
                . PAGI::Test::_Drive::loop_hint());
        }
    }
    return;
}

# An event landed: store the response's cookies once its start is in, as a
# client would on receiving it, and wake a waiting receive_chunk.
sub _captured {
    my ($self) = @_;
    if (!$self->{cookies_stored} && $self->{response}{_response_started}) {
        $self->{cookies_stored} = 1;
        $self->{client}->_finish_response($self->{response});
    }
    PAGI::Test::_Drive::signal_arrival($self);
    return;
}

# The connection ended: a receive the application is waiting on gets the
# disconnect, and a waiting receive_chunk looks again.
sub _wake {
    my ($self) = @_;
    my $waiting = $self->{state}{waiting_after_body};
    $waiting->done({ type => 'http.disconnect' }) if $waiting && !$waiting->is_ready;
    PAGI::Test::_Drive::signal_arrival($self);
    return;
}

# How the response ended. A connection still open when the application
# ends was left by it, failed or with the response unfinished: server_error
# (PAGI::Spec::Www, "Application Left a Response Incomplete"), as get
# records it. One already over (complete, left by the client, aborted)
# keeps its ending.
sub _app_ended {
    my ($self, $app) = @_;
    my $connection = $self->{scope}{'pagi.connection'};
    my $validator  = $self->{validator};
    my $error      = $app->is_failed ? scalar $app->failure : undef;
    $self->{response}->_record_exception($error) if defined $error;

    if ($connection->is_connected) {
        warn 'incomplete response: ', $validator->finalize, "\n" unless defined $error;
        $self->_server_error_response unless $validator->started;
        $connection->_mark_disconnected('server_error');
    }

    $connection->_deliver_notifications;
    $self->_captured;
    return;
}

# The 500 a server sends when the application fails or returns before it
# starts a response, as get gives.
sub _server_error_response {
    my ($self) = @_;
    $self->{response}->_capture_event($_) for PAGI::Test::Response::_server_error_events();
    $self->{scope}{'pagi.connection'}->_mark_response_started;
    return;
}

# With raise_app_exceptions, the application's failure is raised when
# the stream is made, or from receive_chunk.
sub _raise_app_failure {
    my ($self) = @_;
    return unless $self->{client}{raise_app_exceptions};
    my $app = $self->{app_future};
    return unless $app->is_ready && $app->is_failed;
    die scalar $app->failure;
}

1;

__END__

=head1 NAME

PAGI::Test::Stream - an HTTP response read as it's sent, which the client can leave

=head1 SYNOPSIS

    use PAGI::Test::Client;

    my $client = PAGI::Test::Client->new(app => $app);
    my $feed = $client->stream('/feed');

    is $feed->receive_chunk, "hello\n", 'the first chunk';
    is $client->get('/publish?hi')->text, 'published', 'another request meanwhile';
    is $feed->receive_chunk, "hi\n", 'which the feed sends on';

    $feed->close;                     # the client leaves
    ok !$feed->response->body_complete, 'the response never completed';

=head1 DESCRIPTION

What L<PAGI::Test::Client/stream> returns: a request in progress. You read
its body chunk by chunk as the application sends it, look at everything
sent so far, and leave whenever you like, as a browser does when the user
closes the tab. The application learns of it as it would from a server.

=head1 METHODS

=head2 receive_chunk

    my $bytes = $stream->receive_chunk;
    my $bytes = $stream->receive_chunk(timeout => 1);

The next body chunk's bytes, in the order they were sent: one per
C<http.response.body> event that carried any. It waits for one, running the
event loop, for up to C<timeout> seconds (5 by default), then dies with
C<Timeout waiting for a response body chunk>. Once the response is over
and every chunk has been read, it returns C<undef>.

=head2 response

    my $res = $stream->response;

Everything sent so far, as a L<PAGI::Test::Response>: the status, headers,
the body (read and unread), trailers, C<body_complete>, and C<exception>
when the application failed. It doesn't wait, and it's C<undef> until the
start has been sent.

=head2 close

    $stream->close;

The client leaves. The connection ends with C<client_closed>; a C<$receive>
the application is waiting on, and any later one, gets C<http.disconnect>;
later sends are dropped and succeed, as on a real server. Then the
application runs until it has reacted, so whatever it does on leaving has
happened when C<close> returns. One still running after the client's
timeout (5 seconds) is cancelled, so it can't resume later in another
test, and C<close> dies saying so. On a response that's already over,
C<close> does nothing.

=head2 is_closed

True once the response is over: complete, left by the client, aborted, or
ended by the application. How each ends is under
L<PAGI::Test::Client/SEMANTICS>.

=head1 SEE ALSO

L<PAGI::Test::Client>, L<PAGI::Test::Response>, L<PAGI::Test::SSE>

=cut
