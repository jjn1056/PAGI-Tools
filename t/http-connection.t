#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::HTTPConnection;

# PAGI::HTTPConnection is what can be known about an http, websocket or sse
# request without talking to it: the scope, headers, query, path parameters,
# cookies and application state. It reads the scope and never writes it.

my $connection = bless {}, 'Local::Connection';

# A scope of the given type carrying every field the methods read.
sub full_scope {
    my ($type, %extra) = @_;
    return {
        type         => $type,
        ($type eq 'websocket' ? () : (method => 'GET')),
        path         => '/users',
        root_path    => '/admin',
        query_string => 'foo=bar&baz=qux&foo=second&name=John%20Doe&emoji=%F0%9F%94%A5',
        http_version => '2',
        headers      => [
            ['Host', 'example.com'],
            ['Accept', 'text/html'],
            ['accept', 'application/json'],
            ['Cookie', 'session=abc123; theme=dark'],
        ],
        client       => ['127.0.0.1', 54321],
        server       => ['127.0.0.1', 8080],
        path_params  => { id => '42' },
        state        => { db => 'handle' },
        'pagi.connection' => $connection,
        %extra,
    };
}

subtest 'every method over an http, a websocket and an sse scope' => sub {
    for my $type (qw(http websocket sse)) {
        my $scope = full_scope($type);
        my $c = PAGI::HTTPConnection->new($scope);

        is refaddr($c->scope), refaddr($scope), "$type: scope is the scope it was built over";
        is refaddr($c->connection), refaddr($connection), "$type: connection is pagi.connection";
        is $c->client, ['127.0.0.1', 54321], "$type: client";
        is $c->server, ['127.0.0.1', 8080], "$type: server";
        is $c->http_version, '2', "$type: http_version";
        is $c->path, '/users', "$type: path";
        is $c->raw_path, '/admin/users', "$type: raw_path without a scope raw_path";
        is $c->raw_path_info, '/users', "$type: raw_path_info";
        is $c->request_uri,
            '/admin/users?foo=bar&baz=qux&foo=second&name=John%20Doe&emoji=%F0%9F%94%A5',
            "$type: request_uri";
        is $c->query_string,
            'foo=bar&baz=qux&foo=second&name=John%20Doe&emoji=%F0%9F%94%A5',
            "$type: query_string";

        isa_ok $c->headers, ['PAGI::Headers'], "$type: headers";
        is $c->header('host'), 'example.com', "$type: header is case-insensitive";
        is $c->header('ACCEPT'), 'text/html, application/json',
            "$type: header joins a repeated field";
        is [$c->header_all('accept')], ['text/html', 'application/json'],
            "$type: header_all gives every field";
        is $c->header('x-missing'), undef, "$type: an absent header is undef";

        isa_ok $c->query_params, ['Hash::MultiValue'], "$type: query_params";
        is [$c->query_params->get_all('foo')], ['bar', 'second'],
            "$type: query_params keeps every value";
        is $c->query_param('foo'), 'second', "$type: query_param gives the last value";
        is $c->query_param('name'), 'John Doe', "$type: query_param percent-decodes";
        is $c->query_param('emoji'), "\x{1F525}", "$type: query_param decodes UTF-8";
        is $c->query_param('missing'), undef, "$type: a missing query_param is undef";
        is $c->raw_query_param('emoji'), "\xF0\x9F\x94\xA5",
            "$type: raw_query_param skips UTF-8 decoding";
        is $c->raw_query_params->get('emoji'), "\xF0\x9F\x94\xA5",
            "$type: raw_query_params skips UTF-8 decoding";

        is $c->path_params, { id => '42' }, "$type: path_params";
        is $c->path_param('id'), '42', "$type: path_param";

        is $c->cookies, { session => 'abc123', theme => 'dark' }, "$type: cookies";
        is $c->cookie('session'), 'abc123', "$type: cookie";
        is $c->cookie('missing'), undef, "$type: a missing cookie is undef";

        is $c->has_state, 1, "$type: has_state with application state";
        isa_ok $c->state, ['PAGI::State'], "$type: state";
        is $c->state->get('db'), 'handle', "$type: state reads application state";
    }
};

subtest 'query options' => sub {
    my $c = PAGI::HTTPConnection->new({ type => 'http', query_string => 'bad=%FF' });
    is $c->query_param('bad'), "\x{FFFD}", 'invalid UTF-8 is replaced by default';
    like dies { $c->query_params(strict => 1) }, qr/UTF-8|malformed/i,
        'strict dies on invalid UTF-8';
    is $c->query_param('bad', raw => 1), "\xFF", 'raw keeps the bytes';
    like dies { $c->query_params(bogus => 1) }, qr/Unknown options to query_params: bogus/,
        'an unknown option croaks';

    my $empty = PAGI::HTTPConnection->new({ type => 'http' });
    is $empty->query_string, '', 'query_string defaults to empty';
    isa_ok $empty->query_params, ['Hash::MultiValue'], 'query_params with no query string';
};

