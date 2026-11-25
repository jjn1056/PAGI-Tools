use v5.24;
use warnings;
use Test2::V0;
use PAGI::Test::Client;
use Test::Lib;
use PAGITest::LowercaseHeaders;

use PAGI::Response::HTML;

# Serves a response for one GET, as a strict server would.
sub get { PAGI::Test::Client->new(app => $_[0])->get('/') }

# The headers the response sent: all but the Date the client adds, as a server does.
sub sent_headers { [grep { $_->[0] ne 'date' } @{ $_[0]->header_pairs }] }

subtest 'markup, sent as UTF-8 HTML' => sub {
    my $res = get(PAGI::Response::HTML->new(content => "<p>Gr\x{fc}\x{df}e</p>"));
    is $res->status, 200, 'status 200';
    is $res->content, "<p>Gr\xc3\xbc\xc3\x9fe</p>", 'the body is the UTF-8 bytes';
    is sent_headers($res),
        [['content-length', 14], ['content-type', 'text/html; charset=utf-8']],
        'the length in bytes, and the HTML type naming the charset';
};

subtest 'the markup is sent as given, not escaped' => sub {
    my $res = get(PAGI::Response::HTML->new(content => '<b>&</b>'));
    is $res->content, '<b>&</b>', 'nothing escaped';
};

subtest 'a content type of your own' => sub {
    my $res = get(PAGI::Response::HTML->new(content => '<p/>', content_type => 'text/x-html'));
    is $res->header('content-type'), 'text/x-html; charset=utf-8', 'a text type gets the charset';

    $res = get(PAGI::Response::HTML->new(content => '<p/>', content_type => 'application/xhtml+xml'));
    is $res->header('content-type'), 'application/xhtml+xml', 'another type is sent as given';
};

subtest 'content that is not text dies at new' => sub {
    like dies { PAGI::Response::HTML->new(content => []) }, qr/\Acontent must be text: /,
        'a plain reference says what to give';
};

done_testing;
