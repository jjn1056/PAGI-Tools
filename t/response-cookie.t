use v5.24;
use warnings;
use Test2::V0;
use PAGI::Test::Client;
use Test::Lib;
use PAGITest::LowercaseHeaders;

use PAGI::Response;

# The Set-Cookie values a response will send, in order.
sub set_cookies {
    my ($response) = @_;
    return [map { $_->[1] } grep { $_->[0] eq 'set-cookie' } @{ $response->headers }];
}

# The one Set-Cookie value that set_cookie with these arguments adds.
sub cookie { set_cookies(PAGI::Response->new->set_cookie(@_))->[0] }

subtest 'set_cookie: a Set-Cookie header, path / by default' => sub {
    is cookie(session => 'abc123'), 'session=abc123; Path=/', 'name, value and the default path';
    is cookie(flag => ''), 'flag=; Path=/', 'an empty value';
    is cookie(x => 'y', path => undef), 'x=y', 'path => undef: no Path at all';
    my $response = PAGI::Response->new;
    is $response->set_cookie(a => 'b'), exact_ref($response), 'returns the response, so calls chain';
};

subtest 'every attribute, in order' => sub {
    is cookie(id => 'v', path => '/app', domain => 'example.com', expires => 784111777, max_age => 3600,
            samesite => 'LAX', secure => 1, httponly => 1, partitioned => 1),
        'id=v; Path=/app; Domain=example.com; Expires=Sun, 06 Nov 1994 08:49:37 GMT; Max-Age=3600; SameSite=Lax; Secure; HttpOnly; Partitioned',
        'Path, Domain, Expires (an epoch, as an HTTP date), Max-Age, SameSite (capitalized), then the flags';
    is cookie(id => 'v', expires => 'Wed, 21 Oct 2037 07:28:00 GMT'), 'id=v; Path=/; Expires=Wed, 21 Oct 2037 07:28:00 GMT',
        'a date string, as given';
    is cookie(id => 'v', secure => 0, httponly => 0), 'id=v; Path=/', 'false flags: not written';
    is cookie(id => '', samesite => 'strict'), 'id=; Path=/; SameSite=Strict', 'samesite strict';
};

subtest 'each call adds a header after the others; nothing else changes' => sub {
    my $response = PAGI::Response->new(content => 'hi', content_type => 'text/plain', headers => [['X-Id', '7']]);
    my $before = [@{ $response->headers }];
    $response->set_cookie(theme => 'light')->set_cookie(theme => 'dark', path => '/app');
    is $response->headers, [@$before, ['set-cookie', 'theme=light; Path=/'], ['set-cookie', 'theme=dark; Path=/app']],
        'two calls, two headers, after the ones the response was built with';
    is [$response->status, $response->body, $response->content_type], [200, 'hi', 'text/plain'], 'status, body and type as built';
};

subtest 'delete_cookie: the same cookie, emptied and expired' => sub {
    my $response = PAGI::Response->new;
    is $response->delete_cookie('session', path => '/app', domain => 'example.com', secure => 1, httponly => 1, max_age => 60),
        exact_ref($response), 'returns the response';
    is set_cookies($response),
        ['session=; Path=/app; Domain=example.com; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0; Secure; HttpOnly'],
        'the attributes it was set with, so the browser removes the one it has; max_age is 0 whatever you give';
    is set_cookies(PAGI::Response->new->delete_cookie('x')), ['x=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0'],
        'path / by default, as set_cookie';
};

