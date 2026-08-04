use strict;
use warnings;
use Test2::V0;
use PAGI::Authority;

subtest 'validate preserves accepted authority spellings' => sub {
    my @valid = (
        'example.com',
        'Example.COM',
        'localhost',
        'api_v1.example',
        'example.com.',
        '192.0.2.1',
        '[2001:db8::1]',
        'example.com:80',
        'example.com:00080',
        '[2001:db8::1]:443',
    );

    for my $case (@valid) {
        is(
            PAGI::Authority->validate($case),
            $case,
            "valid authority is preserved: $case",
        );
    }
};

subtest 'validate rejects unsafe or malformed authority input' => sub {
    my @invalid = (
        [undef, 'undefined value'],
        [\'example.com', 'reference'],
        ['', 'empty value'],
        [' example.com', 'leading whitespace'],
        ["example.com\t", 'control character'],
        ["example.\N{U+00E9}", 'non-ASCII'],
        ['example.com/path', 'path delimiter'],
        ['example.com?query', 'query delimiter'],
        ['example.com#fragment', 'fragment delimiter'],
        ['user@example.com', 'userinfo delimiter'],
        ['example.com,evil.example', 'list delimiter'],
        ['example.com;param', 'parameter delimiter'],
        ['.example.com', 'empty first label'],
        ['example..com', 'consecutive labels'],
        ['[2001:db8::1', 'missing closing bracket'],
        ['2001:db8::1]', 'stray closing bracket'],
        ['[2001:db8::1]]', 'extra closing bracket'],
        ['2001:db8::1', 'unbracketed IPv6'],
        ['[fe80::1%eth0]', 'IPv6 zone ID'],
        ['[v1.fe80::]', 'IPvFuture'],
        ['127.1', 'abbreviated IPv4'],
        ['2130706433', 'decimal IPv4 integer'],
        ['01.2.3.4', 'noncanonical IPv4 octet'],
        ['256.1.1.1', 'out-of-range IPv4 octet'],
        ['example.com:', 'empty port'],
        ['example.com:http', 'nondigit port'],
        ['example.com:65536', 'out-of-range port'],
    );
    my @forbidden_delimiters = (
        '!', '"', '#', '$', '%', '&', q{'}, '(', ')', '*', '+', ',', '/', ';',
        '<', '=', '>', '?', '@', '\\', '^', '`', '{', '|', '}',
    );
    push @invalid, map {
        ["example${_}com", "forbidden delimiter $_"]
    } @forbidden_delimiters;

    for my $case (@invalid) {
        like(
            dies { PAGI::Authority->validate($case->[0]) },
            qr/invalid authority/,
            "invalid authority is rejected: $case->[1]",
        );
    }
};

subtest 'host_from_scope validates raw Host header cardinality and leaves scope unchanged' => sub {
    my $absent = { headers => [['X-Forwarded-Host', 'not-used.example']] };
    is(PAGI::Authority->host_from_scope($absent), undef, 'absent Host is absent');

    my $one = { headers => [['hOsT', 'Example.COM:443']] };
    is(PAGI::Authority->host_from_scope($one), 'Example.COM:443', 'mixed-case Host is used verbatim');

    for my $headers (
        [['Host', 'same.example'], ['host', 'same.example']],
        [['Host', 'good.example'], ['HOST', 'evil.example']],
    ) {
        like(
            dies { PAGI::Authority->host_from_scope({ headers => $headers }) },
            qr/Host header must occur at most once/,
            'duplicate Host is rejected before considering its value',
        );
    }

    for my $bad_scope (
        { headers => [['Host', undef]] },
        { headers => ['Host'] },
        { headers => [['Host']] },
        { headers => [['Host', 'good.example', 'extra']] },
        { headers => [[undef, 'good.example']] },
        { headers => [[[], 'good.example']] },
        { headers => {} },
    ) {
        like(
            dies { PAGI::Authority->host_from_scope($bad_scope) },
            qr/scope headers must be an arrayref of pairs/,
            'malformed raw header shape is rejected',
        );
    }

    like(
        dies { PAGI::Authority->host_from_scope([]) },
        qr/authority scope must be a hashref/,
        'scope must be a hashref',
    );

    my $scope = {
        headers => [['hOsT', 'Example.COM:443'], ['X-Other', 'value']],
        server  => ['fallback.example', 443],
    };
    my $before = {
        headers => [['hOsT', 'Example.COM:443'], ['X-Other', 'value']],
        server  => ['fallback.example', 443],
    };
    is(PAGI::Authority->host_from_scope($scope), 'Example.COM:443', 'Host is extracted');
    is($scope, $before, 'Host extraction does not mutate its input');
};

subtest 'from_scope prefers Host and only falls back when Host is absent' => sub {
    is(
        PAGI::Authority->from_scope({
            headers => [['Host', 'header.example:8443']],
            server  => ['fallback.example', 443],
            scheme  => 'https',
        }),
        'header.example:8443',
        'valid Host wins over server',
    );

    my $duplicate = {
        scheme  => 'https',
        headers => [['Host', 'good.example'], ['host', 'evil.example']],
        server  => ['fallback.example', 443],
    };
    like(
        dies { PAGI::Authority->from_scope($duplicate) },
        qr/Host header must occur at most once/,
        'duplicate Host cannot fall back to server',
    );

    like(
        dies { PAGI::Authority->from_scope({
            headers => [['Host', 'bad.example:65536']],
            server  => ['fallback.example', 443],
        }) },
        qr/invalid authority/,
        'malformed Host cannot fall back to server',
    );
};

subtest 'from_scope formats valid server fallbacks' => sub {
    my @cases = (
        [{ server => ['example.com'] }, 'example.com', 'hostname without port'],
        [{ server => ['192.0.2.1', 8080] }, '192.0.2.1:8080', 'IPv4 with port'],
        [{ server => ['2001:db8::1', 8443] }, '[2001:db8::1]:8443', 'unbracketed IPv6 becomes bracketed'],
        [{ server => ['[2001:db8::1]', 8443] }, '[2001:db8::1]:8443', 'bracketed IPv6 is preserved'],
        [{ scheme => 'http', server => ['example.com', 80] }, 'example.com', 'HTTP default port is omitted'],
        [{ scheme => 'ws', server => ['example.com', 80] }, 'example.com', 'WebSocket default port is omitted'],
        [{ scheme => 'https', server => ['example.com', 443] }, 'example.com', 'HTTPS default port is omitted'],
        [{ scheme => 'wss', server => ['example.com', 443] }, 'example.com', 'secure WebSocket default port is omitted'],
        [{ server => ['example.com', 80] }, 'example.com', 'missing scheme defaults to HTTP'],
        [{ scheme => 'ftp', server => ['example.com', 80] }, 'example.com:80', 'unknown scheme retains defined port'],
        [{ scheme => 'https', server => ['example.com', 0] }, 'example.com:0', 'zero is a real port'],
        [{ scheme => 'https', server => ['example.com', 80] }, 'example.com:80', 'nondefault port is retained'],
        [{ scheme => 'http', server => ['example.com', 443] }, 'example.com:443', 'other standard port is retained'],
        [{ scheme => 'http', server => ['example.com', 8443] }, 'example.com:8443', 'alternate port is retained'],
    );

    for my $case (@cases) {
        is(PAGI::Authority->from_scope($case->[0]), $case->[1], $case->[2]);
    }

    my $scope = { scheme => 'https', server => ['2001:db8::1', 8443] };
    my $before = { scheme => 'https', server => ['2001:db8::1', 8443] };
    is(PAGI::Authority->from_scope($scope), '[2001:db8::1]:8443',
        'server fallback is formatted');
    is($scope, $before, 'server fallback does not mutate its input');
};

subtest 'from_scope rejects unusable server fallback' => sub {
    for my $scope (
        {},
        { server => undef },
        { server => 'example.com' },
        { server => [] },
        { server => ['example.com', 80, 'extra'] },
        { server => [undef] },
        { server => [\'example.com'] },
        { server => ['bad..example'] },
        { server => ['[2001:db8::1'] },
        { server => ['example.com', undef] },
        { server => ['example.com', ''] },
        { server => ['example.com', '80x'] },
        { server => ['example.com', 65536] },
    ) {
        like(
            dies { PAGI::Authority->from_scope($scope) },
            qr/scope server cannot provide an authority/,
            'unusable server fallback is rejected',
        );
    }
};

done_testing;
