use strict;
use warnings;
use utf8;
use Test2::V0;
use lib 'lib';
use PAGI::Utils::Scope;
use PAGI::Utils::URI;

# PAGI::Utils::URI is the request's URL as an immutable value: the Host as
# the client sent it (never validated), escaped on output so it cannot
# change the path or query, and the path and query exactly as request_uri
# gives them.

sub http_scope {
    my (%fields) = @_;
    return {
        type         => 'http',
        scheme       => 'http',
        root_path    => '',
        path         => '/',
        raw_path     => '/',
        query_string => '',
        server       => ['127.0.0.1', 5000],
        %fields,
    };
}

sub uri_for { PAGI::Utils::URI->from_scope(http_scope(@_)) }

subtest 'a hostile Host cannot change the path or query' => sub {
    my $uri = uri_for(
        headers      => [['host', 'evil.com/x?']],
        path         => '/items',
        raw_path     => '/items',
        query_string => 'page=1',
    );
    is("$uri", 'http://evil.com%2Fx%3F/items?page=1', 'the string form escapes the Host');
    is($uri->to_string, "$uri", 'to_string is the string form');
    is($uri->host, 'evil.com/x?', 'host is the Host, unvalidated');
    is($uri->authority, 'evil.com/x?', 'authority is the Host, unvalidated');
    is($uri->raw_path, '/items', 'the path is the request path');
    is($uri->query_string, 'page=1', 'the query is the request query');

    is("" . uri_for(headers => [['host', 'a b@c#d']]), 'http://a%20b%40c%23d/',
        'a space, @ and # in a Host are escaped');
    is("" . uri_for(headers => [['host', "x-._~!\$&'()*+,;=y"]]), "http://x-._~!\$&'()*+,;=y/",
        'what Mojo::URL allows in an authority stays');
    my $escaped = uri_for(headers => [['host', 'a%41']]);
    is($escaped->host, 'aA', 'a %XX in a Host is unescaped, as Mojolicious reads a Host');
    is("$escaped", 'http://aA/', 'and written as the character when it is allowed');
    $escaped = uri_for(headers => [['host', 'evil.com%2Fx']], path => '/items', raw_path => '/items');
    is($escaped->host, 'evil.com/x', 'an escaped / in a Host reads as /');
    is("$escaped", 'http://evil.com%2Fx/items', 'and is escaped again on output, so it stays in the authority');
    is("" . uri_for(headers => [['host', 'caf%C3%A9.example']]), 'http://caf%C3%A9.example/',
        'an escaped non-ASCII byte is escaped again');
    is("" . uri_for(headers => [['host', "caf\xC3\xA9.example"]]), 'http://caf%C3%A9.example/',
        'a non-ASCII Host byte is escaped');
};

subtest 'the Host header: a trailing :digits is the port' => sub {
    my $uri = uri_for(headers => [['Host', 'example.com:8080']]);
    is($uri->host, 'example.com', 'host');
    is($uri->port, '8080', 'port');
    is($uri->authority, 'example.com:8080', 'authority');
    is("$uri", 'http://example.com:8080/', 'string');

    $uri = uri_for(headers => [['host', 'example.com']]);
    is($uri->port, undef, 'no port in the Host: port is undef');
    is("$uri", 'http://example.com/', 'string');

    $uri = uri_for(headers => [['host', 'example.com:80']]);
    is($uri->port, '80', 'an explicit default port is kept');
    is("$uri", 'http://example.com:80/', 'and shown');

    $uri = uri_for(headers => [['host', '[::1]:8080']]);
    is($uri->host, '[::1]', 'an IPv6 Host keeps its brackets');
    is($uri->port, '8080', 'and its port');
    is("$uri", 'http://[::1]:8080/', 'string');

    $uri = uri_for(headers => [['host', '[::1]']]);
    is($uri->host, '[::1]', 'an IPv6 Host without a port');
    is($uri->port, undef, 'has no port');
    is("$uri", 'http://[::1]/', 'string');
};

