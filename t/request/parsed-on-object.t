use strict;
use warnings;
use Test2::V0;
use Future;

use lib 'lib';
use PAGI::Request;

# PAGI::Request keeps what it parses on the object and only reads the scope,
# as Starlette's Request does. A layer that hands the next one a scope with
# different headers, query or cookies therefore gets a Request that parses
# those, with nothing to invalidate.

sub scope_with {
    my (%args) = @_;
    return {
        type         => 'http',
        method       => 'POST',
        path         => '/',
        query_string => $args{query} // '',
        headers      => $args{headers} // [],
    };
}
my $receive = sub { Future->done({ type => 'http.request', body => 'a=1', more => 0 }) };

subtest 'a Request over a copy with new headers sees them' => sub {
    my $scope = scope_with(headers => [ [ 'x-who', 'outer' ] ]);
    is(PAGI::Request->new($scope, $receive)->header('x-who'), 'outer', 'the first Request parses them');
    my $copy = { %$scope, headers => [ [ 'x-who', 'inner' ] ] };
    is(PAGI::Request->new($copy, $receive)->header('x-who'), 'inner', 'the next one sees the rewrite');
};

subtest 'a Request over a copy with a new query string sees it' => sub {
    my $scope = scope_with(query => 'page=1');
    is(PAGI::Request->new($scope, $receive)->query_param('page'), '1', 'the first Request parses it');
    my $copy = { %$scope, query_string => 'page=2' };
    is(PAGI::Request->new($copy, $receive)->query_param('page'), '2', 'the next one sees the rewrite');
};

subtest 'a Request over a copy with a new cookie header sees it' => sub {
    my $scope = scope_with(headers => [ [ 'cookie', 'id=1' ] ]);
    is(PAGI::Request->new($scope, $receive)->cookie('id'), '1', 'the first Request parses it');
    my $copy = { %$scope, headers => [ [ 'cookie', 'id=2' ] ] };
    is(PAGI::Request->new($copy, $receive)->cookie('id'), '2', 'the next one sees the rewrite');
};

subtest 'nothing a Request parses is written to the scope' => sub {
    my $scope = scope_with(query => 'q=1', headers => [ [ 'cookie', 'id=1' ],
        [ 'content-type', 'application/x-www-form-urlencoded' ] ]);
    my %before = %$scope;
    my $request = PAGI::Request->new($scope, $receive);
    $request->headers;
    $request->query_params;
    $request->cookies;
    $request->form_params->get;
    is([ sort grep { !exists $before{$_} } keys %$scope ], [], 'no new scope keys');
};

done_testing;