subtest 'every parse is cached on the object' => sub {
    my $c = PAGI::HTTPConnection->new(full_scope('http'));
    is refaddr($c->headers), refaddr($c->headers), 'headers';
    is refaddr($c->query_params), refaddr($c->query_params), 'query_params';
    is refaddr($c->query_params(raw => 1)), refaddr($c->raw_query_params), 'raw query_params';
    is refaddr($c->query_params(strict => 1)), refaddr($c->query_params(strict => 1)),
        'strict query_params';
    isnt refaddr($c->query_params), refaddr($c->raw_query_params),
        'decoded and raw query are cached apart';
    isnt refaddr($c->query_params), refaddr($c->query_params(strict => 1)),
        'lenient and strict query are cached apart';
    is refaddr($c->cookies), refaddr($c->cookies), 'cookies';

    $c->headers->set('X-Added', 'yes');
    is $c->header('x-added'), 'yes', 'header reads the cached headers object';
};

subtest 'nothing is written to the scope' => sub {
    for my $type (qw(http websocket sse)) {
        my $scope = full_scope($type);
        my %before = %$scope;
        my @headers_before = map { [@$_] } @{ $scope->{headers} };
        my $c = PAGI::HTTPConnection->new($scope);

        $c->$_ for qw(scope connection client server scheme http_version path raw_path
            raw_path_info request_uri query_string headers query_params
            raw_query_params path_params cookies state has_state);
        $c->header('accept');
        $c->header_all('accept');
        $c->query_param('foo');
        $c->query_params(strict => 1);
        $c->raw_query_param('foo');
        $c->path_param('id');
        $c->cookie('session');
        $c->state->get('db');

        is [sort keys %$scope], [sort keys %before], "$type: no key added or removed";
        is $scope->{headers}, \@headers_before, "$type: headers unchanged";
        is $scope->{$_}, $before{$_}, "$type: $_ unchanged"
            for grep { !ref $before{$_} } keys %before;
    }
};

subtest 'new' => sub {
    like dies { PAGI::HTTPConnection->new({ type => 'lifespan' }) },
        qr/requires HTTP, WebSocket, or SSE scope; received 'lifespan'/,
        'croaks on a lifespan scope';
    like dies { PAGI::HTTPConnection->new({ headers => [] }) },
        qr/scope type is required/, 'croaks without a type';
    like dies { PAGI::HTTPConnection->new([]) },
        qr/requires an unblessed scope hashref/, 'croaks on an arrayref';
    like dies { PAGI::HTTPConnection->new(undef) },
        qr/requires an unblessed scope hashref/, 'croaks on undef';
    like dies { PAGI::HTTPConnection->new(bless {type => 'http'}, 'Local::Scope') },
        qr/requires an unblessed scope hashref/, 'croaks on a blessed hash';
    like dies { PAGI::HTTPConnection->new({ type => 'http' }, sub {}) },
        qr/requires exactly one scope argument/, 'croaks on a second argument';

    my $c = PAGI::HTTPConnection->new({ type => 'http' });
    isa_ok $c, ['PAGI::HTTPConnection'], 'works without pagi.connection';
    is $c->connection, undef, 'connection is undef without pagi.connection';
    is $c->client, undef, 'client is undef when absent';
    is $c->server, undef, 'server is undef when absent';
    is $c->http_version, '1.1', 'http_version defaults to 1.1';
};

subtest 'scheme' => sub {
    my $scheme_of = sub { PAGI::HTTPConnection->new($_[0])->scheme };
    is $scheme_of->({ type => 'websocket' }), 'ws', 'ws for a websocket scope with no scheme';
    is $scheme_of->({ type => 'http' }), 'http', 'http for an http scope with no scheme';
    is $scheme_of->({ type => 'sse' }), 'http', 'http for an sse scope with no scheme';
    is $scheme_of->({ type => 'websocket', scheme => 'wss' }), 'wss',
        'the scope scheme for a websocket';
    is $scheme_of->({ type => 'sse', scheme => 'https' }), 'https', 'the scope scheme for sse';
};

subtest 'D2: a scope with no path' => sub {
    my $none = PAGI::HTTPConnection->new({ type => 'http', query_string => 'x=1' });
    like dies { $none->path }, qr/\Athis scope has no path at .*http-connection\.t line /,
        'path dies when read, naming the caller';
    like dies { $none->raw_path }, qr/\Athis scope has no path at .*http-connection\.t line /,
        'raw_path dies without raw_path or path';
    like dies { $none->request_uri }, qr/\Athis scope has no path at .*http-connection\.t line /,
        'request_uri dies without raw_path or path';

    my $raw_only = PAGI::HTTPConnection->new({ type => 'http', raw_path => '/a%2Fb',
        query_string => 'x=1' });
    like dies { $raw_only->path }, qr/this scope has no path/,
        'path dies when only raw_path is present';
    is $raw_only->raw_path, '/a%2Fb', 'raw_path as sent';
    is $raw_only->request_uri, '/a%2Fb?x=1', 'request_uri from raw_path';

    my $path_only = PAGI::HTTPConnection->new({ type => 'websocket', path => '/a b',
        root_path => '/m', query_string => 'x=1' });
    is $path_only->raw_path, '/m/a%20b', 'raw_path rebuilt from root_path and path';
    is $path_only->request_uri, '/m/a%20b?x=1', 'request_uri rebuilt from path';
};