subtest 'a repeated Host reads joined, as header does' => sub {
    my $uri = uri_for(headers => [['host', 'a.com'], ['Host', 'b.com']]);
    is($uri->host, 'a.com, b.com', 'joined with ", "');
    is("$uri", 'http://a.com,%20b.com/', 'escaped on output');
};

subtest 'without a Host, the server address, the default port dropped' => sub {
    my $uri = uri_for(server => ['10.0.0.5', 80], path => '/x', raw_path => '/x');
    is("$uri", 'http://10.0.0.5/x', 'http on 80');
    is($uri->port, undef, 'no explicit port');

    $uri = uri_for(server => ['10.0.0.5', 8080]);
    is("$uri", 'http://10.0.0.5:8080/', 'http on 8080');
    is($uri->port, '8080', 'the port is shown, so it is explicit');

    is("" . uri_for(scheme => 'https', server => ['10.0.0.5', 443]), 'https://10.0.0.5/', 'https on 443');
    is("" . uri_for(scheme => 'https', server => ['10.0.0.5', 80]), 'https://10.0.0.5:80/', 'https on 80');
    is("" . uri_for(server => ['::1', 8080]), 'http://[::1]:8080/', 'an IPv6 server address is bracketed');
    is("" . uri_for(headers => [['host', '']], server => ['10.0.0.5', 80]), 'http://10.0.0.5/',
        'an empty Host is no Host');

    is("" . PAGI::Utils::URI->from_scope({ type => 'websocket', scheme => 'wss', path => '/', server => ['10.0.0.5', 443] }),
        'wss://10.0.0.5/', 'wss on 443');
    is("" . PAGI::Utils::URI->from_scope({ type => 'websocket', path => '/', server => ['10.0.0.5', 80] }),
        'ws://10.0.0.5/', 'ws (the websocket default) on 80');

    like(dies { uri_for(server => undef) }, qr/\Ano Host header, and the scope server cannot provide an authority at .*uri\.t line /,
        'neither a Host nor a server address dies, naming the caller');
    like(dies { PAGI::Utils::URI->from_scope({ type => 'http' }) }, qr/\Athis scope has no path at .*uri\.t line /,
        'nor a path');
};

subtest 'scheme' => sub {
    my $scope = { type => 'websocket', scheme => 'wss', path => '/chat', headers => [['host', 'example.com']] };
    my $uri = PAGI::Utils::URI->from_scope($scope);
    is($uri->scheme, 'wss', 'the scope scheme');
    is("$uri", 'wss://example.com/chat', 'a websocket scope with scheme wss');

    delete $scope->{scheme};
    is(PAGI::Utils::URI->from_scope($scope)->scheme, 'ws', 'a websocket scope without one is ws');
    is(PAGI::Utils::URI->from_scope({ type => 'sse', path => '/', headers => [['host', 'example.com']] })->scheme,
        'http', 'an sse scope without one is http');
};

subtest 'paths: path is decoded text, raw_path escaped bytes, both with the root path' => sub {
    my $uri = uri_for(headers => [['host', 'example.com']], root_path => '/app', path => '/café', raw_path => undef);
    is($uri->path, '/app/café', 'path');
    is($uri->raw_path, '/app/caf%C3%A9', 'raw_path');
    is("$uri", 'http://example.com/app/caf%C3%A9', 'string');

    $uri = uri_for(path => '/a/b', raw_path => '/a%2Fb');
    is($uri->path, '/a/b', 'path is decoded');
    is($uri->raw_path, '/a%2Fb', 'an encoded / stays encoded in raw_path');

    $uri = uri_for(root_path => '/app', path => '/café', raw_path => "/app/caf\xC3\xA9");
    is($uri->path, '/app/café', 'path from root_path and path');
    is($uri->raw_path, '/app/caf%C3%A9', 'the client bytes, escaped');

    $uri = uri_for(path => '//evil.example/x', raw_path => '//evil.example/x');
    is($uri->raw_path, '//evil.example/x', 'a leading // is kept, as sent');
    is($uri->path, '//evil.example/x', 'path agrees with raw_path');
    is($uri->path_query, '/evil.example/x', 'path_query alone is held to one leading /');
};

