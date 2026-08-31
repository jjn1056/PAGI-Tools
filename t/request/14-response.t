use strict;
use warnings;
use Test2::V0;
use PAGI::CSRF;
use PAGI::Request;
use PAGI::Response;
use PAGI::Routing qw(route);
use PAGI::Routing::Resolver;
use PAGI::Routing::URL;
use PAGI::Session;
use PAGI::Stash;
use PAGI::State;
use PAGI::Transport;

{
    package T::TransportHandle;
    sub new { bless {}, shift }
    sub buffered_amount { 0 }
}

my $resolver = PAGI::Routing::Resolver->new(routes => [
    route('/items/{id}' => sub { }, name => 'item'),
]);
my $scope = {
    type             => 'http',
    method           => 'GET',
    headers          => [],
    path             => '/',
    raw_path         => '/',
    scheme           => 'http',
    root_path        => '',
    state            => { app_name => 'test' },
    'pagi.session'   => { _id => 'session-1', user_id => 42 },
    'pagi.transport' => T::TransportHandle->new,
    csrf_token       => 'csrf-token',
    'pagi.routing'   => {
        version => 1,
        frames  => [{
            resolver          => $resolver,
            logical_namespace => '/',
            captures          => {},
            mounts            => [],
            match             => undef,
        }],
    },
};
my $request = PAGI::Request->new($scope, sub { die 'body unavailable' });
my $response = PAGI::Response->new('outgoing bytes');

ok !$request->can('response'), 'Request no longer vends an outgoing Response';
is(PAGI::State->new($request)->get('app_name'), 'test', 'Request remains a State source');
is(PAGI::Stash->new($request)->set(request_id => 'r-1')->get('request_id'), 'r-1',
    'Request remains a Stash source');
is(PAGI::Session->new($request)->get('user_id'), 42, 'Request remains a Session source');
is(PAGI::CSRF->new($request)->token, 'csrf-token', 'Request remains a CSRF source');
my $urls = PAGI::Routing::URL->new($request);
isa_ok($urls, ['PAGI::Routing::URL'],
    'Request remains a Routing::URL source');
is($urls->path_for('item', { id => 7 }), '/items/7',
    'Request-backed Routing::URL renders a real reverse lookup');
is(PAGI::Transport->new($request)->buffered_amount, 0, 'Request remains a Transport source');

for my $helper (
    [ 'PAGI::State',        sub { PAGI::State->new($response) } ],
    [ 'PAGI::Stash',        sub { PAGI::Stash->new($response) } ],
    [ 'PAGI::Session',      sub { PAGI::Session->new($response) } ],
    [ 'PAGI::CSRF',         sub { PAGI::CSRF->new($response) } ],
    [ 'PAGI::Routing::URL', sub { PAGI::Routing::URL->new($response) } ],
    [ 'PAGI::Transport',    sub { PAGI::Transport->new($response) } ],
) {
    like dies { $helper->[1]->() }, qr/scope method|scope hashref/i,
        "$helper->[0] rejects Response as a scope source";
}

done_testing;