subtest 'D3: path parameters' => sub {
    my $c = PAGI::HTTPConnection->new({ type => 'sse',
        path_params => { userId => 1, postId => 2 } });
    like dies { $c->path_param('nope') },
        qr/path_param 'nope' not found\. Available: postId, userId/,
        'a missing name dies naming the available names';
    is $c->path_param('nope', strict => 0), undef, 'strict => 0 gives undef';
    like dies { $c->path_param('userId', bogus => 1) },
        qr/Unknown options to path_param: bogus/, 'an unknown option croaks';

    my $none = PAGI::HTTPConnection->new({ type => 'websocket' });
    is $none->path_params, {}, 'path_params is {} without a router';
    like dies { $none->path_params(strict => 1) },
        qr/path_params not set in scope/, 'path_params strict => 1 dies without a router';
    like dies { $none->path_param('id') }, qr/path_param 'id' not found\. No path params set/,
        'path_param dies without a router';

    {
        package Local::LenientConnection;
        our @ISA = ('PAGI::HTTPConnection');
        sub _default_path_param_strict_opt { return 0 }
    }
    my $lenient = Local::LenientConnection->new({ type => 'http', path_params => {} });
    is $lenient->path_param('nope'), undef,
        'a subclass overriding _default_path_param_strict_opt is lenient';
};

subtest 'D5/D5b: cookies' => sub {
    my $cookies_of = sub {
        my (@fields) = @_;
        return PAGI::HTTPConnection->new({ type => 'http',
            headers => [map { ['Cookie', $_] } @fields] })->cookies;
    };

    is $cookies_of->('cart=sku1,sku2; theme=dark'), { cart => 'sku1,sku2', theme => 'dark' },
        'split on ";" only: a comma stays in the value';
    is $cookies_of->('a="x y"'), { a => 'x y' }, 'a quoted value is unquoted';
    is $cookies_of->('a=x%2Fy'), { a => 'x%2Fy' }, 'no percent-decoding';
    is $cookies_of->('a=1; a=2'), { a => '2' }, 'a repeated name: the last wins';
    is $cookies_of->('a=1', 'b=2'), $cookies_of->('a=1; b=2'),
        'two Cookie fields read as one field';
    is $cookies_of->('a=1', 'b=2'), { a => '1', b => '2' }, 'every Cookie field is read';
    is $cookies_of->('a=1', 'a=2'), { a => '2' }, 'the last wins across fields';
};

subtest 'no headers' => sub {
    for my $case ([{ type => 'http' }, 'no headers key'],
                  [{ type => 'http', headers => [] }, 'headers => []']) {
        my ($scope, $name) = @$case;
        my $c = PAGI::HTTPConnection->new($scope);
        is warnings {
            isa_ok $c->headers, ['PAGI::Headers'], "$name: headers";
            is $c->header('cookie'), undef, "$name: header is undef";
            is [$c->header_all('cookie')], [], "$name: header_all is empty";
            is $c->cookies, {}, "$name: cookies is empty";
        }, [], "$name: no warnings";
    }
};

subtest 'state' => sub {
    my $c = PAGI::HTTPConnection->new({ type => 'http' });
    is $c->has_state, 0, 'has_state is false without application state';
    isa_ok $c->state, ['PAGI::State'], 'state is a facade without application state';

    my $bad = PAGI::HTTPConnection->new({ type => 'http', state => [] });
    like dies { $bad->has_state }, qr/PAGI::HTTPConnection state must be a hashref/,
        'malformed state croaks naming the class';
};

subtest 'an object built on a rewritten copy sees the rewrite' => sub {
    my $scope = full_scope('http');
    my $original = PAGI::HTTPConnection->new($scope);
    is $original->cookie('session'), 'abc123', 'the original reads the original';

    my $copy = { %$scope, headers => [['Cookie', 'session=rewritten'], ['X-Added', 'yes']] };
    my $rewritten = PAGI::HTTPConnection->new($copy);
    is $rewritten->cookie('session'), 'rewritten', 'the copy reads its rewritten Cookie';
    is $rewritten->header('x-added'), 'yes', 'the copy reads its rewritten headers';
    is $original->cookie('session'), 'abc123', 'the original is unaffected';
    is $original->header('x-added'), undef, 'the original headers are unaffected';
};

done_testing;
