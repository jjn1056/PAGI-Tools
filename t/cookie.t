use v5.24;
use warnings;
use Test2::V0;
use PAGI::Test::Client;

use PAGI::Response;
use PAGI::Cookie;

sub cookie { PAGI::Cookie->new(@_) }

subtest 'a cookie: its header, path / by default' => sub {
    my $c = cookie(name => 'session', value => 'abc123');
    is $c->as_string, 'session=abc123; Path=/', 'name, value and the default path';
    is $c->header, ['set-cookie', 'session=abc123; Path=/'], 'a header pair, ready for headers';
    is(cookie(name => 'flag')->as_string, 'flag=; Path=/', 'no value: empty');
    is(cookie(name => 'x', value => 'y', path => undef)->as_string, 'x=y', 'path => undef: no Path at all');
};

subtest 'every attribute, in order' => sub {
    my $c = cookie(name => 'id', value => 'v', path => '/app', domain => 'example.com',
        expires => 784111777, max_age => 3600, samesite => 'LAX',
        secure => 1, httponly => 1, partitioned => 1);
    is $c->as_string,
        'id=v; Path=/app; Domain=example.com; Expires=Sun, 06 Nov 1994 08:49:37 GMT; Max-Age=3600; SameSite=Lax; Secure; HttpOnly; Partitioned',
        'Path, Domain, Expires (an epoch, as an HTTP date), Max-Age, SameSite (capitalized), then the flags';
    is(cookie(name => 'id', value => 'v', expires => 'Wed, 21 Oct 2037 07:28:00 GMT')->as_string,
        'id=v; Path=/; Expires=Wed, 21 Oct 2037 07:28:00 GMT', 'a date string, as given');
    is(cookie(name => 'id', value => 'v', secure => 0, httponly => 0)->as_string, 'id=v; Path=/', 'false flags: not written');
    is(cookie(name => 'id', samesite => 'strict')->as_string, 'id=; Path=/; SameSite=Strict', 'samesite strict');
};

subtest 'expired: the same cookie, emptied and expired' => sub {
    my $c = cookie(name => 'session', value => 'abc', path => '/app', domain => 'example.com', secure => 1, httponly => 1, max_age => 60);
    my $gone = $c->expired;
    is $gone->as_string,
        'session=; Path=/app; Domain=example.com; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0; Secure; HttpOnly',
        'same name, path and domain: the browser removes the one it has';
    is $c->value, 'abc', 'the cookie it came from is unchanged';
    is(cookie(name => '__Host-id', value => 'x', secure => 1)->expired->as_string,
        '__Host-id=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0; Secure', 'a prefixed cookie expires too');
};

subtest 'getters: read, never written' => sub {
    my $c = cookie(name => 'id', value => 'v', domain => 'example.com', max_age => 5, secure => 1);
    is [map { $c->$_ } qw(name value path domain max_age secure)], ['id', 'v', '/', 'example.com', 5, 1], 'what it was built with';
    is [map { $c->$_ } qw(expires samesite httponly partitioned)], [undef, undef, undef, undef], 'and nothing it was not';
    for my $field (qw(name value path domain expires max_age samesite secure httponly partitioned)) {
        like dies { $c->$field(1) }, qr/\Acookie is immutable: \$cookie->$field can't be set; build a new cookie/, "$field can't be set";
    }
};

