use strict;
use warnings;
use utf8;
use Test2::V0;
use Scalar::Util qw(refaddr);
use Hash::MultiValue;
use lib 'lib';
use PAGI::HTTPConnection;
use PAGI::Utils::URI;

# Every edit of a PAGI::Utils::URI returns a new value and leaves the one it
# was called on as it was. A query edit re-parses the query and writes every
# pair form-encoded; a path edit can never start the path with "//".

sub uri { PAGI::Utils::URI->parse(@_) }

subtest 'with_query: pagination appends the new key after the client pairs' => sub {
    my $uri = uri('https://example.com/items?x=1&x=2');
    my $next = $uri->with_query(page => 2);
    isa_ok($next, 'PAGI::Utils::URI');
    is("$next", 'https://example.com/items?x=1&x=2&page=2', 'the new key goes to the end');
    is("" . $next->with_query(page => 3), 'https://example.com/items?x=1&x=2&page=3',
        'a named key loses every existing pair, then gets the new value');
    is("" . uri('http://h/?page=1&x=1')->with_query(page => 2), 'http://h/?x=1&page=2',
        'an edited key moves to the end; untouched pairs keep their order');
    is("$uri", 'https://example.com/items?x=1&x=2', 'the original is unchanged');
};

subtest 'with_query: undef deletes, an arrayref repeats, call order is kept' => sub {
    my $uri = uri('http://h/p?x=1&y=2&x=3');
    is("" . $uri->with_query(x => undef), 'http://h/p?y=2', 'undef drops every x');
    is("" . $uri->with_query(x => [7, 8]), 'http://h/p?y=2&x=7&x=8', 'an arrayref gives a repeated key');
    is("" . $uri->with_query(x => []), 'http://h/p?y=2', 'an empty arrayref drops the key');
    is("" . $uri->with_query(b => 1, a => 2), 'http://h/p?x=1&y=2&x=3&b=1&a=2',
        'new keys go to the end in call order');
    is("" . $uri->with_query(a => 1, a => 2), 'http://h/p?x=1&y=2&x=3&a=2',
        'a key named twice: the later one replaces the earlier');
    is("" . uri('http://h/p?x=1')->with_query(x => undef), 'http://h/p',
        'no pairs left: no query');
    is("" . $uri->with_query, 'http://h/p?x=1&y=2&x=3', 'no pairs: the query re-encoded only');
    like(dies { $uri->with_query('x') }, qr/\Awith_query takes name => value pairs at \Q${\ __FILE__}\E/,
        'an odd list dies, naming the caller');
};

subtest 'with_query: names and values are text, form-encoded' => sub {
    my $uri = uri('http://h/?caf%C3%A9=1&z=0');
    is("" . $uri->with_query('café' => 2), 'http://h/?z=0&caf%C3%A9=2',
        'a non-ASCII name matches the pair the client sent');
    is("" . uri('http://h/')->with_query(q => 'red shoes', n => '1+1', s => 'a&b=c', 'é' => 'ü'),
        'http://h/?q=red+shoes&n=1%2B1&s=a%26b%3Dc&%C3%A9=%C3%BC',
        'a space is +, a literal + is %2B, & and = are escaped, text is UTF-8');
    is($uri->with_query(q => 'red shoes')->query_params->get('q'), 'red shoes',
        'and reads back as the same text');

    my ($name, @values, @params) = ('café');
    @values = ('é', 'ü');
    @params = (z => ['é']);
    $uri->with_query($name => \@values);
    $uri->without_query($name);
    $uri->replace(query_params => \@params);
    is([$name, \@values, \@params], ['café', ['é', 'ü'], [z => ['é']]],
        "the caller's names and values are left as they were");
};

