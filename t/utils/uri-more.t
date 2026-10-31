use strict;
use warnings;
use utf8;
use Test2::V0;
use lib 'lib';
use PAGI::Utils::URI;

# The nice-to-have methods of a PAGI::Utils::URI and is_equivalent. eq stays
# strict; is_equivalent is RFC 3986 6.2.2 on scheme, authority and path, and
# compares the decoded query parameters.

sub uri { PAGI::Utils::URI->parse(@_) }

subtest 'add_query appends and removes nothing' => sub {
    my $uri = uri('http://h/p?x=1&x=2');
    is("" . $uri->add_query(x => 3, y => 'a b'), 'http://h/p?x=1&x=2&x=3&y=a+b',
        'existing pairs stay, new ones go at the end, form-encoded');
    is("" . $uri->add_query(tag => [qw(a b)], gone => undef), 'http://h/p?x=1&x=2&tag=a&tag=b',
        'an arrayref repeats the name; undef adds nothing');
    is("" . uri('http://h/?q=red%20shoes;flag')->add_query(n => 1), 'http://h/?q=red+shoes&flag=&n=1',
        'the client pairs are written form-encoded, a bare name as name=');
    is("" . uri('http://h/')->add_query(k => "caf\x{e9}"), 'http://h/?k=caf%C3%A9', 'text is UTF-8 encoded');
    is("$uri", 'http://h/p?x=1&x=2', 'the original is unchanged');
    like(dies { $uri->add_query('x') }, qr/add_query takes name => value pairs/, 'an odd list dies');
};

subtest 'path_query is raw_path and the query' => sub {
    is(uri('http://h/a%2Fb?x=1&y=2')->path_query, '/a%2Fb?x=1&y=2', 'path and query');
    is(uri('http://h/a')->path_query, '/a', 'no query, no ?');
    is(uri('http://h//evil.example/x?q=1')->path_query, '/evil.example/x?q=1', 'never starts with //');
    is(uri('http://h/a')->replace(raw_path => '//evil.example/')->path_query, '/evil.example/',
        'an edited path is held to one leading slash');
    is(uri('http://h///evil.example/x')->path_query, '/evil.example/x', 'any run of leading slashes becomes one');
    is(uri('http://h/a//b')->path_query, '/a//b', 'a // later in the path is kept');
    like(dies { uri('http://h/')->path_query(1) }, qr/path_query takes no arguments/, 'a reader takes none');
};

subtest 'path_segments reads decoded segments from raw_path' => sub {
    is([uri('http://h/a%2Fb/c')->path_segments], ['a/b', 'c'], 'an encoded / stays inside its segment');
    is([uri('http://h/')->path_segments], [], 'the root has none');
    is([uri('http://h/a/')->path_segments], ['a', ''], 'a trailing slash is a final empty segment');
    is([uri('http://h//a')->path_segments], ['a'], 'a leading // gives no empty first segment');
    is([uri('http://h/caf%C3%A9/a%20b')->path_segments], ["caf\x{e9}", 'a b'], 'decoded text');
};

subtest 'replace(path_segments => ...) encodes each segment' => sub {
    my $uri = uri('http://h/old?x=1');
    is("" . $uri->replace(path_segments => ['a/b', 'c']), 'http://h/a%2Fb/c?x=1',
        'a / inside a segment stays %2F; the query is kept');
    is("" . $uri->replace(path_segments => ["caf\x{e9}", 'a b']), 'http://h/caf%C3%A9/a%20b?x=1', 'text encoded');
    is("" . $uri->replace(path_segments => []), 'http://h/?x=1', 'no segments is the root');
    is("" . $uri->replace(path_segments => ['', 'evil.example', 'x']), 'http://h/evil.example/x?x=1',
        'an empty first segment cannot start the path with //');
    like(dies { $uri->replace(path_segments => 'a', path => '/b') }, qr/replace takes path_segments, or path or raw_path, not both/,
        'not with path');
    like(dies { $uri->replace(path_segments => 'a') }, qr/path_segments must be an arrayref/, 'an arrayref is required');
};

