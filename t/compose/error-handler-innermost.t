use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use lib 't/lib';
use PAGITest::Invoke qw(invoke);
use PAGI::Exception::HTTP;
use PAGI::Middleware::ErrorHandler;
use PAGI::Tools qw(compose middleware mount response route router);

# The innermost ErrorHandler answers, as Starlette's innermost
# ExceptionMiddleware replaces scope["starlette.exception_handlers"]: every
# exception boundary publishes itself, so an outer ErrorHandler's catch table
# never reaches past an inner one, and a mounted Compose is a barrier.

package Local::Conflict { sub new { bless {}, shift } }

my @outer_reported;
sub outer {
    my (@routes) = @_;
    return compose(routes => \@routes, middleware => [middleware('ErrorHandler',
        on_error => sub { push @outer_reported, ref($_[0]) || $_[0]; return },
        catch    => {
            'Local::Conflict'       => sub { response('Text', 'outer conflict entry', status => 409) },
            'PAGI::Exception::HTTP' => sub { response('Text', 'outer HTTP entry') },
        })]);
}

subtest 'a mounted Compose is a barrier to the outer catch table' => sub {
    @outer_reported = ();
    my $app = outer(mount('/inner', app => compose(routes => [
        route('/conflict' => sub { die Local::Conflict->new }),
        route('/http'     => sub { PAGI::Exception::HTTP->throw(404, 'inner note') }),
    ])))->to_app;
    my $r = invoke($app, path => '/inner/conflict');
    is [$r->{status}, $r->{body}], [500, 'Internal Server Error'], "the inner Compose's own 500, not the outer entry";
    $r = invoke($app, path => '/inner/http');
    is [$r->{status}, $r->{body}], [404, 'inner note'], "the inner Compose's built-in answer to its HTTP error";
    $r = invoke($app, path => '/inner/nowhere');
    is [$r->{status}, $r->{body}], [404, 'Not Found'], 'and its own routing 404';
};

subtest 'a handler-only ErrorHandler on a Mount answers its own routes, under an outer catch table' => sub {
    my (@inner_reported);
    @outer_reported = ();
    my $api = middleware('ErrorHandler',
        on_error => sub { push @inner_reported, ref($_[0]) || $_[0]; return },
        handler  => sub { response('Text', 'api 500', status => 500) });
    my $app = outer(mount('/api', routes => [
        route('/conflict' => sub { die Local::Conflict->new }),
        route('/http'     => sub { PAGI::Exception::HTTP->throw(404, 'api note') }),
    ], middleware => [$api]))->to_app;

    my $r = invoke($app, path => '/api/conflict');
    is [$r->{status}, $r->{body}], [500, 'api 500'], "the Mount's handler, not the outer entry";
    $r = invoke($app, path => '/api/http');
    is [$r->{status}, $r->{body}], [404, 'api note'], "the Mount's built-in answer, not the outer entry";
    is \@inner_reported, ['Local::Conflict', 'PAGI::Exception::HTTP'], "the Mount's on_error saw both";

    $r = invoke($app, path => '/api/nowhere');
    is [$r->{status}, $r->{body}], [404, 'Not Found'],
        "the Mount's Router answers its own miss: the innermost ErrorHandler has no catch entries";
    is \@inner_reported, ['Local::Conflict', 'PAGI::Exception::HTTP'], 'not raised, so not reported';
};

subtest 'with no inner ErrorHandler, the outer table still answers inside a Router mount' => sub {
    my $app = outer(mount('/r', app => router(routes => [route('/c' => sub { die Local::Conflict->new })])))->to_app;
    is invoke($app, path => '/r/c')->{body}, 'outer conflict entry';
    is invoke($app, path => '/r/nowhere')->{body}, 'outer HTTP entry', "and the child Router's miss";
};

done_testing;
