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
# naming the handler's line.

my $read_line;
sub client_with {
    my (%error_handler) = @_;
    return PAGI::Test::Client->new(app => compose(
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
    my $res;
    my $warnings = warnings { $res = $client->post('/', form => { title => 'hi' }) };
    is $res->status, 500, 'the last-resort 500';
    like $warnings->[0],
        qr/\APAGI ErrorHandler handler failed: ErrorHandler handlers read the request's headers, not its body: the body was the application's at \Q${\__FILE__}\E line \Q$read_line\E\./,
        'the warning says why and where';
};

subtest 'so does a catch entry' => sub {
    my $client = client_with(catch => { 500 => async sub {
        my ($request) = @_;
        await $request->body;
        return response('Text', 'caught');
    } });
    my $res;
    my $warnings = warnings { $res = $client->post('/', form => { title => 'hi' }) };
    is $res->status, 500, 'the last-resort 500';
    like $warnings->[0], qr/\APAGI ErrorHandler catch entry failed: ErrorHandler handlers read the request's headers, not its body/,
        'the warning says why';
};

subtest 'a handler that reads only the headers answers' => sub {
    my $client = client_with(handler => sub {
        my ($request) = @_;
        return response('Text', 'handled ' . $request->method, status => 503);
    });
    my $res;
    my $warnings = warnings { $res = $client->post('/', form => { title => 'hi' }) };
    is [$res->status, $res->text], [503, 'handled POST'], 'its answer';
};

done_testing;
