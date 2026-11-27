use v5.24;
use warnings;
use Test2::V0;
use PAGI::Test::Client;
use Test::Lib;
use PAGITest::LowercaseHeaders;

use PAGI::Response::Redirect;

# Serves a response for one GET, as a strict server would.
sub get { PAGI::Test::Client->new(app => $_[0])->get('/') }

sub location { get(PAGI::Response::Redirect->new(url => $_[0]))->header('location') }

{
    package Local::URL;
    use overload '""' => sub { $_[0]{url} };
    sub new { my ($class, $url) = @_; bless { url => $url }, $class }
}

subtest 'a redirect: 302 and a Location, no body' => sub {
    my $res = get(PAGI::Response::Redirect->new(url => '/next'));
    is $res->status, 302, '302 unless you give a status';
    is get(PAGI::Response::Redirect->new(url => '/next', status => 307))->status, 307,
        'the status option changes it: 307 to keep the method';
    is $res->header('location'), '/next', 'the Location';
    is [$res->content, $res->header('content-length')], ['', 0], 'no body';
    is get(PAGI::Response::Redirect->new(url => '/next', status => 303))->status, 303, 'a status you give';
};

subtest 'the URL, percent-encoded as UTF-8 however Perl holds it' => sub {
    my $plain   = "/search?q=Gr\x{fc}\x{df}e";
    my $flagged = $plain;
    utf8::upgrade($flagged);
    is location($plain),   '/search?q=Gr%C3%BC%C3%9Fe', 'characters below 256, internal flag off';
    is location($flagged), '/search?q=Gr%C3%BC%C3%9Fe', 'the same characters, flag on';
    is location("/caf\x{e9}/\x{1F30D}"), '/caf%C3%A9/%F0%9F%8C%8D', 'any character';
    is location('/search?q=a b'), '/search?q=a%20b', 'a space';
};

subtest 'a valid URL is left as it is' => sub {
    for my $url ('/next', 'https://example.com/a?b=1&c=2#d', '/already%20escaped', 'mailto:a@example.com',
                 "/x;y=1/(z)!*'+,\$") {
        is location($url), $url, $url;
    }
    is location(Local::URL->new('/from/an/object')), '/from/an/object', 'an object that stringifies';
};

subtest 'a line break cannot start a header of its own' => sub {
    is location("/x\r\nSet-Cookie: evil=1"), '/x%0D%0ASet-Cookie:%20evil=1', 'CR and LF escaped';
};

subtest 'what new refuses' => sub {
    like dies { PAGI::Response::Redirect->new }, qr/\Aurl is required: /, 'no url';
    like dies { PAGI::Response::Redirect->new(url => '') }, qr/\Aurl is required: /, 'an empty url';
    like dies { PAGI::Response::Redirect->new(url => []) },
        qr/\Aurl must be a string, or an object that stringifies at \Q${\ __FILE__}\E line/,
        'a plain reference';
    for my $status (200, 304, 404) {
        like dies { PAGI::Response::Redirect->new(url => '/x', status => $status) },
            qr/\Astatus $status isn't a redirect: use 301, 302, 303, 307 or 308/, "status $status";
    }
    like dies { PAGI::Response::Redirect->new(url => '/x', headers => [['Location', '/y']]) },
        qr/\ARedirect sets location itself, from url/, 'a Location header';
};

subtest 'every redirect status, and only those' => sub {
    for my $status (301, 302, 303, 307, 308) {
        is get(PAGI::Response::Redirect->new(url => '/x', status => $status))->status, $status, "status $status";
    }
    like dies { PAGI::Response::Redirect->new(url => '/x', status => 300) }, qr/\Astatus 300 isn't a redirect/,
        '300 Multiple Choices is not one of them';
};

subtest 'a redirect has no body' => sub {
    like dies { PAGI::Response::Redirect->new(url => '/x', content => 'moved') },
        qr/\Aa redirect has no body: give url, not content/, 'content refused, not ignored';
};

subtest 'a URL with an IPv6 literal and a tilde is left as it is' => sub {
    is location('http://[::1]:8080/~ada/'), 'http://[::1]:8080/~ada/', 'brackets and tilde kept';
};

subtest 'other headers, and cookies' => sub {
    my $response = PAGI::Response::Redirect->new(url => '/home', headers => [['cache-control', 'no-store']]);
    $response->set_cookie(session => 'abc');
    my $res = get($response);
    is $res->header('cache-control'), 'no-store', 'yours';
    like $res->header('set-cookie'), qr/\Asession=abc;/, 'a cookie, as after a login';
};

done_testing;