subtest 'names and values: what browsers can carry, or a croak' => sub {
    my $line = __LINE__ + 1;
    my $error = dies { PAGI::Response->new->set_cookie('a b' => 'x') };
    like $error, qr/\Acookie name contains ' ': a name is an RFC 6265 token/, 'a space in the name';
    like $error, qr/at \Q${\ __FILE__ }\E line $line\.$/, 'from the line that set it';
    like dies { cookie(undef, 'x') }, qr/\Aa cookie needs a name/, 'no name';
    like dies { cookie('' => 'x') }, qr/\Aa cookie needs a name/, 'an empty name';
    like dies { cookie('a=b' => 'x') }, qr/\Acookie name contains '='/, 'an = in the name';
    for my $bad (' ', ';', ',', '"', '\\', "\x7F", "\x00", "\xE9") {
        like dies { cookie(x => "a${bad}b") },
            qr/\Acookie value contains '\Q$bad\E', which browsers can't carry: encode it first \(Base64 or URI::Escape\)/,
            sprintf('%vX in a value croaks', $bad);
    }
    like dies { cookie(x => "caf\x{e9}\x{263A}") }, qr/\Acookie value contains/, 'a character above 0xFF';
    like dies { cookie(x => [1]) }, qr/\Acookie value must be a string, not a ARRAY reference/, 'a reference';
    like dies { cookie(x => undef) }, qr/\Acookie value must be a string, not undef/, 'undef';
    is cookie(x => q{!#$%&'()*+-./:<=>?@[]^_`{|}~09AZaz}), q{x=!#$%&'()*+-./:<=>?@[]^_`{|}~09AZaz; Path=/},
        'every kind of cookie-octet passes';
};

subtest 'attributes: each checked on its own' => sub {
    for my $attr (qw(path domain)) {
        like dies { cookie(x => '', $attr => "/a;b") }, qr/\Acookie $attr can't contain ';' or a control character/, "$attr with ;";
        like dies { cookie(x => '', $attr => "/a\nb") }, qr/\Acookie $attr can't contain/, "$attr with a newline";
    }
    like dies { cookie(x => '', expires => "Wed; Domain=evil") }, qr/\Acookie expires can't contain ';'/, 'expires string with ;';
    like dies { cookie(x => '', max_age => '1h') }, qr/\Amax_age must be a whole number of seconds/, 'max_age not a number';
    like dies { cookie(x => '', max_age => 1.5) }, qr/\Amax_age must be a whole number/, 'max_age a fraction';
    like dies { cookie(x => '', samesite => 'loose') }, qr/\Asamesite must be lax, strict or none/, 'samesite unknown';
};

subtest 'an attribute name not in the list croaks: a misspelled flag would go unsent' => sub {
    like dies { cookie(s => 1, http_only => 1) }, qr/\Aunknown cookie attribute 'http_only': use one of domain, /,
        'http_only, not httponly';
    like dies { cookie(s => 1, 'max-age' => 5) }, qr/\Aunknown cookie attribute 'max-age'/, 'max-age, not max_age';
    like dies { PAGI::Response->new->delete_cookie(s => same_site => 'lax') }, qr/\Aunknown cookie attribute 'same_site'/,
        'delete_cookie too';
};

subtest 'expires: any epoch number is a date' => sub {
    is cookie(x => '', expires => 784111777.25), 'x=; Path=/; Expires=Sun, 06 Nov 1994 08:49:37 GMT',
        'a fraction, as Time::HiRes::time gives: the whole second';
    is cookie(x => '', expires => -1), 'x=; Path=/; Expires=Wed, 31 Dec 1969 23:59:59 GMT', 'before 1970';
};

subtest 'rules across attributes are yours: sent as set, nothing added' => sub {
    is cookie('__Secure-id' => 'x'), '__Secure-id=x; Path=/', '__Secure- without secure';
    is cookie('__Host-id' => 'x', secure => 1, domain => 'example.com'), '__Host-id=x; Path=/; Domain=example.com; Secure',
        '__Host- with a domain';
    is cookie(x => '', samesite => 'None'), 'x=; Path=/; SameSite=None', 'SameSite=None without secure';
    is cookie(x => '', partitioned => 1), 'x=; Path=/; Partitioned', 'partitioned without secure';
};

subtest 'name and value over 4096 bytes croaks: browsers ignore it' => sub {
    my $long_path = '/' . 'p' x 100;
    is cookie(x => 'a' x 4095, path => $long_path), 'x=' . 'a' x 4095 . "; Path=$long_path",
        '4096 bytes of name and value: fine, however long the attributes make the header';
    like dies { cookie(x => 'a' x 4096) }, qr/\Acookie x is 4097 bytes of name and value: browsers ignore one over 4096/,
        'over: croaks, naming the cookie and its size';
};

subtest 'to the wire' => sub {
    my $res = PAGI::Test::Client->new(app => PAGI::Response->new
        ->set_cookie(session => 'abc', httponly => 1)
        ->delete_cookie('old'))->get('/');
    ok !$res->exception, 'a strict client accepts it';
    is [map { $_->[1] } grep { $_->[0] eq 'set-cookie' } @{ $res->header_pairs }],
        ['session=abc; Path=/; HttpOnly', 'old=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0'],
        'both Set-Cookie headers, as set';
};

done_testing;
