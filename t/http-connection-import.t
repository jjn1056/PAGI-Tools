#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::HTTPConnection qw(http_connection);

# http_connection($scope) is the function import for the safe reader: the
# one middleware reaches for to read headers, query and path parameters
# without a body or socket.

my $scope = {
    type    => 'http',
    method  => 'GET',
    path    => '/users',
    headers => [['Accept', 'application/json']],
};

subtest 'PAGI::HTTPConnection exports it on request' => sub {
    ok eval "package Local::FromConnection; use PAGI::HTTPConnection qw(http_connection); 1", 'imports' or diag $@;
    my $conn = eval { Local::FromConnection::http_connection($scope) };
    isa_ok $conn, ['PAGI::HTTPConnection'], 'the function returns a connection';
    is $conn->header('accept'), 'application/json', 'reading the scope';
    is $conn->scope, $scope, 'over that scope';
};

subtest 'PAGI::Tools exports it on request' => sub {
    ok eval "package Local::FromTools; use PAGI::Tools qw(http_connection); 1", 'imports' or diag $@;
    my $conn = eval { Local::FromTools::http_connection($scope) };
    isa_ok $conn, ['PAGI::HTTPConnection'], 'the function returns a connection';
    is $conn->path, '/users', 'reading the scope';
};

subtest 'a second argument croaks as new does' => sub {
    like dies { http_connection($scope, sub { }) },
        qr/requires exactly one scope argument/, 'the error is new\'s';
};

subtest 'subclasses importing nothing still import nothing' => sub {
    for my $class (qw(PAGI::Request PAGI::WebSocket PAGI::SSE)) {
        my $package = "Local::Plain::" . ($class =~ s/::/_/gr);
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $ok = eval "package $package; use $class; 1";
        ok $ok, "use $class compiles" or diag $@;
        ok !$package->can('http_connection'),
            "use $class does not import http_connection";
        is \@warnings, [], "use $class does not warn";
    }
};

subtest 'a subclass cannot export it' => sub {
    for my $class (qw(PAGI::Request PAGI::WebSocket PAGI::SSE)) {
        my $package = "Local::Asked::" . ($class =~ s/::/_/gr);
        my $ok = eval "package $package; use $class qw(http_connection); 1";
        ok !$ok, "use $class qw(http_connection) fails";
        like $@, qr/\A\Q$class\E exports nothing; import from PAGI::HTTPConnection at /,
            'and names the class asked and the one that exports it';
        ok !$package->can('http_connection'), 'and imports nothing';
    }
};

done_testing;
