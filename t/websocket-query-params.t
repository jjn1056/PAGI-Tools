use strict;
use warnings;
use Test2::V0;

use PAGI::WebSocket;
use lib 't/lib';
use PAGITest::Connected qw(ws_scope);

# Mock receive/send for WebSocket constructor
my $receive = sub { Future->done({ type => 'websocket.receive', text => '{}' }) };
my $send = sub { Future->done };

# Helper to create WebSocket with query string
sub make_ws {
    my ($query_string, %extra) = @_;
    my $scope = ws_scope(
        path         => '/ws/chat',
        query_string => $query_string // '',
        %extra,
    );
    return PAGI::WebSocket->new($scope, $receive, $send);
}

subtest 'query_params basic parsing' => sub {
    my $ws = make_ws('user=alice&room=general');

    my $params = $ws->query_params;
    isa_ok($params, ['Hash::MultiValue'], 'query_params returns Hash::MultiValue');
    is($params->get('user'), 'alice', 'parses user param');
    is($params->get('room'), 'general', 'parses room param');
};

subtest 'query_param shortcut' => sub {
    my $ws = make_ws('user=bob&count=42');

    is($ws->query_param('user'), 'bob', 'query_param returns single param');
    is($ws->query_param('count'), '42', 'query_param returns numeric string');
    is($ws->query_param('missing'), undef, 'query_param returns undef for missing param');
};

subtest 'URL decoding' => sub {
    my $ws = make_ws('name=John%20Doe&msg=hello+world&special=%26%3D%3F');

    is($ws->query_param('name'), 'John Doe', 'decodes %20 as space');
    is($ws->query_param('msg'), 'hello world', 'decodes + as space');
    is($ws->query_param('special'), '&=?', 'decodes special characters');
};

subtest 'UTF-8 decoding' => sub {
    # UTF-8 encoded "cafe" with accent: caf%C3%A9
    my $ws = make_ws('word=caf%C3%A9&emoji=%F0%9F%8E%89');

    is($ws->query_param('word'), "caf\x{e9}", 'decodes UTF-8 characters');
    is($ws->query_param('emoji'), "\x{1F389}", 'decodes emoji');
};

subtest 'raw mode skips UTF-8 decoding' => sub {
    my $ws = make_ws('word=caf%C3%A9');

    my $raw = $ws->query_param('word', raw => 1);
    is($raw, "caf\xC3\xA9", 'raw mode returns bytes');

    my $raw_params = $ws->raw_query_params;
    is($raw_params->get('word'), "caf\xC3\xA9", 'raw_query_params returns bytes');

    is($ws->raw_query_param('word'), "caf\xC3\xA9", 'raw_query_param returns bytes');
};

subtest 'multiple values for same key' => sub {
    my $ws = make_ws('tag=perl&tag=async&tag=websocket');

    my $params = $ws->query_params;
    # Hash::MultiValue->get returns the LAST value
    is($params->get('tag'), 'websocket', 'get returns last value');

    my @all = $params->get_all('tag');
    is(\@all, ['perl', 'async', 'websocket'], 'get_all returns all values in order');
};

subtest 'empty and missing values' => sub {
    my $ws = make_ws('empty=&flag&normal=value');

    is($ws->query_param('empty'), '', 'empty value returns empty string');
    is($ws->query_param('flag'), '', 'key without = returns empty string');
    is($ws->query_param('normal'), 'value', 'normal key=value works');
};

subtest 'empty query string' => sub {
    my $ws = make_ws('');

    my $params = $ws->query_params;
    isa_ok($params, ['Hash::MultiValue'], 'returns Hash::MultiValue for empty query');
    is($ws->query_param('anything'), undef, 'query_param returns undef for empty query string');
};

subtest 'semicolon delimiter' => sub {
    # Some systems use ; instead of & as delimiter
    my $ws = make_ws('a=1;b=2&c=3');

    is($ws->query_param('a'), '1', 'parses with semicolon');
    is($ws->query_param('b'), '2', 'parses after semicolon');
    is($ws->query_param('c'), '3', 'parses with ampersand');
};

subtest 'cached on the object, not in the scope' => sub {
    my $scope = ws_scope(
        path         => '/ws',
        query_string => 'x=1',
    );
    my $ws = PAGI::WebSocket->new($scope, $receive, $send);

    my $decoded = $ws->query_params;
    is($ws->query_params, exact_ref($decoded), 'query_params parsed once per object');

    my $raw = $ws->query_params(raw => 1);
    is($ws->query_params(raw => 1), exact_ref($raw), 'raw query_params kept separately');
    isnt($raw, exact_ref($decoded), 'raw and decoded are different parses');

    is([grep { /^pagi\.websocket\.query/ } keys %$scope], [], 'nothing is written to the scope');
};

subtest 'strict mode dies on invalid UTF-8' => sub {
    # Invalid UTF-8 sequence: %FF is not valid
    my $ws = make_ws('bad=%FF%FE');

    # Non-strict mode replaces with replacement character
    my $result = $ws->query_param('bad');
    ok(defined $result, 'non-strict mode handles invalid UTF-8');

    # Create fresh scope for strict test (caching)
    my $ws2 = make_ws('bad=%FF%FE');
    like(
        dies { $ws2->query_param('bad', strict => 1) },
        qr/./,  # Any error is fine
        'strict mode dies on invalid UTF-8'
    );
};

subtest 'unknown options rejected' => sub {
    my $ws = make_ws('x=1');

    like(
        dies { $ws->query_params(invalid_option => 1) },
        qr/Unknown options.*invalid_option/,
        'query_params rejects unknown options'
    );
};

subtest 'query and raw_query are gone' => sub {
    ok(!PAGI::WebSocket->can($_), "PAGI::WebSocket has no $_") for qw(query raw_query);
};

done_testing;
