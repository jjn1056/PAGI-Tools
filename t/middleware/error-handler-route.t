use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(refaddr);

use lib 'lib';
use lib 't/lib';
use PAGITest::Invoke qw(invoke);
use PAGI::CSRF qw(csrf);
use PAGI::Exception::HTTP;
use PAGI::Middleware::Session qw(session_store);
use PAGI::Session qw(session);
use PAGI::Test::Client;
use PAGI::Tools qw(compose endpoint middleware mount response route router websocket);
use PAGI::Utils qw(as_app_object);

# A catch entry answering an error a route's own handler threw gets that
# route's own Request, as Starlette's request_response hands an exception
# handler the endpoint's Request: what the route read (its form), its
# path_params, and the scope keys of middleware inside the ErrorHandler.

package Local::Conflict { sub new { my ($class, %f) = @_; bless {%f}, $class } }
package Local::Base     { sub new { bless {}, shift } }
package Local::Derived  { our @ISA = ('Local::Base') }

my %form_post = (form => { title => 'Rotate the key' });

subtest "a class entry gets the route's own Request" => sub {
    my ($route_request, $entry_request, $form_title);
    my $app = compose(
        routes => [route('/notes/{id}' => async sub {
            my ($request) = @_;
            $route_request = $request;
            my $form = await $request->form_params;
            die Local::Conflict->new(title => $form->get('title'));
        }, methods => ['POST'])],
        middleware => [middleware('ErrorHandler', catch => { 'Local::Conflict' => async sub {
            my ($request, $error) = @_;
            $entry_request = $request;
            $form_title = (await $request->form_params)->get('title');
            return response('Text', join('|', $form_title, $request->path_param('id'),
                $error->exception->{title}), status => 409);
        } })],
    );
    my $res = PAGI::Test::Client->new(app => $app)->post('/notes/7', %form_post);
    is [$res->status, $res->text], [409, 'Rotate the key|7|Rotate the key'],
        'the form the route read, and the path_param';
    is refaddr($entry_request), refaddr($route_request), 'the same Request object';
};

subtest 'the scope keys of middleware inside the ErrorHandler are there' => sub {
    my $app = compose(
        routes => [route('/' => sub { die Local::Conflict->new }, methods => ['GET'])],
        # ErrorHandler listed outside Session and CSRF: only the route's own
        # Request carries their keys.
        middleware => [
            middleware('ErrorHandler', catch => { 'Local::Conflict' => sub {
                my ($request) = @_;
                session($request)->set(seen => 1);
                return response('Text', 'token:' . (length(csrf($request)->token) ? 'yes' : 'no'), status => 409);
            } }),
            middleware('Session', store => session_store('Memory')),
            middleware('CSRF', session => 1),
        ],
    );
    my $res = PAGI::Test::Client->new(app => $app)->get('/');
    is [$res->status, $res->text], [409, 'token:yes'], 'the session and the CSRF token are reachable';
};

subtest 'a status entry for an HTTP error answers at the route; the lookup order' => sub {
    my $seen;
    my $app = compose(
        routes => [
            route('/http' => sub { PAGI::Exception::HTTP->throw(409, 'taken') }),
            route('/derived' => sub { die Local::Derived->new }),
        ],
        middleware => [middleware('ErrorHandler', catch => {
            409          => sub { my ($request) = @_; response('Text', 'status ' . $request->path) },
            'Local::Base' => sub { my ($request) = @_; response('Text', 'ancestor ' . $request->path, status => 400) },
        })],
    );
    my $client = PAGI::Test::Client->new(app => $app);
    my $res = $client->get('/http');
    is [$res->status, $res->text], [409, 'status /http'], 'the status entry, with the route Request';
    $res = $client->get('/derived');
    is [$res->status, $res->text], [400, 'ancestor /derived'], 'a class entry for an ancestor';
};

subtest 'an entry may answer with an application; headers it sets are sent' => sub {
    my $app = compose(
        routes => [route('/' => sub { die Local::Conflict->new })],
        middleware => [middleware('ErrorHandler', catch => { 'Local::Conflict' => sub {
            return as_app_object(async sub {
                my ($scope, $receive, $send) = @_;
                await $send->({ type => 'http.response.start', status => 401,
                    headers => [['www-authenticate', 'Bearer'], ['content-type', 'text/plain']] });
                await $send->({ type => 'http.response.body', body => "native $scope->{path}", more => 0 });
            });
        } })],
    );
    my $res = PAGI::Test::Client->new(app => $app)->get('/');
    is [$res->status, $res->header('WWW-Authenticate'), $res->text], [401, 'Bearer', 'native /'],
        'the application runs with the route scope and its send';
};

subtest "an HTTP error's own headers are kept on the built-in answer at the route" => sub {
    my $app = compose(
        routes => [route('/' => sub { PAGI::Exception::HTTP->throw(503, 'later', headers => ['Retry-After' => '30']) })],
        middleware => [middleware('ErrorHandler')],
    );
    my $res = PAGI::Test::Client->new(app => $app)->get('/');
    is [$res->status, $res->header('Retry-After')], [503, '30'];
};

