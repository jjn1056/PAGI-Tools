use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use lib 'lib';
use PAGI::Utils qw(invoke_app);
use PAGI::App::URLMap;
use PAGI::App::Cascade;
use PAGI::Response::Text ();
use PAGI::Routing qw(router mount);

# A native application sends its answer; one that returns a Response has the
# wrong shape -- most likely a ($request) handler in a native slot.
my $GUARD_TEXT = 'a native ($scope, $receive, $send) application returned a response '
    . 'instead of sending it; for a ($request) handler use request_response()';
my $GUARD = qr/\Q$GUARD_TEXT\E/;

my %scope = (type => 'http', method => 'GET', path => '/x', raw_path => '/x',
    root_path => '', headers => []);
my $receive = sub { Future->done({ type => 'http.disconnect' }) };
my $send = sub { Future->done };
sub failure_of { my $f = Future->wrap($_[0]); return $f->is_failed ? ($f->failure)[0] : undef }

my $returns_response = sub { PAGI::Response::Text->new('hi') };
my $async_returns_response = async sub { PAGI::Response::Text->new('hi') };

subtest 'invoke_app refuses a native app that returns a response' => sub {
    like failure_of(invoke_app($returns_response, {%scope}, $receive, $send)), $GUARD, 'sync';
    like failure_of(invoke_app($async_returns_response, {%scope}, $receive, $send)), $GUARD, 'async';
    is failure_of(invoke_app(sub { 1 }, {%scope}, $receive, $send)), undef,
        'any other return value carries no meaning and passes';
};

subtest 'hosting slots refuse it too' => sub {
    my $mounted = PAGI::App::URLMap->new->mount('/x' => $returns_response)->to_app;
    like failure_of($mounted->({%scope}, $receive, $send)), $GUARD, 'URLMap mount';
    my $default = PAGI::App::URLMap->new(default => $returns_response)->to_app;
    like failure_of($default->({%scope}, $receive, $send)), $GUARD, 'URLMap default';
    my $routed = router(routes => [mount('/x', app => $returns_response)])->to_app;
    like failure_of($routed->({%scope}, $receive, $send)), $GUARD, 'Router mount';
    my $cascade = PAGI::App::Cascade->new(apps => [$returns_response])->to_app;
    like failure_of($cascade->({%scope}, $receive, $send)), $GUARD, 'Cascade';
};

done_testing;
