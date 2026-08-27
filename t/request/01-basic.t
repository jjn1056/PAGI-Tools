#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;

use lib 'lib';
use PAGI::Request;

my $receive = sub { Future->fail('body unavailable') };

subtest 'constructor and basic properties' => sub {
    my $scope = {
        type         => 'http',
        method       => 'GET',
        path         => '/users/42',
        raw_path     => '/users/42',
        query_string => 'foo=bar&baz=qux',
        scheme       => 'https',
        http_version => '1.1',
        headers      => [
            ['host', 'example.com'],
            ['content-type', 'application/json'],
            ['accept', 'text/html'],
            ['accept', 'application/json'],
        ],
        client => ['127.0.0.1', 54321],
    };

    my $req = PAGI::Request->new($scope, $receive);

    is($req->method, 'GET', 'method');
    is($req->path, '/users/42', 'path');
    is($req->raw_path, '/users/42', 'raw_path');
    is($req->query_string, 'foo=bar&baz=qux', 'query_string');
    is($req->scheme, 'https', 'scheme');
    is($req->host, 'example.com', 'host from headers');
    is($req->content_type, 'application/json', 'content_type');
    is($req->client, ['127.0.0.1', 54321], 'client');
};

subtest 'host validates the raw Host field instead of using a last-value lookup' => sub {
    is(
        PAGI::Request->new({
            type    => 'http',
            headers => [['Host', 'example.com:8443']],
        }, $receive)->host,
        'example.com:8443',
        'preserves an explicit Host port',
    );

    is(
        PAGI::Request->new({ type => 'http', headers => [] }, $receive)->host,
        undef,
        'returns undef when Host is absent',
    );

    like(
        dies {
            PAGI::Request->new({
                type    => 'http',
                headers => [['Host', 'bad.example:65536']],
            }, $receive)->host;
        },
        qr/invalid authority/,
        'rejects a malformed Host field',
    );

    for my $case (
        [['Host', 'same.example'], ['host', 'same.example'], 'identical duplicates'],
        [['Host', 'one.example'], ['host', 'two.example'], 'conflicting duplicates'],
        [['hOsT', 'one.example'], ['HOST', 'two.example'], 'mixed-case duplicates'],
    ) {
        my ($first, $second, $description) = @$case;
        my $request = PAGI::Request->new({
            type    => 'http',
            headers => [$first, $second],
        }, $receive);

        is(
            $request->header('host'),
            $second->[1],
            "raw lookup remains last-value for $description",
        );
        like(
            dies { $request->host },
            qr/Host header must occur at most once/,
            "host rejects $description",
        );
    }
};

subtest 'predicate methods' => sub {
    my $get_scope = { type => 'http', method => 'GET', headers => [] };
    my $post_scope = { type => 'http', method => 'POST', headers => [] };

    my $get_req = PAGI::Request->new($get_scope, $receive);
    my $post_req = PAGI::Request->new($post_scope, $receive);

    ok($get_req->is_get, 'is_get true for GET');
    ok(!$get_req->is_post, 'is_post false for GET');
    ok($post_req->is_post, 'is_post true for POST');
    ok(!$post_req->is_get, 'is_get false for POST');
};

subtest 'all method predicates' => sub {
    my @methods = qw(GET POST PUT PATCH DELETE HEAD OPTIONS);
    my @predicates = qw(is_get is_post is_put is_patch is_delete is_head is_options);

    for my $i (0 .. $#methods) {
        my $method = $methods[$i];
        my $scope = { type => 'http', method => $method, headers => [] };
        my $req = PAGI::Request->new($scope, $receive);

        for my $j (0 .. $#predicates) {
            my $predicate = $predicates[$j];
            if ($i == $j) {
                ok($req->$predicate, "$predicate true for $method");
            } else {
                ok(!$req->$predicate, "$predicate false for $method");
            }
        }
    }
};

subtest 'content_length method' => sub {
    my $scope = {
        type => 'http',
        method => 'POST',
        headers => [
            ['content-length', '1234'],
            ['content-type', 'application/json'],
        ],
    };

    my $req = PAGI::Request->new($scope, $receive);
    is($req->content_length, '1234', 'content_length returns correct value');

    # Test without content-length header
    my $scope_no_cl = {
        type => 'http',
        method => 'GET',
        headers => [],
    };
    my $req_no_cl = PAGI::Request->new($scope_no_cl, $receive);
    is($req_no_cl->content_length, undef, 'content_length returns undef when missing');
};

subtest 'http_version property' => sub {
    my $scope_11 = {
        type => 'http',
        method => 'GET',
        http_version => '1.1',
        headers => [],
    };
    my $req_11 = PAGI::Request->new($scope_11, $receive);
    is($req_11->http_version, '1.1', 'http_version returns 1.1');

    my $scope_10 = {
        type => 'http',
        method => 'GET',
        http_version => '1.0',
        headers => [],
    };
    my $req_10 = PAGI::Request->new($scope_10, $receive);
    is($req_10->http_version, '1.0', 'http_version returns 1.0');
};

