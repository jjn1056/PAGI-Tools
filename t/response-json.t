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

# What the encoder dies with, on every backend JSON::MaybeXS picks: its own
# words, not ours.
my $OBJECT = qr/\Aencountered object '/;

subtest 'content JSON cannot carry dies at new, with the encoder\'s own error' => sub {
    like(dies { PAGI::Response::JSON->new(content => sub { 1 }) }, qr/\Aencountered CODE/, 'a code reference');
    like(dies { PAGI::Response::JSON->new(content => { when => bless {}, 'Local::Plain' }) }, $OBJECT,
        'an object of a class with no subs');
};

{
    package Local::Row;
    sub new { bless { id => 1 }, shift }
    sub id  { $_[0]{id} }
}

{
    package Local::User;
    my $called = 0;
    sub new { bless { name => $_[1], password => 'secret' }, $_[0] }
    sub TO_JSON { $called++; return { name => $_[0]{name} } }
    sub called { $called }
}

{
    package Local::Stringy;
    use overload '""' => sub { 'a string' };
    sub new { bless {}, shift }
}

subtest 'objects are not data: each dies, the first time, whatever it has' => sub {
    like(dies { PAGI::Response::JSON->new(content => { row => Local::Row->new }) }, $OBJECT,
        'an object of a class with methods: dies the first time, not null');
    like(dies { PAGI::Response::JSON->new(content => { user => Local::User->new('ada') }) }, $OBJECT,
        'an object with TO_JSON dies too: nothing is coerced');
    is(Local::User->called, 0, 'and its TO_JSON is never called');
    like(dies { PAGI::Response::JSON->new(content => [Local::Stringy->new]) }, $OBJECT,
        'an object that stringifies: not stringified');
};

{
    package Local::ObjectJSON;    # the POD's example, as written
    use parent -norequire, 'PAGI::Response::JSON';
    sub json_encoder { return JSON::PP->new->utf8->allow_nonref->convert_blessed }
}

{
    package Local::Refusing;
    sub new { bless { error => $_[1] }, $_[0] }
    sub TO_JSON { die $_[0]{error} }
}

subtest 'an encoder of your own that converts objects' => sub {
    require JSON::PP;
    is(Local::ObjectJSON->new(content => [Local::User->new('ada')])->body, '[{"name":"ada"}]', 'through TO_JSON');
    like(dies { Local::ObjectJSON->new(content => [Local::Row->new]) }, $OBJECT, 'one without TO_JSON still dies');
    my $exception = bless { reason => 'gone' }, 'Local::Exception';
    is(dies { Local::ObjectJSON->new(content => [Local::Refusing->new($exception)]) }, exact_ref($exception),
        "an exception object its TO_JSON throws goes on as it is");
};

{
    package Local::FriendlyJSON;    # the POD's example of encode_json, as written
    use parent -norequire, 'PAGI::Response::JSON';
    sub encode_json {
        my ($self, $data) = @_;
        my $json = eval { $self->SUPER::encode_json($data) };
        return $json if defined $json;
        die "Send plain data: flatten objects first ($@)";
    }
}

subtest 'encode_json: the hook every body is encoded through' => sub {
    is(PAGI::Response::JSON->new(content => { a => 1 })->encode_json([1, 'two']), '[1,"two"]',
        'the content as JSON, with json_encoder');
    is(Local::FriendlyJSON->new(content => { a => 1 })->body, '{"a":1}', 'a subclass of it encodes as before');
    like(dies { Local::FriendlyJSON->new(content => [Local::Row->new]) },
        qr/\ASend plain data: flatten objects first \(encountered object '/, 'and can say its own thing on failure');
};

subtest 'JSON::MaybeXS is loaded only when the default encoder is made' => sub {
    my $perl = $^X;
    my $loaded = `"$perl" -Ilib -e "use PAGI::Response::JSON; print \\\$INC{'JSON/MaybeXS.pm'} ? 'yes' : 'no'"`;
    is $loaded, 'no', 'not by loading the class';
    $loaded = `"$perl" -Ilib -e "use PAGI::Response::JSON; PAGI::Response::JSON->json_encoder; print \\\$INC{'JSON/MaybeXS.pm'} ? 'yes' : 'no'"`;
    is $loaded, 'yes', 'by json_encoder';
};

subtest 'booleans are data' => sub {
    is(PAGI::Response::JSON->new(content => [JSON::MaybeXS::true(), JSON::MaybeXS::false(), \1, \0])->body,
        '[true,false,true,false]', "JSON's booleans, and \\1 and \\0");
};

{
    package Local::SortedJSON;
    use parent -norequire, 'PAGI::Response::JSON';
    sub json_encoder { return JSON::MaybeXS->new(utf8 => 1, canonical => 1) }
}

subtest 'json_encoder: the encoder the body is made with, a subclass gives its own' => sub {
    my $encoder = PAGI::Response::JSON->json_encoder;
    is $encoder->encode({ name => "\x{e9}" }), qq({"name":"\xc3\xa9"}), 'the class encoder: UTF-8 bytes';
    {
        package Local::ConvertingJSON;
        use parent -norequire, 'PAGI::Response::JSON';
        sub json_encoder { return JSON::MaybeXS->new(utf8 => 1, convert_blessed => 1) }
    }
    is(Local::ConvertingJSON->new(content => { user => Local::User->new('ada') })->body, '{"user":{"name":"ada"}}',
        'an encoder of your own can convert objects: here, through TO_JSON');
    is(Local::SortedJSON->new(content => { b => 2, a => 1, c => 3 })->body, '{"a":1,"b":2,"c":3}',
        "a subclass's encoder is the one used: its keys sorted");
    PAGI::Response::JSON->json_encoder->pretty(1);
    is(PAGI::Response::JSON->new(content => { a => 1 })->body, '{"a":1}',
        'a new encoder each time: changing one changes no other response');
};

subtest 'content on its own is the arguments, not the content (the trap the POD shows)' => sub {
    is(PAGI::Response::JSON->new({ hello => 'world' })->body, 'null', 'a lone hash reference sends null');
    is(PAGI::Response::JSON->new(content => { hello => 'world' })->body, '{"hello":"world"}', 'by name, it is the content');
};

done_testing;