subtest 'from_scope: a request for //evil/x keeps the // in the value' => sub {
    my $uri = uri_for(headers => [['host', 'h']], path => '//evil/x', raw_path => '//evil/x', query_string => 'a=1');
    is("$uri", 'http://h//evil/x?a=1', 'the string form');
    is($uri->path, '//evil/x', 'path');
    is($uri->raw_path, '//evil/x', 'raw_path');
    is($uri->path_query, '/evil/x?a=1', 'path_query');
    is(PAGI::Utils::Scope::request_uri(http_scope(path => '//evil/x', raw_path => '//evil/x', query_string => 'a=1')),
        '/evil/x?a=1', 'request_uri stays collapsed');
    ok(!$uri->is_equivalent(uri_for(headers => [['host', 'h']], path => '/evil/x', raw_path => '/evil/x', query_string => 'a=1')),
        'not equivalent to the single-slash path');
    is(uri_for(headers => [['host', 'h']], root_path => '/', path => '/x', raw_path => undef)->raw_path, '//x',
        'a root path rebuilt without raw_path is not collapsed either');
};

subtest 'an unedited value stringifies to scheme://authority + the exact request_uri' => sub {
    my @scopes = (
        http_scope(path => '/reports', raw_path => '/reports', query_string => 'x=1'),
        http_scope(root_path => '/admin', path => '/users', raw_path => '/admin/users'),
        http_scope(root_path => '/café', path => '/menu é', raw_path => undef, query_string => 'q=1'),
        http_scope(path => '/x', raw_path => '/x', query_string => "a=1\x0D\x0Ab"),
        http_scope(path => '/s', raw_path => '/s', query_string => 'q={"x":1}|a^b<c>[d]#e'),
        http_scope(path => '/a?b', raw_path => '/a?b', query_string => 'q=1'),
        http_scope(path => '/café', raw_path => "/caf\xC3\xA9", query_string => "q=\x{263A}"),
        http_scope(path => '/s', raw_path => '/s', query_string => "a=1&b=x:y/z?w;v=(1)!*'+,\$\@~%2F"),
    );
    for my $scope (@scopes) {
        $scope->{headers} = [['host', 'example.com']];
        my $request_uri = PAGI::Utils::Scope::request_uri($scope);
        is("" . PAGI::Utils::URI->from_scope($scope), "http://example.com$request_uri", $request_uri);
    }
};

subtest 'query_string, query_params, raw_query_params' => sub {
    my $uri = uri_for(query_string => 'q=caf%C3%A9&q=x+y&b&bad=%FF');
    is($uri->query_string, 'q=caf%C3%A9&q=x+y&b&bad=%FF', 'query_string');

    my $params = $uri->query_params;
    isa_ok($params, 'Hash::MultiValue');
    is([$params->get_all('q')], ['café', 'x y'], 'decoded text, every value');
    is($params->get('b'), '', 'a bare key reads as ""');
    is($params->get('bad'), "\x{FFFD}", 'invalid UTF-8 is replaced');
    $params->add(q => 'added');
    is([$uri->query_params->get_all('q')], ['café', 'x y'], 'a change to the returned params does not reach the value');

    my $raw = $uri->raw_query_params;
    is([$raw->get_all('q')], ["caf\xC3\xA9", 'x y'], 'raw_query_params are bytes');
    is($raw->get('bad'), "\xFF", 'undecoded');

    $uri = uri_for(query_string => '');
    is($uri->query_string, '', 'no query: ""');
    is([$uri->query_params->keys], [], 'no params');
    unlike("$uri", qr/\?/, 'and no ? in the string');
};

subtest 'fragment is "" for a request' => sub {
    is(uri_for()->fragment, '', 'fragment');
};

subtest 'eq is strict byte equality' => sub {
    my $scope = http_scope(headers => [['host', 'example.com']], query_string => 'a=1');
    ok(PAGI::Utils::URI->from_scope($scope) eq PAGI::Utils::URI->from_scope($scope), 'the same request');
    ok(PAGI::Utils::URI->from_scope($scope) eq 'http://example.com/?a=1', 'against a string');
    ok(uri_for(headers => [['host', 'Example.COM']]) ne uri_for(headers => [['host', 'example.com']]),
        'the Host spelling counts');
};