subtest 'raw property returns full scope' => sub {
    my $scope = {
        type => 'http',
        method => 'POST',
        path => '/test',
        headers => [['host', 'example.com']],
        custom_field => 'custom_value',
    };

    my $req = PAGI::Request->new($scope, $receive);
    is($req->raw, $scope, 'raw returns the full scope hash');
    is($req->raw->{custom_field}, 'custom_value', 'raw includes custom fields');
};

subtest 'case-insensitive header lookup' => sub {
    my $scope = {
        type => 'http',
        method => 'GET',
        headers => [
            ['host', 'example.com'],
            ['Content-Type', 'application/json'],
            ['X-Custom-Header', 'custom-value'],
        ],
    };

    my $req = PAGI::Request->new($scope, $receive);

    # Test various case combinations
    is($req->header('host'), 'example.com', 'lowercase header name');
    is($req->header('Host'), 'example.com', 'capitalized header name');
    is($req->header('HOST'), 'example.com', 'uppercase header name');
    is($req->header('HoSt'), 'example.com', 'mixed case header name');

    is($req->header('content-type'), 'application/json', 'content-type lowercase');
    is($req->header('Content-Type'), 'application/json', 'content-type original case');
    is($req->header('CONTENT-TYPE'), 'application/json', 'content-type uppercase');

    is($req->header('x-custom-header'), 'custom-value', 'custom header lowercase');
    is($req->header('X-Custom-Header'), 'custom-value', 'custom header original case');
    is($req->header('X-CUSTOM-HEADER'), 'custom-value', 'custom header uppercase');
};

subtest 'multiple headers with same name returns last value' => sub {
    my $scope = {
        type => 'http',
        method => 'GET',
        headers => [
            ['accept', 'text/html'],
            ['accept', 'application/json'],
            ['accept', 'text/plain'],
            ['x-custom', 'first'],
            ['x-custom', 'second'],
            ['x-custom', 'third'],
        ],
    };

    my $req = PAGI::Request->new($scope, $receive);
    is($req->header('accept'), 'text/plain', 'returns last accept header value');
    is($req->header('x-custom'), 'third', 'returns last x-custom header value');
};

subtest 'content-type parameter stripping' => sub {
    my $scope = {
        type => 'http',
        method => 'POST',
        headers => [
            ['content-type', 'application/json; charset=utf-8'],
        ],
    };

    my $req = PAGI::Request->new($scope, $receive);
    is($req->content_type, 'application/json', 'content_type strips charset parameter');

    # Test with multiple parameters
    my $scope_multi = {
        type => 'http',
        method => 'POST',
        headers => [
            ['content-type', 'text/html; charset=utf-8; boundary=something'],
        ],
    };
    my $req_multi = PAGI::Request->new($scope_multi, $receive);
    is($req_multi->content_type, 'text/html', 'content_type strips all parameters');

    # Test without parameters
    my $scope_plain = {
        type => 'http',
        method => 'POST',
        headers => [
            ['content-type', 'application/xml'],
        ],
    };
    my $req_plain = PAGI::Request->new($scope_plain, $receive);
    is($req_plain->content_type, 'application/xml', 'content_type without parameters');
};

subtest 'constructor requires an HTTP scope and receive callback' => sub {
    my $scope = {
        type => 'http',
        method => 'GET',
        headers => [],
    };

    like(dies { PAGI::Request->new({ type => 'http' }) }, qr/receive coderef/i,
        'receive callback is required');
    like(dies { PAGI::Request->new({ headers => [] }, $receive) },
        qr/scope type is required/i, 'scope type is required');
    like(dies { PAGI::Request->new({ type => 'sse' }, $receive) },
        qr/requires HTTP scope.*sse/i, 'only HTTP scopes are accepted');
    like(dies { PAGI::Request->new(bless({}, 'Local::Scope'), $receive) },
        qr/unblessed scope hashref/i, 'scope must be an unblessed hashref');
    like(
        dies { PAGI::Request->new($scope, $receive, sub { Future->done }) },
        qr/exactly.*scope.*receive/i,
        'a send callback or any other third constructor argument is rejected',
    );
    is(PAGI::Request->new({ type => 'http', server => ['127.0.0.1', 8080] }, $receive)->server,
        ['127.0.0.1', 8080], 'server returns the local endpoint tuple');
    is(PAGI::Request->new({ type => 'http' }, $receive)->server, undef,
        'server is optional');

    my $req_with_receive = PAGI::Request->new($scope, $receive);
    is($req_with_receive->{receive}, $receive, 'receive is stored');
};

