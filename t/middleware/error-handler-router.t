use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use lib 't/lib';
use PAGITest::Invoke qw(invoke);
use PAGI::Middleware::ErrorHandler;
use PAGI::Tools qw(compose middleware response route router);

# With exception handling active (an ErrorHandler with catch entries), the
# router raises its 404 and 405 to it, as Starlette's router raises
# HTTPException when it is inside an application; the exception boundary
# picks the entry or the default answer, which is the router's own plain
# response. Asserted on the captured events: Test::Client blanks HEAD
# bodies itself.

sub header_of {
    my ($r, $name) = @_;
    my ($pair) = grep { lc($_->[0]) eq lc($name) } @{ $r->{headers} // [] };
    return $pair ? $pair->[1] : undef;
}

my @routes = (route('/notes' => sub { response('Text', 'ok') }, methods => ['GET', 'POST']));
my $entries = {
    404 => sub { my ($request) = @_; response('Text', 'no such page: ' . $request->path, status => 404) },
    # A 405 entry is responsible for Allow (ErrorHandler's rule for a status
    # that must carry a field); the router's value is on the exception.
    405 => sub { my ($request, $error) = @_;
        response('Text', 'not like that', status => 405, headers => [map { @$_ } @{ $error->exception->headers }]) },
};

subtest 'an unknown path, with a catch{404} entry: answered by it' => sub {
    my $app = compose(routes => \@routes, middleware => [middleware('ErrorHandler', catch => $entries)]);
    my $r = invoke($app->to_app, path => '/nowhere');
    is [$r->{status}, $r->{body}], [404, 'no such page: /nowhere'];
    ok $r->{future}->is_done, 'handled';
};

subtest "a wrong method, with catch{405}: answered, keeping the router's Allow" => sub {
    my $app = compose(routes => \@routes, middleware => [middleware('ErrorHandler', catch => $entries)]);
    my $r = invoke($app->to_app, path => '/notes', method => 'DELETE');
    is [$r->{status}, $r->{body}], [405, 'not like that'];
    like header_of($r, 'Allow'), qr/\AGET, HEAD, POST\z|\AGET, POST, HEAD\z|GET.*POST/, 'the authoritative method union';
};

subtest 'exception handling active but no entry for them: today\'s responses, byte for byte' => sub {
    my $plain = compose(routes => \@routes);
    my $active = compose(routes => \@routes,
        middleware => [middleware('ErrorHandler', catch => { 'Local::Other' => sub { response('Text', 'x') } })]);
    for my $case (['/nowhere', 'GET'], ['/notes', 'DELETE']) {
        my ($path, $method) = @$case;
        my $before = invoke($plain->to_app, path => $path, method => $method);
        my $after  = invoke($active->to_app, path => $path, method => $method);
        is [$after->{status}, $after->{headers}, $after->{body}], [$before->{status}, $before->{headers}, $before->{body}],
            "$method $path: the same status, headers and body";
    }
};

subtest 'no configured ErrorHandler: the router does not throw' => sub {
    my $r = invoke(compose(routes => \@routes)->to_app, path => '/nowhere');
    is [$r->{status}, $r->{body}], [404, 'Not Found'];
    ok $r->{future}->is_done;
};

subtest 'an explicit http_default still answers an unknown path' => sub {
    my $app = compose(routes => \@routes,
        http_default => sub { response('Text', 'the default', status => 404) },
        middleware => [middleware('ErrorHandler', catch => $entries)]);
    is invoke($app->to_app, path => '/nowhere')->{body}, 'the default';
};

subtest 'HEAD to an unknown path, with catch{404}: headers, no body' => sub {
    my $composed = compose(routes => \@routes, middleware => [middleware('ErrorHandler', catch => $entries)]);
    my $bare = PAGI::Middleware::ErrorHandler->new(catch => $entries)->wrap(router(routes => \@routes)->to_app);
    for my $case (['under Compose', $composed->to_app], ['bare, around a Router', $bare]) {
        my ($label, $app) = @$case;
        my $r = invoke($app, path => '/nowhere', method => 'HEAD');
        is $r->{status}, 404, "$label: the entry's status";
        is $r->{body}, '', "$label: no body";
        my @bodies = grep { $_->{type} eq 'http.response.body' } @{ $r->{events} };
        ok !(grep { length($_->{body} // '') } @bodies), "$label: no body bytes in any event";
    }
};

done_testing;