subtest 'immutable' => sub {
    my $scope = http_scope(headers => [['host', 'example.com']], path => '/a', raw_path => '/a', query_string => 'x=1');
    my $uri = PAGI::Utils::URI->from_scope($scope);
    $scope->{path} = $scope->{raw_path} = '/b';
    $scope->{query_string} = 'x=2';
    $scope->{headers} = [['host', 'other.example']];
    is("$uri", 'http://example.com/a?x=1', 'a later change to the scope does not reach the value');
    is($uri->path, '/a', 'nor its path');

    for my $reader (qw(scheme authority host port path raw_path query_string query_params raw_query_params fragment)) {
        like(dies { $uri->$reader('changed') }, qr/\A$reader takes no arguments/, "$reader takes no value");
    }
    is("$uri", 'http://example.com/a?x=1', 'unchanged');
    like(dies { $uri->query_params(strict => 1) }, qr/\Aquery_params takes no arguments: .*no options/,
        'an option to query_params is refused as an option');
};

subtest 'parse' => sub {
    my $uri = PAGI::Utils::URI->parse('https://example.com:8443/a%2Fb/caf%C3%A9?x=1&y=caf%C3%A9#top');
    is($uri->scheme, 'https', 'scheme');
    is($uri->host, 'example.com', 'host');
    is($uri->port, '8443', 'port');
    is($uri->authority, 'example.com:8443', 'authority');
    is($uri->raw_path, '/a%2Fb/caf%C3%A9', 'raw_path');
    is($uri->path, '/a/b/café', 'path decoded as the server decodes it');
    is($uri->query_string, 'x=1&y=caf%C3%A9', 'query_string');
    is($uri->query_params->get('y'), 'café', 'query_params');
    is($uri->fragment, 'top', 'fragment');
    is("$uri", 'https://example.com:8443/a%2Fb/caf%C3%A9?x=1&y=caf%C3%A9#top', 'string');

    my $hostile = uri_for(headers => [['host', 'evil.com/x? %41']], path => '/items', raw_path => '/items');
    is($hostile->host, 'evil.com/x? A', 'a Host as unescaped');
    my $again = PAGI::Utils::URI->parse("$hostile");
    is($again->host, 'evil.com/x? A', 'the string form parses back to the same host');
    ok($again eq $hostile, 'and stringifies the same');

    my $colon = uri_for(headers => [['host', 'a%3A80']]);
    is([$colon->host, $colon->port, "$colon"], ['a:80', undef, 'http://a:80/'], 'Host: a%3A80 has the host a:80');
    my $reparsed = PAGI::Utils::URI->parse("$colon");
    is([$reparsed->host, $reparsed->port], ['a', '80'], 'its string form parses to the host a and the port 80');
    ok($reparsed eq $colon, 'with the same string form');

    is(PAGI::Utils::URI->parse('http://example.com/%FF')->path, "/\xFF", 'a path that is not UTF-8 stays bytes');
    is("" . PAGI::Utils::URI->parse('http://example.com/a b?c d#e f'), 'http://example.com/a%20b?c%20d#e%20f',
        'what a URI cannot hold is escaped');
    is("" . PAGI::Utils::URI->parse('http://example.com'), 'http://example.com', 'an empty path stays empty');
    is(PAGI::Utils::URI->parse('http://example.com')->fragment, '', 'no fragment: ""');

    like(dies { PAGI::Utils::URI->parse('/items?x=1') }, qr/not an absolute URI/, 'a relative reference dies');
    like(dies { PAGI::Utils::URI->parse('mailto:a@example.com') }, qr/not an absolute URI/, 'so does one without an authority');
    like(dies { PAGI::Utils::URI->parse(undef) }, qr/not an absolute URI/, 'and undef');
};

