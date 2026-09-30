use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use PAGI::Compose qw(compose);
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

done_testing;
