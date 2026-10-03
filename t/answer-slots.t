use v5.40;
use Test2::V0;
use Future::AsyncAwait;
use lib 'lib';
use PAGI::Test::Client;
use PAGI::Response qw(response);
use PAGI::CSRF qw(csrf);
use PAGI::Auth qw(requires unauth_result);
use PAGI::Compose qw(compose);
use PAGI::Routing qw(route websocket middleware);
use PAGI::Middleware::CSRF;
use PAGI::Middleware::Maintenance;
use PAGI::Middleware::TrustedHosts;
use PAGI::App::File;
use PAGI::Utils qw(as_app_object);
use File::Temp qw(tempdir);

# A slot that answers a request reads a bare coderef as a Request handler.

subtest 'CSRF refuse: a Request handler reads the failure' => sub {
    my $app = PAGI::Middleware::CSRF->new(secret => 's', refuse => sub ($request) {
        response('JSON', { error => csrf($request)->failure }, status => 403);
    })->wrap(sub { die 'not reached' });
    my $res = PAGI::Test::Client->new(app => $app)->post('/');
    is [$res->status, $res->json], [403, { error => 'missing_cookie' }], 'answered by the handler';
};

subtest 'App::File refuse: a Request handler reads pagi.file_failure' => sub {
    my $files = PAGI::App::File->new(root => tempdir(CLEANUP => 1), refuse => sub ($request) {
        response('Text', 'no: ' . $request->scope->{'pagi.file_failure'}, status => 404);
    });
    is PAGI::Test::Client->new(app => $files)->get('/missing')->text, 'no: not_found';
};

subtest 'Maintenance response: a Request handler, async too' => sub {
    my $app = PAGI::Middleware::Maintenance->new(enabled => 1, response => async sub ($request) {
        response('Text', 'down for ' . $request->path, status => 503);
    })->wrap(sub { die 'not reached' });
    is PAGI::Test::Client->new(app => $app)->get('/x')->text, 'down for /x';
};

subtest 'TrustedHosts refuse: as_app_object still reaches a native app' => sub {
    my $app = PAGI::Middleware::TrustedHosts->new(hosts => ['example.com'], refuse => as_app_object(async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 421, headers => [] });
        await $send->({ type => 'http.response.body', body => 'native', more => 0 });
    }))->wrap(sub { die 'not reached' });
    my $res = PAGI::Test::Client->new(app => $app)->get('/', headers => { Host => 'evil.example' });
    is [$res->status, $res->text], [421, 'native'];
};

subtest 'Auth requires refuse: one Request handler answers HTTP and WebSocket' => sub {
    my $refuse = sub ($request) { response('Text', 'who are you', status => 401) };
    my $app = compose(
        middleware => [middleware('Authentication', backend => sub { unauth_result() })],
        routes => [
            route('/page' => requires([], sub { response('Text', 'in') }, refuse => $refuse)),
            websocket('/ws' => requires([], sub { die 'not reached' }, refuse => $refuse)),
        ],
    );
    my $client = PAGI::Test::Client->new(app => $app);
    is [$client->get('/page')->status, $client->get('/page')->text], [401, 'who are you'], 'HTTP';
    is $client->websocket('/ws')->response->{status}, 401, 'WebSocket deny';
};

subtest 'a native app given as a handler is told about as_app_object' => sub {
    my $expected = 'request handler returned nothing; a native ($scope, $receive, '
        . '$send) application given as a handler needs as_app_object()';
    my $app = compose(routes => [route('/n' => sub { my ($scope) = @_; return })]);
    my $client = PAGI::Test::Client->new(app => $app, raise_app_exceptions => 1);
    like dies { $client->get('/n') }, qr/\Q$expected\E/;
};

done_testing;