subtest 'names and values: what browsers can carry, or a croak' => sub {
    like dies { cookie(value => 'x') }, qr/\Aa cookie needs a name/, 'no name';
    like dies { cookie(name => '') }, qr/\Aa cookie needs a name/, 'an empty name';
    like dies { cookie(name => 'a b') }, qr/\Acookie name contains ' ': a name is an RFC 6265 token/, 'a space in the name';
    like dies { cookie(name => 'a=b') }, qr/\Acookie name contains '='/, 'an = in the name';
    for my $bad (' ', ';', ',', '"', '\\', "\x7F", "\x00", "\xE9") {
        like dies { cookie(name => 'x', value => "a${bad}b") },
            qr/\Acookie value contains '\Q$bad\E', which browsers can't carry: encode it first \(Base64 or URI::Escape\)/,
            sprintf('%vX in a value croaks', $bad);
    }
    like dies { cookie(name => 'x', value => "caf\x{e9}\x{263A}") }, qr/\Acookie value contains/, 'a character above 0xFF';
    like dies { cookie(name => 'x', value => [1]) }, qr/\Acookie value must be a string, not a ARRAY reference/, 'a reference';
    like dies { cookie(name => 'x', value => undef) }, qr/\Acookie value must be a string/, 'undef';
    is(cookie(name => 'x', value => q{!#$%&'()*+-./:<=>?@[]^_`{|}~09AZaz})->value, q{!#$%&'()*+-./:<=>?@[]^_`{|}~09AZaz},
        'every cookie-octet kinds of character passes');
};

subtest 'attributes: checked when built' => sub {
    for my $attr (qw(path domain)) {
        like dies { cookie(name => 'x', $attr => "/a;b") }, qr/\Acookie $attr can't contain ';' or a control character/, "$attr with ;";
        like dies { cookie(name => 'x', $attr => "/a\nb") }, qr/\Acookie $attr can't contain/, "$attr with a newline";
    }
    like dies { cookie(name => 'x', expires => "Wed; Domain=evil") }, qr/\Acookie expires can't contain ';'/, 'expires string with ;';
    like dies { cookie(name => 'x', max_age => '1h') }, qr/\Amax_age must be a whole number of seconds/, 'max_age not a number';
    like dies { cookie(name => 'x', max_age => 1.5) }, qr/\Amax_age must be a whole number/, 'max_age a fraction';
    like dies { cookie(name => 'x', samesite => 'loose') }, qr/\Asamesite must be lax, strict or none/, 'samesite unknown';
};

subtest 'contradictions croak with the fix; nothing is added for you' => sub {
    like dies { cookie(name => '__Secure-id', value => 'x') }, qr/\Aa __Secure- cookie needs secure => 1/, '__Secure- without secure';
    like dies { cookie(name => '__Host-id', value => 'x') }, qr/\Aa __Host- cookie needs secure => 1/, '__Host- without secure';
    like dies { cookie(name => '__Host-id', value => 'x', secure => 1, path => '/app') },
        qr/\Aa __Host- cookie needs path => '\/' and no domain/, '__Host- with another path';
    like dies { cookie(name => '__Host-id', value => 'x', secure => 1, domain => 'example.com') },
        qr/\Aa __Host- cookie needs path => '\/' and no domain/, '__Host- with a domain';
    like dies { cookie(name => 'x', samesite => 'None') }, qr/\Asamesite => none needs secure => 1: browsers drop it otherwise/,
        'SameSite=None without secure';
    like dies { cookie(name => 'x', partitioned => 1) }, qr/\Apartitioned needs secure => 1/, 'partitioned without secure';
    is(cookie(name => '__Host-id', value => 'x', secure => 1)->as_string, '__Host-id=x; Path=/; Secure', 'fixed: fine');
    is(cookie(name => 'x', samesite => 'none', secure => 1)->as_string, 'x=; Path=/; SameSite=None; Secure', 'and SameSite=None too');
};

subtest 'a cookie over 4096 bytes croaks: browsers drop it' => sub {
    is length(cookie(name => 'x', value => 'a' x (4096 - length 'x=; Path=/'))->as_string), 4096, '4096 bytes: fine';
    like dies { cookie(name => 'x', value => 'a' x 4096) }, qr/\Acookie x is 4\d\d\d bytes: browsers ignore one over 4096/,
        'over: croaks, naming the cookie and its size';
};

subtest 'in a response, to the wire' => sub {
    my $session = cookie(name => 'session', value => 'abc', httponly => 1);
    my $res = PAGI::Test::Client->new(app => PAGI::Response->new(
        headers => [$session->header, cookie(name => 'old')->expired->header]))->get('/');
    ok !$res->exception, 'a strict client accepts it';
    is [map { $_->[1] } grep { $_->[0] eq 'set-cookie' } @{ $res->header_pairs }],
        ['session=abc; Path=/; HttpOnly', 'old=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0'],
        'both Set-Cookie headers, as built';
};

done_testing;
