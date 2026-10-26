use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use PAGI::Auth qw(auth auth_result unauth_result);
use PAGI::Auth::SimpleUser;
use PAGI::Exception::HTTP;
use PAGI::Routing qw(sse websocket);
use PAGI::Test::Client;
use PAGI::Tools qw(compose middleware response route);

# An HTTP error an authentication backend throws is the client's answer, as
# Starlette's AuthenticationMiddleware answers its backend's
# AuthenticationError: the middleware answers it, with the answer a route's
# thrown HTTP error gets -- the ErrorHandler the scope carries, when the
# middleware is inside one (on a route), else the built-in answer. A 5xx is
# answered and re-raised, so the server logs it. Anything else a backend
# throws is a server error, as before.

my $ran = 0;
sub whoami {
    my ($request) = @_;
    ++$ran;
    my $user = auth($request)->user;
    return response('Text', 'user=' . ($user->is_authenticated ? $user->identity : 'none'));
}

sub client_for {
    my ($backend, %opts) = @_;
    my @auth = (middleware('Authentication', backend => $backend));
    my $app = $opts{on_route}
        ? compose(routes => [route('/' => \&whoami, middleware => \@auth)], middleware => $opts{middleware} // [])
        : compose(routes => [
              route('/' => \&whoami),
              websocket('/socket' => async sub { my ($ws) = @_; ++$ran; await $ws->accept; await $ws->close }),
              sse('/events' => async sub { my ($stream) = @_; ++$ran; await $stream->start; await $stream->close }),
          ], middleware => [@{ $opts{middleware} // [] }, @auth]);
    return PAGI::Test::Client->new(app => $app->to_app);
}

subtest 'in Compose middleware: a backend HTTP error is answered with its status' => sub {
    for my $case (
        ['thrown',              sub { PAGI::Exception::HTTP->throw(400, 'bad token format') }],
        ['a failed Future',     sub { Future->fail(PAGI::Exception::HTTP->new(400, 'bad token format')) }],
        ['from authenticate',   do { package Local::Backend; sub new { bless {}, shift }
                                     sub authenticate { PAGI::Exception::HTTP->throw(400, 'bad token format') } Local::Backend->new }],
    ) {
        my ($name, $backend) = @$case;
        $ran = 0;
        my $res = client_for($backend)->get('/');
        is [$res->status, $res->text, $res->header('Cache-Control')], [400, 'bad token format', 'no-store'],
            "$name: 400, the client message, as a route's thrown error is answered";
        is $ran, 0, "$name: the route never ran";
    }
};

subtest 'the error\'s headers reach the client' => sub {
    my $res = client_for(sub {
        PAGI::Exception::HTTP->throw(401, 'Sign in.', headers => ['WWW-Authenticate' => 'Bearer realm="notes"']);
    })->get('/');
    is [$res->status, $res->text, $res->header('WWW-Authenticate')], [401, 'Sign in.', 'Bearer realm="notes"'];
};

subtest 'a HEAD request gets the status and no body' => sub {
    my $res = client_for(sub { PAGI::Exception::HTTP->throw(400, 'bad token format') })->head('/');
    is [$res->status, $res->content], [400, ''];
};

subtest 'a 5xx is answered, then re-raised for the server to log' => sub {
    my $res;
    like warning { $res = client_for(sub { PAGI::Exception::HTTP->throw(503, 'identity provider down') })->get('/') },
        qr/exception after response completed: 503 identity provider down/, 're-raised';
    is [$res->status, $res->text], [503, 'Service Unavailable'], 'answered with the reason phrase, as a 5xx is';
};

subtest 'anything else a backend throws is still a server error' => sub {
    my $res;
    like warning { $res = client_for(sub { die "backend bug\n" })->get('/') },
        qr/exception after response completed: backend bug/, 'reported';
    is $res->status, 500;
};

subtest 'an uncaught malformed credential is a 400, not a server error' => sub {
    my $backend = sub {
        my ($request) = @_;
        my ($user) = $request->basic_auth(raise_on_error => 1);
        return defined $user ? auth_result(user => PAGI::Auth::SimpleUser->new(identity => $user)) : unauth_result();
    };
    my $res = client_for($backend)->get('/', headers => { Authorization => 'Basic !!!' });
    is [$res->status, $res->text], [400, 'The Authorization header could not be parsed.'];
    $res = client_for($backend)->get('/', headers => { Authorization => 'Basic YWRhOnRlc3Q=' });
    is [$res->status, $res->text], [200, 'user=ada'], 'a good credential still passes';
};

subtest 'on a route, the ErrorHandler the route is inside answers it, with its catch entries' => sub {
    my $reported = 0;
    my $json = sub {
        my ($request, $context) = @_;
        return response('JSON', { error => $context->message }, status => $context->status);
    };
    my $client = client_for(sub { PAGI::Exception::HTTP->throw(400, 'bad token format') }, on_route => 1,
        middleware => [middleware('ErrorHandler', catch => { 'PAGI::Exception::HTTP' => $json },
            on_error => sub { ++$reported; Future->done })]);
    my $res = $client->get('/');
    is [$res->status, $res->json], [400, { error => 'bad token format' }], 'the catch entry answers';
    is $reported, 1, 'and on_error hears of it, as of a route\'s error';
};

subtest 'a WebSocket or SSE connection is refused with the answer' => sub {
    my $client = client_for(sub {
        PAGI::Exception::HTTP->throw(401, 'Sign in.', headers => ['WWW-Authenticate' => 'Bearer']);
    });
    $ran = 0;
    my $sse = $client->sse('/events');
    isa_ok $sse, 'PAGI::Test::Response';    # a declined stream is answered, not started
    is [$sse->status, $sse->text, $sse->header('WWW-Authenticate')], [401, 'Sign in.', 'Bearer'], 'SSE: declined with the answer';

    my $ws = $client->websocket('/socket');
    ok $ws->refused, 'WebSocket: denied, not accepted';
    is [$ws->response->status, $ws->response->text], [401, 'Sign in.'], 'WebSocket: denied with the answer';
    is $ran, 0, 'neither handler ran';
};

done_testing;
