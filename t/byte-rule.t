use strict;
use warnings;
use Test2::V0;
use Encode ();

use lib 't/lib';
use PAGITest::Stringy;
use PAGI::Request;
use PAGI::Response qw(response);
use PAGI::Response::Text;

# "Bytes" is every character <= 0xFF, whatever Perl's internal UTF-8 flag
# says: byte-range strings are accepted and sent as plain bytes, and a wide
# character is refused.

sub hex_of { join ' ', map { sprintf '%02X', ord } split //, $_[0] }
sub flagged { my ($s) = @_; utf8::upgrade($s); return $s }
my $wide = qr/must be encoded bytes: it contains a character above 0xFF; encode text first, or use Text or HTML/;

my %site = (
    'PAGI::Response->new' => sub { PAGITest::Stringy::body_of(PAGI::Response->new($_[0])) },
    'Stream write'        => sub { my ($v) = @_; PAGITest::Stringy::body_of(response('Stream', sub { $_[0]->write($v) })) },
);

for my $name (sort keys %site) {
    my $send = $site{$name};
    subtest $name => sub {
        my $decoded = Encode::decode('UTF-8', 'foo: bar');
        ok(utf8::is_utf8($decoded), 'the decoded string carries the flag');
        is($send->($decoded), 'foo: bar', 'decoded ASCII is sent as its bytes');

        my $sent = $send->(flagged("caf\xC3\xA9"));
        is(hex_of($sent), '63 61 66 C3 A9', 'flagged UTF-8 bytes are sent as the same octets');
        ok(!utf8::is_utf8($sent), 'as plain bytes');

        is(hex_of($send->("caf\xE9")), '63 61 66 E9', 'an unflagged byte string is unchanged');

        like(dies { $send->("wide \x{263a}") }, $wide, 'a wide character is refused, naming the fix');
        like(dies { $send->(PAGITest::Stringy::Overloaded->new("wide \x{263a}")) }, $wide,
            'so is an object whose string is wide');
    };
}

subtest "bbrtj's case: text from decoded request parameters" => sub {
    my $body = sub {
        my ($query) = @_;
        my $request = PAGI::Request->new({ type => 'http', method => 'GET', path => '/get',
            raw_path => '/get', query_string => $query, headers => [] }, sub { Future->done });
        return 'foo: ' . $request->query_params->get('foo');
    };
    is(PAGITest::Stringy::body_of(PAGI::Response->new($body->('foo=bar'))), 'foo: bar',
        'ASCII text through the byte API is sent');
    is(hex_of(PAGITest::Stringy::body_of(PAGI::Response->new($body->('foo=caf%C3%A9')))),
        '66 6F 6F 3A 20 63 61 66 E9', 'non-ASCII text through the byte API goes out as Latin-1, as documented');
    is(hex_of(PAGITest::Stringy::body_of(PAGI::Response::Text->new($body->('foo=caf%C3%A9')))),
        '66 6F 6F 3A 20 63 61 66 C3 A9', 'Text sends it as UTF-8');
};

done_testing;
