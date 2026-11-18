use v5.24;
use warnings;
use Test2::V0;
use PAGI::Test::Client;
use Test::Lib;
use PAGITest::LowercaseHeaders;

use PAGI::Response::Text;

# Serves a response for one GET, as a strict server would.
sub get { PAGI::Test::Client->new(app => $_[0])->get('/') }

# The headers the response sent: all but the Date the client adds, as a server does.
sub sent_headers { [grep { $_->[0] ne 'date' } @{ $_[0]->header_pairs }] }

{
    package Local::Name;
    use overload '""' => sub { "Jos\x{e9}" };
    sub new { bless {}, shift }
}

{
    package Local::Broken;
    use overload q{""} => sub { die "no name today\n" };
    sub new { bless {}, shift }
}

subtest 'characters, sent as UTF-8' => sub {
    my $res = get(PAGI::Response::Text->new(content => "Hello, \x{1F30D}\n"));
    is $res->status, 200, 'status 200';
    is $res->content, "Hello, \xF0\x9F\x8C\x8D\n", 'the body is the UTF-8 bytes';
    is sent_headers($res),
        [['content-length', 12], ['content-type', 'text/plain; charset=utf-8']],
        'the length in bytes, and the type naming the charset';
};

subtest 'a character below 256 is a character, not a byte' => sub {
    my $res = get(PAGI::Response::Text->new(content => "caf\x{e9}"));
    is $res->content, "caf\xc3\xa9", 'e-acute as its two UTF-8 bytes';
    is sent_headers($res)->[0], ['content-length', 5], 'length 5';
};

subtest 'no content' => sub {
    my $res = get(PAGI::Response::Text->new);
    is $res->content, '', 'an empty body';
    is sent_headers($res),
        [['content-length', 0], ['content-type', 'text/plain; charset=utf-8']],
        'length 0, the type';
};

subtest 'a text type you give says the body is UTF-8, as Starlette does' => sub {
    my $type = sub { PAGI::Response::Text->new(content => 'hi', @_)->content_type };
    is $type->(content_type => 'text/html'), 'text/html; charset=utf-8', 'a text/* type: the charset added';
    is sent_headers(get(PAGI::Response::Text->new(content => '<p>hi</p>', content_type => 'text/html')))->[1],
        ['content-type', 'text/html; charset=utf-8'], 'and sent so';
    is $type->(content_type => 'text/csv; charset=iso-8859-1'), 'text/csv; charset=iso-8859-1',
        'one that names a charset: as given';
    is $type->(content_type => 'application/xml'), 'application/xml', 'not text/*: as given';
    my $none;
    ok no_warnings { $none = $type->(content_type => undef) }, 'undef: no warning';
    is $none, undef, 'undef: none';
    is sent_headers(get(PAGI::Response::Text->new(content => 'hi', headers => [['Content-Type', 'text/html']]))),
        [['content-type', 'text/html'], ['content-length', 2]], 'a Content-Type in headers: as given';
};

subtest 'an object that stringifies: its string, encoded' => sub {
    is(PAGI::Response::Text->new(content => Local::Name->new)->body, "Jos\xc3\xa9", 'the string, as UTF-8');
};

subtest 'content that is not text dies at new' => sub {
    like(dies { PAGI::Response::Text->new(content => []) }, qr/pass a string/, 'an array reference');
    like(dies { PAGI::Response::Text->new(content => bless {}, 'Local::Plain') }, qr/pass a string/,
        'an object that does not stringify');
    is(dies { PAGI::Response::Text->new(content => Local::Broken->new) }, "no name today\n",
        "an object whose stringification dies: its own error, untouched");
    like(dies { PAGI::Response::Text->new(content => "\x{D800}") }, qr/\A"\\x\{d800\}" does not map to UTF-8 at /,
        "a surrogate is not a character UTF-8 can carry: Encode's own error");
};

{
    package Local::CSV;
    use parent -norequire, 'PAGI::Response::Text';
    sub as_text { my ($self, $rows) = @_; join '', map { join(',', @$_) . "\r\n" } @$rows }
}

{
    package Local::Replacing;
    use Encode ();
    use parent -norequire, 'PAGI::Response::Text';
    sub encode_text { my ($self, $text) = @_; Encode::encode('UTF-8', $text) }
}

subtest 'as_text and encode_text: the body in two steps, a subclass overrides either' => sub {
    is(PAGI::Response::Text->as_text(undef), '', 'as_text: no content is empty');
    is(PAGI::Response::Text->as_text(Local::Name->new), "Jos\x{e9}", 'as_text: an object that stringifies, as characters');
    like(dies { PAGI::Response::Text->as_text([]) }, qr/pass a string/, 'as_text: any other reference dies');
    is(PAGI::Response::Text->encode_text("Jos\x{e9}"), "Jos\xc3\xa9", 'encode_text: characters as UTF-8 bytes');
    like(dies { PAGI::Response::Text->encode_text("\x{D800}") }, qr/does not map to UTF-8/,
        "encode_text: a character UTF-8 can't carry dies");
    is(Local::CSV->new(content => [['id', 'name'], [1, "Jos\x{e9}"]])->body, "id,name\r\n1,Jos\xc3\xa9\r\n",
        "a subclass's as_text makes the text, which Text encodes");
    is(Local::Replacing->new(content => "a\x{D800}b")->body, "a\xef\xbf\xbdb",
        "a subclass's encode_text is the one used: a replacement character instead of dying");
};

done_testing;
