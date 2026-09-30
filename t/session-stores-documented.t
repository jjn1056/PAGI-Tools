use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use PAGI::Compose qw(compose);
use PAGI::Middleware::Session;
use PAGI::Middleware::Session::Store::Memory;
use PAGI::Response qw(json_response);
use PAGI::Routing qw(middleware route);
use PAGI::Session qw(session);
use PAGI::Test::Client;

# What PAGI::Session and PAGI::Middleware::Session document about where the
# session lives: PAGI::Session needs the middleware; the default store is
# this process's memory; the cookie store keeps the session in the cookie.

my $SECRET = 'a-test-secret-that-is-at-least-32-bytes';

sub visits {
    my ($request) = @_;
    my $session = session($request);
    $session->set(visits => $session->get('visits', 0) + 1);
    return json_response({ visits => $session->get('visits') });
}

sub app_with {
    my (%session_config) = @_;
    return compose(
        middleware => [middleware('Session', secret => $SECRET, %session_config)],
        routes     => [route('/visits' => \&visits)],
    );
}

sub count { return $_[0]->get('/visits')->json->{visits} }

subtest 'PAGI::Session reads the session the middleware loads' => sub {
    my $client = PAGI::Test::Client->new(app => app_with());
    is([count($client), count($client)], [1, 2], 'the session carries across requests');
    like(dies { PAGI::Session->new({ type => 'http' }) },
        qr/PAGI::Session requires Session middleware \(missing pagi\.session\)/,
        'and without the middleware it says what is missing');
};

subtest 'the default store is this process memory' => sub {
    my $client = PAGI::Test::Client->new(app => app_with());
    is([count($client), count($client)], [1, 2], 'sessions persist while the process holds them');
    PAGI::Middleware::Session::Store::Memory->clear_all;    # as a restart, or another worker, sees it
    is(count($client), 1, 'a process without that memory starts the session over');
};

subtest 'the cookie store keeps the session in the cookie' => sub {
    eval { require PAGI::Middleware::Session::Store::Cookie; 1 }
        or skip_all 'PAGI::Middleware::Session::Store::Cookie is not installed';
    my $store = PAGI::Middleware::Session::Store::Cookie->new(secret => $SECRET);
    my $client = PAGI::Test::Client->new(app => app_with(store => $store));
    is([count($client), count($client)], [1, 2], 'the session carries across requests');
    PAGI::Middleware::Session::Store::Memory->clear_all;
    my $elsewhere = PAGI::Test::Client->new(app => app_with(store => $store));
    $elsewhere->set_cookie($_ => $client->cookie($_)) for keys %{ $client->cookies };
    is(count($elsewhere), 3, 'and any process holding the secret continues it from the cookie alone');
};

# State: how the session ID travels. Documented in PAGI::Middleware::Session
# ("STATE CLASSES") and pointed to from PAGI::Session.

subtest 'the cookie is configured on State::Cookie, not on the middleware' => sub {
    require PAGI::Middleware::Session::State::Cookie;
    my $set_cookie = sub {
        my (%config) = @_;
        return PAGI::Test::Client->new(app => app_with(%config))
            ->get('/visits')->header('set-cookie');
    };

    my $default = $set_cookie->(expire => 7200);
    like($default, qr/^pagi_session=.*HttpOnly.*SameSite=Lax/, 'the default state keeps its defaults');
    like($default, qr/Max-Age=3600\b/,
        "and its own lifetime: the middleware's expire (7200) is not passed to it");

    my $configured = $set_cookie->(state => PAGI::Middleware::Session::State::Cookie->new(
        cookie_name    => 'myapp_session',
        cookie_options => { httponly => 1, path => '/', samesite => 'Lax', secure => 1 },
        expire         => 7200,
    ));
    like($configured, qr/^myapp_session=.*HttpOnly.*Secure.*SameSite=Lax.*Max-Age=7200\b/,
        'a State::Cookie passed as state sets name, attributes and lifetime');

    for my $moved (qw(cookie_name cookie_options)) {
        like(dies { PAGI::Middleware::Session->new(secret => $SECRET, $moved => 'x') },
            qr/'$moved' is not a Session option.*PAGI::Middleware::Session::State::Cookie/,
            "$moved on the middleware dies naming where it goes");
    }
};

subtest 'header state: the application hands the client its session ID' => sub {
    require PAGI::Middleware::Session::State::Header;
    my $issued;
    my $app = compose(
        middleware => [middleware('Session', secret => $SECRET,
            state => PAGI::Middleware::Session::State::Header->new(header_name => 'X-Session-ID'))],
        routes => [
            route('/visits' => sub {
                my ($request) = @_;
                my $session = session($request);
                $issued = $session->id;
                $session->set(visits => $session->get('visits', 0) + 1);
                return json_response({ visits => $session->get('visits') });
            }),
            route('/login' => sub {
                my ($request) = @_;
                session($request)->regenerate;
                return json_response({ ok => 1 });
            }, methods => ['POST']),
        ],
    );
    my $client = PAGI::Test::Client->new(app => $app);
    my $res = $client->get('/visits');
    is($res->header('set-cookie'), undef, 'nothing carries the new session ID back');
    my $id = $issued;
    ok($id, 'but the handler can read it');
    my $with_id = sub { $client->get('/visits', headers => { 'X-Session-ID' => $id })->json->{visits} };
    is($with_id->(), 2, 'a client that sends it back continues the session');
    $client->post('/login', headers => { 'X-Session-ID' => $id });
    is($with_id->(), 1, 'regenerate replaces the ID where the handler cannot see it, so the old one starts over');
};

done_testing;