subtest 'any query edit re-parses and re-encodes the whole query' => sub {
    my $uri = uri('http://h/?q=red%20shoes&a=1%2B1&flag&b=2;c=3&d=e=f&t=%7e');
    my $expect = 'http://h/?q=red+shoes&a=1%2B1&flag=&b=2&c=3&d=e%3Df&t=~';
    is("" . $uri->with_query, $expect, 'with_query');
    is("" . $uri->without_query('absent'), $expect, 'without_query, even when nothing is removed');
    is("" . $uri->with_query(z => 1), "$expect&z=1", 'with a new pair');
    is("" . uri("http://h/?b=%FF%FE")->with_query(z => 1), 'http://h/?b=%FF%FE&z=1',
        'bytes that are not UTF-8 are kept as they were');
    is("" . uri('http://h/?a=1&&b=2&')->with_query, 'http://h/?a=1&b=2', 'empty pieces are dropped');
};

subtest 'without_query: a canonical link without tracking keys' => sub {
    my $uri = uri('https://example.com/post/7?id=7&utm_source=news&ref=a&utm_medium=email&utm_source=x');
    my $canonical = $uri->without_query(qw(utm_source utm_medium));
    isa_ok($canonical, 'PAGI::Utils::URI');
    is("$canonical", 'https://example.com/post/7?id=7&ref=a', 'every pair with those keys is gone');
    is("" . uri('http://h/?utm_source=a')->without_query('utm_source'), 'http://h/', 'no pairs left: no query');
    is("" . uri('http://h/?caf%C3%A9=1&z=0')->without_query('café'), 'http://h/?z=0', 'a non-ASCII name');
    is("" . $uri->without_query, 'https://example.com/post/7?id=7&utm_source=news&ref=a&utm_medium=email&utm_source=x',
        'no keys: the query re-encoded only');
};

subtest 'a query edit leaves the parsed pairs of the original alone' => sub {
    my $uri = uri('http://h/?a=1&b=2&a=3');
    my @raw = $uri->raw_query_params->flatten;
    my @text = $uri->query_params->flatten;
    $uri->with_query(a => 9, c => 1);
    $uri->without_query('b');
    $uri->replace(query_params => [z => 1]);
    is([$uri->raw_query_params->flatten], \@raw, 'raw_query_params as before');
    is([$uri->query_params->flatten], \@text, 'query_params as before');
    is($uri->query_string, 'a=1&b=2&a=3', 'query_string as before');
    is("$uri", 'http://h/?a=1&b=2&a=3', 'the string form as before');
    my $edited = $uri->with_query(a => 9)->without_query('b');
    is([$edited->raw_query_params->flatten], [a => 9], 'a chained edit reads its own pairs');
};

subtest 'replace(scheme): only the scheme changes' => sub {
    my $uri = uri('http://example.com:8080/a%2Fb/c?x=1&y#top');
    my $https = $uri->replace(scheme => 'https');
    is("$https", 'https://example.com:8080/a%2Fb/c?x=1&y#top', 'everything else is kept byte for byte');
    is($https->scheme, 'https', 'scheme');
    like(dies { $uri->replace(scheme => 'ht tp') }, qr/\Anot a scheme: ht tp at \Q${\ __FILE__}\E/,
        'an invalid scheme dies, naming the caller');
    like(dies { $uri->replace(scheme => '1http') }, qr/\Anot a scheme/, 'a scheme starts with a letter');
    like(dies { $uri->replace(scheme => undef) }, qr/\Anot a scheme/, 'undef is not a scheme');
};