subtest 'defaults and fallbacks' => sub {
    # Test raw_path with explicit value
    my $scope_with_raw = {
        type => 'http',
        method => 'GET',
        path => '/path',
        raw_path => '/raw/path',
        headers => [],
    };
    my $req_with_raw = PAGI::Request->new($scope_with_raw, $receive);
    is($req_with_raw->raw_path, '/raw/path', 'raw_path returns value when provided');

    # Test raw_path fallback to path
    my $scope_no_raw = {
        type => 'http',
        method => 'GET',
        path => '/fallback/path',
        headers => [],
    };
    my $req_no_raw = PAGI::Request->new($scope_no_raw, $receive);
    is($req_no_raw->raw_path, '/fallback/path', 'raw_path falls back to path when missing');

    # Test query_string defaults to empty string
    my $scope_no_qs = {
        type => 'http',
        method => 'GET',
        raw_path => '/test',
        headers => [],
    };
    my $req_no_qs = PAGI::Request->new($scope_no_qs, $receive);
    is($req_no_qs->query_string, '', 'query_string defaults to empty string');

    # Test scheme defaults to http
    my $scope_no_scheme = {
        type => 'http',
        method => 'GET',
        raw_path => '/test',
        headers => [],
    };
    my $req_no_scheme = PAGI::Request->new($scope_no_scheme, $receive);
    is($req_no_scheme->scheme, 'http', 'scheme defaults to http');

    # Test http_version defaults to 1.1
    my $scope_no_version = {
        type => 'http',
        method => 'GET',
        raw_path => '/test',
        headers => [],
    };
    my $req_no_version = PAGI::Request->new($scope_no_version, $receive);
    is($req_no_version->http_version, '1.1', 'http_version defaults to 1.1');

    # Test all defaults together
    my $minimal_scope = {
        type => 'http',
        method => 'GET',
        raw_path => '/minimal',
        headers => [],
    };
    my $minimal_req = PAGI::Request->new($minimal_scope, $receive);
    is($minimal_req->raw_path, '/minimal', 'minimal request: raw_path works');
    is($minimal_req->query_string, '', 'minimal request: query_string defaults');
    is($minimal_req->scheme, 'http', 'minimal request: scheme defaults');
    is($minimal_req->http_version, '1.1', 'minimal request: http_version defaults');
};

subtest 'connection state is tri-state and advanced delegates are absent' => sub {
    {
        package t::MockConn;
        sub new { bless { connected => $_[1] }, $_[0] }
        sub is_connected { shift->{connected} }
    }

    is(PAGI::Request->new({ type => 'http' }, $receive)->is_disconnected,
        undef, 'missing connection has unknown disconnected state');
    is(PAGI::Request->new({ type => 'http', 'pagi.connection' => t::MockConn->new(1) }, $receive)->is_disconnected,
        0, 'connected connection is not disconnected');
    is(PAGI::Request->new({ type => 'http', 'pagi.connection' => t::MockConn->new(0) }, $receive)->is_disconnected,
        1, 'disconnected connection is disconnected');
    ok(PAGI::Request->can('connection'), 'connection remains available');
    ok(!PAGI::Request->can($_), "$_ is not a Request delegate")
        for qw(is_connected disconnect_reason on_disconnect on_complete
               disconnect_future buffered_amount high_water_mark low_water_mark
               on_high_water on_drain is_writable);
};

subtest 'headers is a PAGI::Headers' => sub {
    my $scope = {
        type    => 'http',
        method  => 'GET',
        headers => [
            ['Accept', 'text/html'],
            ['Accept', 'application/json'],
            ['Content-Type', 'text/plain'],
            ['X-Custom', 'value1'],
        ],
    };

    my $req = PAGI::Request->new($scope, $receive);

    # headers returns PAGI::Headers
    my $headers = $req->headers;
    isa_ok $headers, ['PAGI::Headers'], 'headers() is a PAGI::Headers';

    # Single value access (last value - case-insensitive)
    is($headers->get('accept'), 'application/json', 'get returns last value');
    is($headers->get('content-type'), 'text/plain', 'access other headers');

    # Multi-value access
    my @accepts = $headers->get_all('accept');
    is(\@accepts, ['text/html', 'application/json'], 'get_all returns all values');

    # header_all method
    my @accepts2 = $req->header_all('accept');
    is(\@accepts2, ['text/html', 'application/json'], 'header_all works');
};

subtest 'request headers are a PAGI::Headers' => sub {
    my $scope = {
        type => 'http', method => 'GET',
        headers => [['Host','example.com'],['Accept','text/html'],['X-Multi','a'],['X-Multi','b']],
    };
    my $req = PAGI::Request->new($scope, $receive);
    isa_ok $req->headers, ['PAGI::Headers'], 'headers() is a PAGI::Headers';
    is $req->header('host'), 'example.com', 'case-insensitive single lookup';
    is [$req->header_all('x-multi')], ['a','b'], 'multi-value via header_all';
};

subtest 'mutating the returned headers does not affect the request' => sub {
    my $req = PAGI::Request->new({ type => 'http', method => 'GET', headers => [['Host','x.com']] }, $receive);
    $req->headers->clear;                 # mutate the returned object (a clone)
    is $req->header('host'), 'x.com', 'request lookups unaffected -- headers() is a clone';
};

done_testing;
