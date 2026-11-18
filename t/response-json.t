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

subtest 'content JSON cannot carry dies at new, with the encoder\'s own error' => sub {
    like(dies { PAGI::Response::JSON->new(content => sub { 1 }) }, qr/\Aencountered CODE/, 'a code reference');
    like(dies { PAGI::Response::JSON->new(content => { when => bless {}, 'Local::Plain' }) },
        qr/\Aencountered object/, 'an object with no TO_JSON');
};

{
    package Local::Fails;
    sub new { bless { error => $_[1] }, $_[0] }
    sub TO_JSON { die $_[0]{error} }
}

subtest 'a TO_JSON that dies: its own error, untouched' => sub {
    is(dies { PAGI::Response::JSON->new(content => { user => Local::Fails->new("no user today\n") }) },
        "no user today\n", 'a message');
    my $exception = bless { reason => 'gone' }, 'Local::Exception';
    is(dies { PAGI::Response::JSON->new(content => [Local::Fails->new($exception)]) }, exact_ref($exception),
        'an exception object, the same object');
};

{
    package Local::User;
    sub new { bless { name => $_[1], password => 'secret' }, $_[0] }
    sub TO_JSON { return { name => $_[0]{name} } }
}

subtest 'an object with TO_JSON is sent as what TO_JSON returns' => sub {
    is(PAGI::Response::JSON->new(content => { user => Local::User->new('ada') })->body, '{"user":{"name":"ada"}}',
        'its TO_JSON, which leaves the password out');
};

{
    package Local::SortedJSON;
    use parent -norequire, 'PAGI::Response::JSON';
    my $sorted = JSON::MaybeXS->new(utf8 => 1, canonical => 1);
    sub json_encoder { return $sorted }
}

subtest 'json_encoder: the encoder render uses, a subclass gives its own' => sub {
    my $encoder = PAGI::Response::JSON->json_encoder;
    is $encoder->encode({ name => "\x{e9}" }), qq({"name":"\xc3\xa9"}), 'the class encoder: UTF-8 bytes';
    is $encoder->encode(Local::User->new('ada')), '{"name":"ada"}', 'and TO_JSON';
    is(Local::SortedJSON->new(content => { b => 2, a => 1, c => 3 })->body, '{"a":1,"b":2,"c":3}',
        "a subclass's encoder is the one used: its keys sorted");
};

subtest 'content on its own is the arguments, not the content (the trap the POD shows)' => sub {
    is(PAGI::Response::JSON->new({ hello => 'world' })->body, 'null', 'a lone hash reference sends null');
    is(PAGI::Response::JSON->new(content => { hello => 'world' })->body, '{"hello":"world"}', 'by name, it is the content');
};

done_testing;