subtest 'replace(authority), replace(host, port)' => sub {
    my $uri = uri('http://example.com:8080/p?x=1');
    is("" . $uri->replace(authority => 'other.example:9000'), 'http://other.example:9000/p?x=1', 'authority');
    is("" . $uri->replace(authority => 'other.example'), 'http://other.example/p?x=1', 'authority without a port');
    is("" . $uri->replace(host => 'other.example'), 'http://other.example:8080/p?x=1', 'host keeps the port');
    is("" . $uri->replace(port => 9000), 'http://example.com:9000/p?x=1', 'port keeps the host');
    is("" . $uri->replace(port => undef), 'http://example.com/p?x=1', 'port => undef removes it');
    is("" . $uri->replace(host => '[::1]', port => 443), 'http://[::1]:443/p?x=1', 'an IPv6 host and a port');

    my $odd = $uri->replace(authority => 'a%41:81');
    is($odd->authority, 'a%41:81', 'authority is taken as the reader gives it, not percent-decoded');
    is($odd->host, 'a%41', 'host');
    is($odd->port, 81, 'port');
    is("$odd", 'http://a%2541:81/p?x=1', 'and escaped in the string form');
    my $again = $odd->replace(authority => $odd->authority);
    is($again->authority, $odd->authority, 'replacing the authority with its own reading changes nothing');

    is("" . $uri->replace(host => 'evil.com/x?'), 'http://evil.com%2Fx%3F:8080/p?x=1',
        'a host cannot change the path or query');

    like(dies { $uri->replace(port => 'http') }, qr/\Aport must be digits or undef at \Q${\ __FILE__}\E/,
        'a port that is not digits dies');
    like(dies { $uri->replace(authority => 'a', host => 'b') }, qr/\Areplace takes authority, or host and port, not both/,
        'authority with host dies');
    like(dies { $uri->replace(authority => 'a', port => 1) }, qr/\Areplace takes authority, or host and port, not both/,
        'authority with port dies');
    like(dies { $uri->replace(host => undef) }, qr/\Ahost must be defined/, 'host => undef dies');
    like(dies { $uri->replace(authority => undef) }, qr/\Aauthority must be defined/, 'authority => undef dies');
};

subtest 'replace(path), replace(raw_path)' => sub {
    my $uri = uri('http://h/old?x=1#top');
    my $moved = $uri->replace(path => '/café/a b');
    is("$moved", 'http://h/caf%C3%A9/a%20b?x=1#top', 'path is text, encoded; the query and fragment are kept');
    is($moved->path, '/café/a b', 'and reads back as the same text');
    is($moved->raw_path, '/caf%C3%A9/a%20b', 'raw_path');
    is("" . $uri->replace(path => '/a?b#c'), 'http://h/a%3Fb%23c?x=1#top', 'a ? or # in a path is part of the path');

    my $raw = $uri->replace(raw_path => '/a%2Fb/c');
    is("$raw", 'http://h/a%2Fb/c?x=1#top', 'raw_path is escaped bytes, kept as given');
    is($raw->path, '/a/b/c', 'path is it decoded');
    is("" . $uri->replace(raw_path => '/a b?c'), 'http://h/a%20b%3Fc?x=1#top',
        'what a path cannot hold is percent-encoded');
    is("" . $uri->replace(path => ''), 'http://h?x=1#top', 'an empty path');

    like(dies { $uri->replace(path => 'relative') }, qr/\Aa path must be empty or start with \/ at \Q${\ __FILE__}\E/,
        'a path without a leading / dies');
    like(dies { $uri->replace(raw_path => 'relative') }, qr/\Aa path must be empty or start with \//,
        'so does a raw_path');
    like(dies { $uri->replace(path => '/a', raw_path => '/b') }, qr/\Areplace takes path or raw_path, not both/,
        'path with raw_path dies');
};