{
    package Local::NoteEndpoint;
    use parent 'PAGI::Endpoint::HTTP';
    our $seen;
    sub post {
        my ($self, $request) = @_;
        $seen = $request;
        die Local::Conflict->new(title => 'from post');
    }
}
{
    package Local::BuiltEndpoint;
    use parent 'PAGI::Endpoint::HTTP';
    our $seen;
    sub BUILD_APP {
        my ($class) = @_;
        return sub { my ($request) = @_; $seen = $request; die Local::Conflict->new(title => 'from builder') };
    }
    sub post { }
}
{
    package Local::NewEndpoint;
    use parent 'PAGI::Endpoint::HTTP';
    sub new { die Local::Conflict->new(title => 'from new') }
    sub post { }
}

subtest 'an Endpoint: its method and its Request-taking builder answer at the route' => sub {
    my $got;
    my $app = compose(
        routes => [
            route('/method'  => endpoint('Local::NoteEndpoint')),
            route('/builder' => endpoint('Local::BuiltEndpoint')),
            route('/new'     => endpoint('Local::NewEndpoint')),
        ],
        middleware => [middleware('ErrorHandler', catch => { 'Local::Conflict' => sub {
            my ($request, $error) = @_;
            $got = $request;
            return response('Text', $error->exception->{title}, status => 409);
        } })],
    );
    my $client = PAGI::Test::Client->new(app => $app);
    my $res = $client->post('/method');
    is [$res->status, $res->text], [409, 'from post'], 'a handler method';
    is refaddr($got), refaddr($Local::NoteEndpoint::seen), "with that method's Request";
    $res = $client->post('/builder');
    is [$res->status, $res->text], [409, 'from builder'], 'a builder that receives a Request';
    is refaddr($got), refaddr($Local::BuiltEndpoint::seen), "with the builder's Request";
    $res = $client->post('/new');
    is [$res->status, $res->text], [409, 'from new'], 'an endpoint built with new: the enclosing boundary answers';
    ok !defined(eval { $got->form_params->get; 1 }), 'with a Request that has no body';
};

subtest 'nested ErrorHandlers: the innermost table answers at the route' => sub {
    my $app = compose(
        routes => [mount('/inner', routes => [route('/' => sub { die Local::Conflict->new })],
            middleware => [middleware('ErrorHandler', catch => { 'Local::Conflict' => sub { response('Text', 'inner', status => 409) } })])],
        middleware => [middleware('ErrorHandler', catch => { 'Local::Conflict' => sub { response('Text', 'outer', status => 409) } })],
    );
    is(PAGI::Test::Client->new(app => $app)->get('/inner/')->text, 'inner');
};

subtest 'a route that started its response, then threw: not answered again' => sub {
    my @reported;
    my $app = compose(
        routes => [route('/' => sub {
            return as_app_object(async sub {
                my ($scope, $receive, $send) = @_;
                await $send->({ type => 'http.response.start', status => 200, headers => [] });
                die Local::Conflict->new;
            });
        })],
        middleware => [middleware('ErrorHandler', on_error => sub { push @reported, $_[0] },
            catch => { 'Local::Conflict' => sub { response('Text', 'entry', status => 409) } })],
    );
    my $r = invoke($app->to_app);
    is scalar(grep { $_->{type} eq 'http.response.start' } @{ $r->{events} }), 1, 'one response start';
    is scalar(@reported), 1, 'reported once';
    ok $r->{future}->is_failed, 'rethrown for the server';
};

subtest 'a WebSocket route is untouched' => sub {
    my $entry_ran = 0;
    my $app = compose(
        routes => [websocket('/ws' => sub { die Local::Conflict->new })],
        middleware => [middleware('ErrorHandler', catch => { 'Local::Conflict' => sub { $entry_ran++; response('Text', 'x') } })],
    );
    my $r = invoke($app->to_app, type => 'websocket', path => '/ws',
        body_events => [{ type => 'websocket.connect' }]);
    is $entry_ran, 0, 'the catch entry is for HTTP';
    ok !(grep { ($_->{type} // '') eq 'http.response.start' } @{ $r->{events} }), 'no HTTP answer';
    ok $r->{future}->is_failed, 'the error propagates';
};

subtest "the route classifies quietly: a rejected status is diagnosed once, where it is answered" => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $app = compose(
        routes => [route('/' => sub { PAGI::Exception::HTTP->throw(401, 'who are you') })],
        middleware => [middleware('ErrorHandler')],
    );
    my $res = PAGI::Test::Client->new(app => $app)->get('/');
    is $res->status, 500, 'a 401 the built-in answer cannot carry is a 500';
    is scalar(grep { /must carry WWW-Authenticate/ } @warnings), 1, 'diagnosed once';
};

done_testing;