subtest 'parse takes characters: every non-ASCII character is UTF-8 encoded' => sub {
    my %cases = (
        'a path, alone'                => ["http://example.com/caf\x{e9}",            'http://example.com/caf%C3%A9'],
        'a path, beside a wide char'   => ["http://example.com/caf\x{e9}\x{263A}",    'http://example.com/caf%C3%A9%E2%98%BA'],
        'a query, alone'               => ["http://example.com/?q=caf\x{e9}",         'http://example.com/?q=caf%C3%A9'],
        'a query, beside a wide char'  => ["http://example.com/?q=caf\x{e9}\x{263A}", 'http://example.com/?q=caf%C3%A9%E2%98%BA'],
        'a host, alone'                => ["http://caf\x{e9}.example/",               'http://caf%C3%A9.example/'],
        'a host, beside a wide char'   => ["http://caf\x{e9}\x{263A}.example/",       'http://caf%C3%A9%E2%98%BA.example/'],
        'a fragment'                   => ["http://example.com/#caf\x{e9}",           'http://example.com/#caf%C3%A9'],
        'pre-escaped stays'            => ['http://caf%C3%A9.example/caf%C3%A9?q=caf%C3%A9#caf%C3%A9',
                                           'http://caf%C3%A9.example/caf%C3%A9?q=caf%C3%A9#caf%C3%A9'],
    );
    for my $label (sort keys %cases) {
        my ($in, $out) = @{ $cases{$label} };
        is("" . PAGI::Utils::URI->parse($in), $out, $label);
    }
    my $uri = PAGI::Utils::URI->parse("http://example.com/caf\x{e9}?q=caf\x{e9}");
    is($uri->path, '/café', 'path reads the character back');
    is($uri->query_params->get('q'), 'café', 'so does the query');
};

subtest 'parse keeps the path as sent, a leading // included' => sub {
    for my $string ('http://h//evil.example/x?q=1', 'http://h///evil.example/x?q=1') {
        my $uri = PAGI::Utils::URI->parse($string);
        my ($path) = $string =~ m{\Ahttp://h(/[^?]*)};
        is($uri->raw_path, $path, "$string: raw_path");
        is($uri->path, $path, "$string: path");
        is("$uri", $string, "$string: the string form");
        like($uri->path_query, qr{\A/[^/]}, "$string: path_query starts with one /");
    }
    my $uri = PAGI::Utils::URI->parse('http://h//evil/x?a=1');
    is("$uri", 'http://h//evil/x?a=1', 'the string form parses back');
    is($uri->path_query, '/evil/x?a=1', 'path_query');
    my $scope_uri = uri_for(path => '//evil.example/x', raw_path => '//evil.example/x');
    is(PAGI::Utils::URI->parse('http://127.0.0.1:5000//evil.example/x')->raw_path, $scope_uri->raw_path,
        'the same path as from_scope gives for that request');
    is(PAGI::Utils::URI->parse('http://h/a//b')->raw_path, '/a//b', 'a // later in the path is kept');
};

subtest 'parse refuses userinfo' => sub {
    like(dies { PAGI::Utils::URI->parse('http://user:pw@host.example/x') }, qr/\Auserinfo is not supported at .*uri\.t line /,
        'user and password');
    like(dies { PAGI::Utils::URI->parse('http://user@host.example/x') }, qr/\Auserinfo is not supported/, 'a user alone');
    is(PAGI::Utils::URI->parse('http://user%40host.example/x')->host, 'user@host.example',
        'an escaped @ is part of the host');
};

subtest 'from_scope requires an http, websocket or sse scope' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    like(dies { PAGI::Utils::URI->from_scope({ path => '/', headers => [['host', 'example.com']] }) },
        qr/\APAGI::Utils::URI scope type is required at .*uri\.t line /, 'no type');
    like(dies { PAGI::Utils::URI->from_scope({ type => 'lifespan', path => '/', headers => [['host', 'example.com']] }) },
        qr/\APAGI::Utils::URI requires HTTP, WebSocket, or SSE scope; received 'lifespan' at .*uri\.t line /, 'lifespan');
    is(\@warnings, [], 'and no warnings');
};

done_testing;