subtest 'a path edit keeps a leading // as given' => sub {
    my $uri = uri('http://example.com/p?x=1');
    for my $case (
        [path     => $uri->replace(path => '//x'),     '//x'],
        [raw_path => $uri->replace(raw_path => '//x'), '//x'],
        [path_3   => $uri->replace(path => '///x'),    '///x'],
    ) {
        my ($how, $edited, $raw_path) = @$case;
        is($edited->raw_path, $raw_path, "$how: raw_path");
        is("$edited", "http://example.com$raw_path?x=1", "$how: the string form");
        is($edited->path_query, '/x?x=1', "$how: path_query has one leading /");
    }
    my $resolved = $uri->resolve('/.//x');
    is($resolved->raw_path, '//x', 'resolve follows RFC 3986: /.//x is //x');
    is("$resolved", 'http://example.com//x', 'resolve: the string form');
    is($resolved->path_query, '/x', 'resolve: path_query has one leading /');
    is($uri->resolve('//other.example//x')->raw_path, '//x', 'resolve with an authority: RFC 3986 only');

    my $parsed = uri('http://example.com//evil.example/x?x=1');
    for my $case (
        [with_query    => $parsed->with_query(y => 2)],
        [without_query => $parsed->without_query('x')],
        [add_query     => $parsed->add_query(y => 2)],
        [replace       => $parsed->replace(fragment => 'f', scheme => 'https')],
        [resolve       => $parsed->resolve('?z=1')],
    ) {
        my ($how, $edited) = @$case;
        is($edited->raw_path, '//evil.example/x', "$how, leaving a parsed path alone: the // stays");
    }
};

subtest 'replace(query_params), replace(query_string), replace(fragment)' => sub {
    my $uri = uri('http://h/p?old=1#top');
    is("" . $uri->replace(query_params => [b => 'x y', a => [1, 2], c => undef]), 'http://h/p?b=x+y&a=1&a=2#top',
        'an arrayref of pairs, text, in order');
    is("" . $uri->replace(query_params => {b => 2, a => 'é'}), 'http://h/p?a=%C3%A9&b=2#top',
        'a hashref, its keys sorted');
    is("" . $uri->replace(query_params => Hash::MultiValue->new(z => 1, a => 2, z => 3)), 'http://h/p?z=1&a=2&z=3#top',
        'a Hash::MultiValue, in its order');
    is("" . $uri->replace(query_params => []), 'http://h/p#top', 'no pairs: no query');
    like(dies { $uri->replace(query_params => 'a=1') }, qr/\Aquery_params must be an arrayref, a hashref or a Hash::MultiValue at \Q${\ __FILE__}\E/,
        'a string is not query_params');

    is("" . $uri->replace(query_string => 'a=1;b=%20+'), 'http://h/p?a=1;b=%20+#top', 'query_string is bytes, kept as given');
    is("" . $uri->replace(query_string => 'a b#c'), 'http://h/p?a%20b%23c#top', 'what a query cannot hold is percent-encoded');
    is("" . $uri->replace(query_string => ''), 'http://h/p#top', "'' clears the query");
    like(dies { $uri->replace(query_string => 'a', query_params => []) }, qr/\Areplace takes query_params or query_string, not both/,
        'query_string with query_params dies');

    is("" . $uri->replace(fragment => 'sec 2'), 'http://h/p?old=1#sec%202', 'fragment');
    is("" . $uri->replace(fragment => 'café'), 'http://h/p?old=1#caf%C3%A9', 'fragment is characters, as parse takes them');
    is("" . $uri->replace(fragment => ''), 'http://h/p?old=1', "'' clears the fragment");
};

subtest 'replace: several parts at once, unknown parts die' => sub {
    my $uri = uri('http://example.com/a?x=1');
    is("" . $uri->replace(scheme => 'https', host => 'www.example.com', port => 8443, path => '/b'),
        'https://www.example.com:8443/b?x=1', 'scheme, host, port and path');
    is("" . $uri->replace, "$uri", 'no parts: an equal value');
    like(dies { $uri->replace(query => 'a=1') }, qr/\Areplace cannot change: query at \Q${\ __FILE__}\E/,
        'an unknown part dies, naming it');
    like(dies { $uri->replace('scheme') }, qr/\Areplace takes name => value pairs/, 'an odd list dies');
};

# RFC 3986 section 5.4, against its base.
my $base = 'http://a/b/c/d;p?q';

