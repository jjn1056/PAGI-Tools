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

subtest 'an explicit File ETag' => sub {
    require File::Temp;
    my ($fh, $file) = File::Temp::tempfile(UNLINK => 1);
    print {$fh} 'x';
    close $fh;
    my $etag_sent = sub {
        my ($start) = grep { $_->{type} eq 'http.response.start' }
            @{ PAGITest::Stringy::events_of(response('File', $file, etag => $_[0])) };
        return (map { $_->[1] } grep { lc $_->[0] eq 'etag' } @{ $start->{headers} })[0];
    };
    my $sent = $etag_sent->(Encode::decode('UTF-8', '"v1"'));
    is($sent, '"v1"', 'a flagged ASCII entity-tag is valid');
    ok(!utf8::is_utf8($sent), 'and sent as plain bytes');
    is(hex_of($etag_sent->(flagged(qq{W/"caf\xE9"}))), '57 2F 22 63 61 66 E9 22',
        'a flagged entity-tag with obs-text (RFC 9110) is sent as its bytes');
    like(dies { response('File', $file, etag => qq{"\x{263a}"}) }, qr/File response ETag must be a valid entity-tag/,
        'a wide character is not an entity-tag');
};

subtest 'WebSocket bytes' => sub {
    require PAGI::WebSocket;
    require PAGITest::Connected;
    my $connected = sub {
        my @sent;
        my $ws = PAGI::WebSocket->new(PAGITest::Connected::ws_scope(), sub { Future->done({ type => 'websocket.connect' }) },
            sub { push @sent, $_[0]; Future->done });
        $ws->accept->get;
        return ($ws, \@sent);
    };
    my ($ws, $sent) = $connected->();
    $ws->send_bytes(flagged("caf\xC3\xA9"))->get;
    is(hex_of($sent->[-1]{bytes}), '63 61 66 C3 A9', 'send_bytes sends flagged bytes as the same octets');
    ok(!utf8::is_utf8($sent->[-1]{bytes}), 'as plain bytes');

    my $wide_bytes = qr/send_bytes must be encoded bytes: it contains a character above 0xFF; encode text first, or use send_text/;
    like(dies { $ws->send_bytes("wide \x{263a}")->get }, $wide_bytes, 'send_bytes refuses a wide character');

    my @errors;
    $ws->on_error(sub { push @errors, $_[0] });
    is($ws->try_send_bytes("wide \x{263a}")->get, 0, 'try_send_bytes does not send it');
    like($errors[-1], $wide_bytes, 'and reports why');
};

done_testing;
