use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use PAGI::Compose qw(compose);
use PAGI::Middleware::Session qw(session_state session_store);
use PAGI::Response qw(response);
use PAGI::Routing qw(middleware route);
use PAGI::Session qw(session);
use PAGI::Test::Client;

# session_state(NAME, ...) and session_store(NAME, ...) build the State and
# Store objects the Session middleware takes, resolving NAME the way
# middleware() does: a short name under PAGI::Middleware::Session::State:: or
# ::Store::, an already-qualified name as given, and '+Exact::Package' as is.

subtest 'short names resolve under the State and Store namespaces' => sub {
    my $state = session_state('Cookie', cookie_name => 'myapp_session');
    isa_ok($state, 'PAGI::Middleware::Session::State::Cookie');
    is($state->{cookie_name}, 'myapp_session', 'with the arguments passed to new');
    isa_ok(session_state('Header', header_name => 'X-Session-ID'),
        'PAGI::Middleware::Session::State::Header');
    isa_ok(session_store('Memory'), 'PAGI::Middleware::Session::Store::Memory');
};

subtest 'a qualified name is kept, and + names an exact package' => sub {
    isa_ok(session_store('PAGI::Middleware::Session::Store::Memory'),
        'PAGI::Middleware::Session::Store::Memory');
    my $custom = session_store('+PAGITest::CustomSessionStore', label => 'mine');
    isa_ok($custom, 'PAGITest::CustomSessionStore');
    is($custom->{label}, 'mine', 'loaded from its file and built with its arguments');
};

subtest 'mistakes say what went wrong' => sub {
    like(dies { session_store('Nope') },
        qr/session_store\('Nope'\): cannot load PAGI::Middleware::Session::Store::Nope/,
        'an unknown name names the class it looked for');
    like(dies { session_state('Not a name') },
        qr/invalid session state class name; use leading '\+' for an exact package/,
        'an invalid name is refused');
};

subtest 'they plug straight into the middleware' => sub {
    my $app = compose(
        middleware => [middleware('Session',
            state => session_state('Cookie', cookie_name => 'built_session'),
            store => session_store('+PAGITest::CustomSessionStore'),
        )],
        routes => [route('/visits' => sub {
            my ($request) = @_;
            my $session = session($request);
            $session->set(visits => $session->get('visits', 0) + 1);
            return response('JSON', { visits => $session->get('visits') });
        })],
    );
    my $client = PAGI::Test::Client->new(app => $app);
    my $first = $client->get('/visits');
    like($first->header('set-cookie'), qr/^built_session=/, 'the named state sets the cookie');
    is($client->get('/visits')->json->{visits}, 2, 'and the custom store keeps the session');
};

done_testing;