my @normal = (
    ['g'       => 'http://a/b/c/g'],
    ['./g'     => 'http://a/b/c/g'],
    ['g/'      => 'http://a/b/c/g/'],
    ['/g'      => 'http://a/g'],
    ['//g'     => 'http://g'],
    ['?y'      => 'http://a/b/c/d;p?y'],
    ['g?y'     => 'http://a/b/c/g?y'],
    ['#s'      => 'http://a/b/c/d;p?q#s'],
    ['g#s'     => 'http://a/b/c/g#s'],
    ['g?y#s'   => 'http://a/b/c/g?y#s'],
    [';x'      => 'http://a/b/c/;x'],
    ['g;x'     => 'http://a/b/c/g;x'],
    ['g;x?y#s' => 'http://a/b/c/g;x?y#s'],
    [''        => 'http://a/b/c/d;p?q'],
    ['.'       => 'http://a/b/c/'],
    ['./'      => 'http://a/b/c/'],
    ['..'      => 'http://a/b/'],
    ['../'     => 'http://a/b/'],
    ['../g'    => 'http://a/b/g'],
    ['../..'   => 'http://a/'],
    ['../../'  => 'http://a/'],
    ['../../g' => 'http://a/g'],
);

my @abnormal = (
    ['../../../g'    => 'http://a/g'],
    ['../../../../g' => 'http://a/g'],
    ['/./g'          => 'http://a/g'],
    ['/../g'         => 'http://a/g'],
    ['g.'            => 'http://a/b/c/g.'],
    ['.g'            => 'http://a/b/c/.g'],
    ['g..'           => 'http://a/b/c/g..'],
    ['..g'           => 'http://a/b/c/..g'],
    ['./../g'        => 'http://a/b/g'],
    ['./g/.'         => 'http://a/b/c/g/'],
    ['g/./h'         => 'http://a/b/c/g/h'],
    ['g/../h'        => 'http://a/b/c/h'],
    ['g;x=1/./y'     => 'http://a/b/c/g;x=1/y'],
    ['g;x=1/../y'    => 'http://a/b/c/y'],
    ['g?y/./x'       => 'http://a/b/c/g?y/./x'],
    ['g?y/../x'      => 'http://a/b/c/g?y/../x'],
    ['g#s/./x'       => 'http://a/b/c/g#s/./x'],
    ['g#s/../x'      => 'http://a/b/c/g#s/../x'],
);

subtest 'resolve: RFC 3986 5.4.1 normal examples' => sub {
    my $uri = uri($base);
    for my $case (@normal) {
        my ($reference, $target) = @$case;
        my $resolved = $uri->resolve($reference);
        isa_ok($resolved, 'PAGI::Utils::URI');
        is("$resolved", $target, "'$reference' resolves to $target");
    }
    is("$uri", $base, 'the base is unchanged');
};

subtest 'resolve: RFC 3986 5.4.2 abnormal examples' => sub {
    my $uri = uri($base);
    for my $case (@abnormal) {
        my ($reference, $target) = @$case;
        is("" . $uri->resolve($reference), $target, "'$reference' resolves to $target");
    }
};

subtest 'resolve: a reference with a scheme and no authority dies' => sub {
    my $uri = uri($base);
    # RFC 3986 gives "g:h" and, for a strict parser, "http:g": URIs with no
    # authority, which a PAGI::Utils::URI cannot hold.
    like(dies { $uri->resolve('g:h') }, qr/\Aa reference with a scheme must have an authority at \Q${\ __FILE__}\E/, "'g:h'");
    like(dies { $uri->resolve('http:g') }, qr/\Aa reference with a scheme must have an authority/, "'http:g'");
    like(dies { $uri->resolve(undef) }, qr/\Aresolve requires a reference/, 'undef');
};

subtest 'resolve: a callback URL from a path' => sub {
    my $uri = uri('https://example.com/app/items/42?x=1');
    is("" . $uri->resolve('/app/oauth/return'), 'https://example.com/app/oauth/return',
        'an absolute path keeps the scheme and authority, not the query');
    is("" . $uri->resolve('/app/oauth/return?state=a%20b'), 'https://example.com/app/oauth/return?state=a%20b',
        'its own query is kept as given');
    is("" . $uri->resolve('../7'), 'https://example.com/app/7', 'a relative path merges with the base path');
    is("$uri", 'https://example.com/app/items/42?x=1', 'the base is unchanged');
};

