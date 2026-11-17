use v5.24;
use warnings;
use Test2::V0;
use PAGI::Test::Client;
use Test::Lib;
use PAGITest::LowercaseHeaders;
use JSON::MaybeXS ();

use PAGI::Response::JSON;

# Serves a response for one GET, as a strict server would.
sub get { PAGI::Test::Client->new(app => $_[0])->get('/') }

# The headers the response sent: all but the Date the client adds, as a server does.
sub sent_headers { [grep { $_->[0] ne 'date' } @{ $_[0]->header_pairs }] }

subtest 'data, sent as JSON' => sub {
    my $res = get(PAGI::Response::JSON->new(content => { hello => 'world', list => [1, 2] }));
    is $res->status, 200, 'status 200';
    is JSON::MaybeXS::decode_json($res->content), { hello => 'world', list => [1, 2] }, 'the body decodes to the same data';
    is sent_headers($res), [['content-length', length $res->content], ['content-type', 'application/json']],
        'the length in bytes, and application/json with no charset: JSON is UTF-8 by definition';
};

subtest 'characters, encoded as UTF-8' => sub {
    is(PAGI::Response::JSON->new(content => { name => "\x{e9}" })->body, qq({"name":"\xc3\xa9"}),
        'e-acute as its two UTF-8 bytes, not escaped');
};

subtest 'any JSON value, not only an object or an array' => sub {
    is(PAGI::Response::JSON->new->body, 'null', 'no content: null');
    is(PAGI::Response::JSON->new(content => undef)->body, 'null', 'undef: null');
    is(PAGI::Response::JSON->new(content => 'plain')->body, '"plain"', 'a string');
    is(PAGI::Response::JSON->new(content => 42)->body, '42', 'a number');
};

subtest 'a type you give is sent as given' => sub {
    is(PAGI::Response::JSON->new(content => {}, content_type => 'application/problem+json')->content_type,
        'application/problem+json', 'yours, with no charset added');
};

subtest 'content JSON cannot carry dies at new, from the line that built it' => sub {
    my $line = __LINE__ + 1;
    my $error = dies { PAGI::Response::JSON->new(content => sub { 1 }) };
    like $error, qr/\Acontent can't be sent as JSON: encountered CODE/, "a code reference: JSON's reason";
    like $error, qr/at \Q${\ __FILE__ }\E line $line\.$/, 'the error names the line that built the response';
    like(dies { PAGI::Response::JSON->new(content => { when => bless {}, 'Local::Plain' }) },
        qr/\Acontent can't be sent as JSON: encountered object/, 'an object with no TO_JSON');
};

subtest 'content on its own is the arguments, not the content (the trap the POD shows)' => sub {
    is(PAGI::Response::JSON->new({ hello => 'world' })->body, 'null', 'a lone hash reference sends null');
    is(PAGI::Response::JSON->new(content => { hello => 'world' })->body, '{"hello":"world"}', 'by name, it is the content');
};

done_testing;
