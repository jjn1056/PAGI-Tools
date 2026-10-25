use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';
use lib 't/lib';
use PAGITest::Invoke qw(invoke);
use PAGI::Middleware::RequestId;
use PAGI::Middleware::SecurityHeaders;
use PAGI::Tools qw(compose middleware response route);

# Compose renders a server error outside every application middleware, as
# Starlette's ServerErrorMiddleware does, and a PAGI scope is copied, not
# mutated: what application middleware adds never reaches the 500. Request
# identity and globally enforced response headers that must cover server
# errors wrap Compose, with the middleware's own wrap. Then the same request
# ID reaches on_error, the 500 handler and the response, whether a route or
# an application middleware failed.

sub header_of {
    my ($r, $name) = @_;
    my ($pair) = grep { lc($_->[0]) eq lc($name) } @{ $r->{headers} // [] };
    return $pair ? $pair->[1] : undef;
}

my (@reported, @rendered);
my $failing_middleware = middleware(sub {
    my ($app) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        die "the session store is down\n" if $scope->{path} eq '/middleware-fails';
        await $app->($scope, $receive, $send);
    };
});

sub board {
    my (@extra_middleware) = @_;
    return compose(
        routes => [route('/route-fails' => sub { die "database unreachable\n" })],
        middleware => [
            @extra_middleware,
            $failing_middleware,
            middleware('ErrorHandler',
                on_error => sub { my ($error, $scope) = @_; push @reported, $scope->{'pagi.request_id'}; return },
                handler  => sub {
                    my ($request) = @_;
                    push @rendered, $request->scope->{'pagi.request_id'};
                    return response('Text', 'sorry', status => 500);
                }),
        ],
    );
}

my $wrapped = PAGI::Middleware::SecurityHeaders->new->wrap(
    PAGI::Middleware::RequestId->new->wrap(board()->to_app));

for my $case (['a route', '/route-fails'], ['an application middleware', '/middleware-fails']) {
    my ($what, $path) = @$case;
    subtest "wrapping Compose, $what failing: one request ID everywhere" => sub {
        (@reported, @rendered) = ();
        my $r = invoke($wrapped, path => $path);
        my $sent = header_of($r, 'X-Request-ID');
        is [$r->{status}, $r->{body}], [500, 'sorry'], 'the handler answers';
        ok defined($sent) && length($sent), 'the 500 carries X-Request-ID';
        is \@reported, [$sent], 'on_error saw the same ID';
        is \@rendered, [$sent], 'so did the 500 handler';
        ok defined(header_of($r, 'X-Frame-Options')), 'and the security headers';
        ok $r->{future}->is_failed, 'rethrown for the server';
    };
}

subtest 'listed in Compose middleware, the 500 carries no request ID (the documented limit)' => sub {
    (@reported, @rendered) = ();
    my $r = invoke(board(middleware('RequestId'))->to_app, path => '/route-fails');
    is $r->{status}, 500;
    is header_of($r, 'X-Request-ID'), undef, 'no header';
    is [@reported, @rendered], [undef, undef], 'on_error and the handler see none';
};

done_testing;
