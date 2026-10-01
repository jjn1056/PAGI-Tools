use strict;
use warnings;

# The clock the middleware reads, so expiry can be tested without sleeping.
our $NOW;
BEGIN { *CORE::GLOBAL::time = sub () { defined $main::NOW ? $main::NOW : CORE::time() } }

use Test2::V0;
use Future::AsyncAwait;
use PAGI::Middleware::Session;

# A client's copy of the session's last-access time moves only when a cookie
# is sent, and a request that only reads sends none. The middleware re-sends
# the cookie once the last access is more than half of expire ago, so an
# active reader is never timed out (with the cookie store the last-access time
# lives in the cookie itself).

sub request {
    my ($middleware, $cookie, $handler) = @_;
    my @events;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        $handler->($scope->{'pagi.session'}) if $handler;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    };
    my $scope = { type => 'http', method => 'GET', path => '/',
        headers => defined $cookie ? [['Cookie', "pagi_session=$cookie"]] : [] };
    $middleware->wrap($app)->($scope, async sub { {} }, async sub { push @events, $_[0] })->get;
    my ($set) = map { $_->[1] } grep { lc($_->[0]) eq 'set-cookie' } @{ $events[0]{headers} };
    my ($value) = defined $set ? $set =~ /pagi_session=([^;]*)/ : ();
    return $value;
}

# The memory store saves last-access on every request, so each check starts a
# fresh session and reads it once.
my $mw = PAGI::Middleware::Session->new(expire => 10);
my $read_at = sub {
    my ($elapsed) = @_;
    local $NOW = 1_000;
    my $id = request($mw, undef, sub { $_[0]{user} = 'ada' });
    local $NOW = 1_000 + $elapsed;
    return ($id, request($mw, $id));
};

my ($id, $sent) = $read_at->(4);
ok($id, 'a new session sends its cookie');
is($sent, undef, 'a read before half of expire sends nothing');

($id, $sent) = $read_at->(6);
is($sent, $id, 'a read past half of expire re-sends the same session cookie');

done_testing;