subtest 'resolve: authority, scheme and empty base paths' => sub {
    my $uri = uri('https://example.com:8443/a/b?x=1#f');
    is("" . $uri->resolve('//other.example/x/../y?q'), 'https://other.example/y?q',
        'a network-path reference keeps only the scheme');
    is("" . $uri->resolve('http://other.example:81/x/./y?q#g'), 'http://other.example:81/x/y?q#g',
        'a reference with a scheme and authority keeps nothing of the base');
    is("" . $uri->resolve('#g'), 'https://example.com:8443/a/b?x=1#g', 'a fragment alone');
    is("" . $uri->resolve(''), 'https://example.com:8443/a/b?x=1', 'an empty reference drops the fragment');
    is("" . uri('http://a')->resolve('g'), 'http://a/g', 'a base with an empty path merges to /g');
    like(dies { $uri->resolve('//user@other.example/') }, qr/\Auserinfo is not supported/,
        'userinfo in the reference dies, as parse dies');
};

subtest 'resolve: the reference is characters; the authority stays escaped' => sub {
    my $uri = uri('http://h/a/b');
    is("" . $uri->resolve('/café?q=é#é'), 'http://h/caf%C3%A9?q=%C3%A9#%C3%A9',
        'non-ASCII is UTF-8 encoded and percent-encoded, as parse does');
    is("" . $uri->resolve('/caf%C3%A9'), 'http://h/caf%C3%A9', 'an escaped reference, as path_for gives, is kept');
    is("" . $uri->resolve('c d'), 'http://h/a/c%20d', 'what a path cannot hold is percent-encoded');

    my $hostile = PAGI::Utils::URI->from_scope({
        type => 'http', scheme => 'http', path => '/items', raw_path => '/items',
        query_string => '', headers => [['host', 'evil.com/x?']],
    });
    is("" . $hostile->resolve('/g'), 'http://evil.com%2Fx%3F/g', 'the base authority is escaped in the result');
};

subtest 'every edit leaves $conn->uri unchanged' => sub {
    my $conn = PAGI::HTTPConnection->new({
        type         => 'http',
        scheme       => 'https',
        root_path    => '/app',
        path         => '/items/42',
        raw_path     => '/app/items/42',
        query_string => 'x=1&x=2',
        headers      => [['host', 'example.com']],
        server       => ['10.0.0.5', 443],
    });
    my $uri = $conn->uri;
    my $before = "$uri";
    my @edits = (
        $uri->with_query(page => 2),
        $uri->without_query('x'),
        $uri->replace(scheme => 'http', host => 'other', port => 1, path => '/z', fragment => 'f'),
        $uri->replace(raw_path => '/r', query_string => 'q'),
        $uri->replace(query_params => [a => 1]),
        $uri->resolve('/app/oauth/return'),
    );
    for my $edited (@edits) {
        isnt(refaddr($edited), refaddr($uri), 'an edit is a new value');
    }
    is("" . $edits[-1], 'https://example.com/app/oauth/return', 'resolve(path_for(...)) builds the callback');
    is(refaddr($conn->uri), refaddr($uri), 'the connection keeps its value');
    is("" . $conn->uri, $before, 'and its string form');
    is($conn->uri->path, '/app/items/42', 'path');
    is($conn->uri->query_string, 'x=1&x=2', 'query_string');
    is([$conn->uri->query_params->flatten], [x => 1, x => 2], 'query_params');
    is($conn->uri->fragment, '', 'fragment');
    is($conn->uri->scheme, 'https', 'scheme');
    is($conn->uri->authority, 'example.com', 'authority');
};

done_testing;
