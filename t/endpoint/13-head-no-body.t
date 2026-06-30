use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use PAGI::Endpoint::HTTP;

# A HEAD request to an endpoint with only a `get` handler must return GET's
# headers (incl. Content-Length) but NO body — without relying on
# Middleware::Head being stacked.

package PageEndpoint {
    use parent 'PAGI::Endpoint::HTTP';
    use Future::AsyncAwait;
    async sub get {
        my ($self, $ctx) = @_;
        return $ctx->response->html('<h1>Secret report body</h1>');   # 27 bytes
    }
}

subtest 'HEAD falls back to GET but ships no body' => sub {
    my $app = PageEndpoint->to_app;
    my @sent;
    my $scope = { type => 'http', method => 'HEAD', path => '/report', headers => [] };
    $app->($scope, sub { Future->done({ type => 'http.request' }) },
           sub { push @sent, $_[0]; Future->done })->get;

    is $sent[0]{type}, 'http.response.start', 'response.start emitted';
    is $sent[0]{status}, 200, 'status 200 (HEAD maps to GET)';
    my %h = map { lc($_->[0]) => $_->[1] } @{ $sent[0]{headers} // [] };
    is $h{'content-length'}, 27, 'Content-Length reflects the GET body';
    is $sent[1]{body}, '', 'body is empty for HEAD';
    is $sent[1]{more}, 0, 'response completed';
};

subtest 'GET still returns the body (regression)' => sub {
    my $app = PageEndpoint->to_app;
    my @sent;
    my $scope = { type => 'http', method => 'GET', path => '/report', headers => [] };
    $app->($scope, sub { Future->done({ type => 'http.request' }) },
           sub { push @sent, $_[0]; Future->done })->get;

    like $sent[1]{body}, qr/Secret report body/, 'GET keeps its body';
};

done_testing;
