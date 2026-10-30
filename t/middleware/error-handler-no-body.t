use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use PAGI::Test::Client;
use PAGI::Tools qw(compose middleware response route);

# An ErrorHandler handler or catch entry gets a Request with no body, as
# Starlette's ServerErrorMiddleware hands its handler Request(scope) with no
# receive: the body was the application's, and on a real server reading it
# again would wait for an event that never comes. Reading it dies at once,
# naming the handler's line, with the message of every Request built from the
# scope alone (spec 2026-10-30 section 5: ErrorHandler calls
# request_for_scope($scope), and its own _no_body stub goes).

my $read_line;
# raise => 0 keeps the response of an error that is answered and rethrown.
sub client_with {
    my (%error_handler) = @_;
    my $raise = exists $error_handler{raise} ? delete $error_handler{raise} : 1;
    return PAGI::Test::Client->new(raise_app_exceptions => $raise, app => compose(
        routes => [route('/' => async sub {
            my ($request) = @_;
            await $request->form_params;
            die "the route failed\n";
        }, methods => ['POST'])],
        middleware => [middleware('ErrorHandler', %error_handler)],
    ));
}

subtest 'a handler that reads the body dies at once, naming its line' => sub {
    my $client = client_with(handler => async sub {
        my ($request) = @_;
        $read_line = __LINE__ + 1;
        my $form = await $request->form_params;
        return response('Text', 'handled ' . ($form->get('title') // '(none)'), status => 500);
    });
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    like dies { $client->post('/', form => { title => 'hi' }) },
        qr/\Athis Request was built from the scope alone; it has no body at \Q${\__FILE__}\E line \Q$read_line\E\./,
        'the failure the server gets says why and where';
    like \@warnings, [qr/\APAGI ErrorHandler handler failed while answering "the route failed": this Request was built from the scope alone/],
        'and one line names the error it was answering';
};

subtest 'so does a catch entry' => sub {
    my $client = client_with(catch => { 500 => async sub {
        my ($request) = @_;
        await $request->body;
        return response('Text', 'caught');
    } });
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    like dies { $client->post('/', form => { title => 'hi' }) },
        qr/\Athis Request was built from the scope alone; it has no body/,
        'the failure the server gets says why';
    like \@warnings, [qr/\APAGI ErrorHandler catch entry failed while answering "the route failed": /],
        'and one line names the error it was answering';
};

subtest 'a handler that reads only the headers answers' => sub {
    my $client = client_with(raise => 0, handler => sub {
        my ($request) = @_;
        return response('Text', 'handled ' . $request->method, status => 503);
    });
    my $res;
    my $warnings = warnings { $res = $client->post('/', form => { title => 'hi' }) };
    is [$res->status, $res->text], [503, 'handled POST'], 'its answer';
};

done_testing;