subtest 'join_path appends encoded segments' => sub {
    my $uri = uri('http://h/app/items?x=1');
    is("" . $uri->join_path(42, 'a/b'), 'http://h/app/items/42/a%2Fb?x=1', 'text segments appended, query kept');
    is("" . uri('http://h/app/')->join_path('x'), 'http://h/app/x', 'a trailing slash is not doubled');
    is("" . uri('http://h/')->join_path('x'), 'http://h/x', 'from the root');
    is("" . uri('http://h/%FF')->join_path('x'), 'http://h/%FF/x', 'existing bytes are kept as they were');
    is("" . uri('http://h/a')->join_path('', 'evil.example'), 'http://h/a//evil.example',
        'an empty segment is an empty segment, after the first');
    is("" . uri('http://h/')->join_path('', 'evil.example'), 'http://h/evil.example',
        'but the path never starts with //');
    is("$uri", 'http://h/app/items?x=1', 'the original is unchanged');
};

subtest 'is_secure and origin' => sub {
    ok(uri('https://h/')->is_secure, 'https');
    ok(uri('wss://h/')->is_secure, 'wss');
    ok(!uri('http://h/')->is_secure, 'http');
    ok(!uri('ws://h/')->is_secure, 'ws');
    is(uri('https://example.com:8443/a?b#c')->origin, 'https://example.com:8443', 'scheme://authority');
    is(uri('http://example.com/a')->origin, 'http://example.com', 'no port, none shown');
    is(PAGI::Utils::URI->from_scope({
        type => 'http', scheme => 'http', path => '/', raw_path => '/', query_string => '',
        headers => [['host', 'evil.com/x?']],
    })->origin, 'http://evil.com%2Fx%3F', 'a hostile Host stays escaped');
};

subtest 'is_equivalent: RFC 3986 6.2.2 on scheme, authority and path' => sub {
    ok(uri('HTTP://Example.COM:80/%7Ea')->is_equivalent(uri('http://example.com/~a')),
        'scheme and host case, default port, unreserved escape');
    ok(uri('http://h/%7ea%2fb')->is_equivalent(uri('http://h/~a%2Fb')), 'escape case; an encoded / stays');
    ok(!uri('http://h/a%2Fb')->is_equivalent(uri('http://h/a/b')), 'an encoded / is not a /');
    ok(uri('http://h:0080/')->is_equivalent(uri('http://h/')), 'leading zeros: :0080 is the default for http');
    ok(uri('https://h:443/')->is_equivalent(uri('https://h/')), 'https default');
    ok(!uri('https://h:80/')->is_equivalent(uri('https://h/')), 'port 80 is not https default');
    ok(!uri('http://h:8080/')->is_equivalent(uri('http://h/')), 'other port differs');
    ok(!uri('http://h/a')->is_equivalent(uri('http://h/b')), 'different path');
    ok(!uri('http://h//evil/x')->is_equivalent(uri('http://h/evil/x')), 'a leading // is part of the path');
    ok(!uri('http://h/a')->is_equivalent(uri('https://h/a')), 'different scheme');
    ok(!uri('http://h/A')->is_equivalent(uri('http://h/a')), 'the path is case sensitive');
    ok(!uri('http://h/#a')->is_equivalent(uri('http://h/#b')), 'different fragment');
    like(dies { uri('http://h/')->is_equivalent('http://h/') }, qr/is_equivalent requires a PAGI::Utils::URI/,
        'only another URI');
};

subtest 'is_equivalent: decoded query parameters, order kept' => sub {
    ok(uri('http://h/?q=red+shoes')->is_equivalent(uri('http://h/?q=red%20shoes')), 'plus and %20');
    ok(uri('http://h/?a=%7e')->is_equivalent(uri('http://h/?a=~')), 'escape spelling');
    ok(uri('http://h/?a=1;b=2')->is_equivalent(uri('http://h/?a=1&b=2')), 'separator');
    ok(uri('http://h/?flag')->is_equivalent(uri('http://h/?flag=')), 'a bare name is name=');
    ok(!uri('http://h/?a=1&b=2')->is_equivalent(uri('http://h/?b=2&a=1')), 'order is not normalised');
    ok(!uri('http://h/?a=1&a=2')->is_equivalent(uri('http://h/?a=2&a=1')), 'value order is not normalised');
    ok(!uri('http://h/?a=1')->is_equivalent(uri('http://h/')), 'a missing query differs');
};

subtest 'eq stays strict' => sub {
    ok(uri('HTTP://Example.COM:80/%7Ea') ne uri('http://example.com/~a'), 'scheme, host, port and escapes');
    ok(uri('http://h/?q=red+shoes') ne uri('http://h/?q=red%20shoes'), 'the query spelling');
    ok(uri('http://h/?a=1&b=2') ne uri('http://h/?b=2&a=1'), 'the order');
    ok(uri('http://h/?a=1') eq uri('http://h/?a=1'), 'identical strings');
};

done_testing;
