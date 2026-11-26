package PAGI::Middleware::ErrorHandler;

use v5.24;
use warnings;
use parent 'PAGI::Middleware';
use Future::AsyncAwait;
use Scalar::Util ();
use PAGI::Exception::HTTP;
use PAGI::Response::Text;

# The app, with what it throws answered by response_for: before the
# response starts, and on every scope but lifespan, which passes through.
# What isn't answered, an answer from 500 up, and anything thrown after the
# response started go on to the server unchanged, so it reports them.
async sub call {
    my ($self, $scope, $receive, $send) = @_;
    my $app = $self->app;
    if ($scope->{type} eq 'lifespan') {
        await $app->($scope, $receive, $send);
        return;
    }
    my $done = eval { await $app->($scope, $receive, $send); 1 };
    return if $done;
    my $error = $@;
    die $error if $scope->{'pagi.connection'}->response_started;

    # The answer's status is read before it's sent, inside the eval, so an
    # answer that isn't a Response fails as C6 says, before sending anything.
    my ($response, $server_error);
    my $answered = eval {
        $response = $self->response_for($error, $scope);
        if ($response) {
            $server_error = $response->status >= 500;
            await $response->call($scope, $receive, $send);
        }
        1;
    };
    die _answer_failed($@, $error) unless $answered;
    die $error unless $response;
    die $error if $server_error;
    return;
}

# An HTTP error as plain text: its status, its headers, and its message or
# else the status's reason phrase. Anything else: nothing.
sub response_for {
    my ($self, $error, $scope) = @_;
    return unless Scalar::Util::blessed($error) && $error->isa('PAGI::Exception::HTTP');
    my $status = $error->status_code;
    return PAGI::Response::Text->new(
        status  => $status,
        content => $error->client_message // PAGI::Exception::HTTP::_reason_phrase($status),
        headers => $error->headers,
    );
}

# Perl has no exception chaining, so one error carries both: the answer's
# failure, then the error it was answering.
sub _answer_failed {
    my ($failure, $error) = @_;
    s/\n\z// for my ($was, $now) = ("$error", "$failure");
    return "the error handler's answer failed: $now (while answering: $was)\n";
}

1;

__END__

=encoding UTF-8

=head1 NAME

PAGI::Middleware::ErrorHandler - Answers the HTTP errors an application throws

=head1 SYNOPSIS

    use v5.40;
    use PAGI::Middleware::ErrorHandler;
    use PAGI::Exception::HTTP;

    my $app = async sub ($scope, $receive, $send) {
        PAGI::Exception::HTTP->throw(status_code => 404, client_message => 'No such note.')
            unless note_exists($scope->{path});
        ...
    };

    PAGI::Middleware::ErrorHandler->wrap($app);

=head1 INHERITANCE

    PAGI::Middleware::ErrorHandler
      PAGI::Middleware
        PAGI::App
          Class::Tiny::Object

=head1 DESCRIPTION

A L<PAGI::Middleware> that turns what the application throws into a
response, when it can, and leaves the rest to the server. It's
Starlette's C<ExceptionMiddleware>: the server, not this, makes the 500 for
an error nobody answers, and reports it.

When the application dies, or its Future fails, ErrorHandler asks
L</response_for> for an answer, and:

=over 4

=item * sends the answer, and the error ends there, when its status is
below 500;

=item * sends the answer, then rethrows the error to the server, from 500
up, so the server's log has it, cause and all;

=item * rethrows the error to the server when there's no answer: a plain
C<die>, or an exception nobody answers;

=item * rethrows the error to the server, without asking, once the
response has started (a stream under way, a WebSocket accepted, an SSE
stream started): there's nothing left to answer with.

=back

A rethrown error is the one thrown, unchanged: the same object, or the same
string.

On a C<websocket> or C<sse> scope, an error before the accept or the start
is answered with an HTTP response, which is how PAGI refuses a handshake. A
C<lifespan> scope passes straight through.

By default only L<PAGI::Exception::HTTP> is answered: as plain text, with
its status, its headers, and its C<client_message>, or else the status's
reason phrase (C<Not Found>). The message is sent from 500 up too: it's
meant for the client, and what isn't goes in the error's C<cause>.

=head1 METHODS

=head2 response_for

    my $response = $self->response_for($error, $scope);

The answer to C<$error>: a L<PAGI::Response>, or nothing to let the error go
on to the server. It's called for every error thrown before the response
starts, so a subclass can answer its own exceptions, and send JSON or a page
for HTTP errors, then leave the rest to this one:

    package MyApp::Errors {
        use v5.40;
        use parent 'PAGI::Middleware::ErrorHandler';
        use Scalar::Util qw(blessed);
        use PAGI::Response::JSON;

        sub response_for ($self, $error, $scope) {
            return PAGI::Response::JSON->new(status => 410, content => { error => 'deleted' })
                if blessed $error && $error->isa('MyApp::Gone');
            return $self->SUPER::response_for($error, $scope);
        }
    }

    MyApp::Errors->wrap($app);

An answer from 500 up is still rethrown after it's sent, so a page you send
for a plain C<die> doesn't keep the error from the server.

=head2 Other HTTP exception classes

Only L<PAGI::Exception::HTTP> is answered by default. An exception class
written for Plack, such as L<HTTP::Exception>, is an error nobody answers
until your C<response_for> says how:

    return PAGI::Response::Text->new(status => $error->code, content => $error->status_message)
        if blessed $error && $error->isa('HTTP::Exception::Base');

L<HTTP::Throwable> is the same, with its own method names.

=head1 WHEN THE ANSWER FAILS

If C<response_for>, or sending its answer, dies, the error it was answering
would be lost: Perl has no exception chaining. So ErrorHandler throws one
error naming both, for the server to report:

    the error handler's answer failed: <the failure> (while answering: <the error>)

=head1 WHERE TO WRAP IT

Wrap it closest to your application, with every other middleware outside
it. Its answer goes out through what it was given to send with, so only the
layers outside it add to that answer: a CORS header, or a session cookie,
from a layer inside it never reaches the 404. Starlette puts its
C<ExceptionMiddleware> in the same place, innermost.

=head1 SEE ALSO

L<PAGI::Exception::HTTP>, L<PAGI::Middleware>

=cut
