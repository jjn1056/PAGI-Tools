use strict;
use warnings;

use Test2::V0;
use Encode qw(decode FB_CROAK);
use Future;
use JSON::MaybeXS qw(decode_json);

use PAGI::Pages;

my @NAMED_ERRORS = qw(
    bad_request unauthorized payment_required forbidden not_found
    method_not_allowed not_acceptable proxy_authentication_required
    request_timeout conflict gone length_required precondition_failed
    content_too_large uri_too_long unsupported_media_type
    range_not_satisfiable expectation_failed misdirected_request
    unprocessable_content locked failed_dependency too_early
    upgrade_required precondition_required too_many_requests
    request_header_fields_too_large unavailable_for_legal_reasons
    internal_server_error not_implemented bad_gateway service_unavailable
    gateway_timeout http_version_not_supported variant_also_negotiates
    insufficient_storage loop_detected network_authentication_required
);

sub http_scope {
    my (%args) = @_;
    return {
        type         => 'http',
        method       => 'GET',
        path         => '/',
        headers      => [],
        http_version => exists($args{version}) ? $args{version} : '1.1',
        query_string => '',
    };
}

sub send_response {
    my ($response) = @_;
    my @events;
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    Future->wrap($response->respond($send))->get;
    return \@events;
}

sub response_body {
    my ($response) = @_;
    my $events = send_response($response);
    return $events->[1]{body};
}

subtest 'semantic status fields are normalized exactly' => sub {
    my @field_cases = (
        [unauthorized => { challenge => 'Basic realm="x"' },
         'WWW-Authenticate', 'Basic realm="x"'],
        [method_not_allowed => { allow => ['get', 'HEAD', 'GET'] },
         'Allow', 'GET, HEAD'],
        [range_not_satisfiable => { length => 42 },
         'Content-Range', 'bytes */42'],
        [upgrade_required => { upgrade => ['websocket', 'h2c'] },
         'Upgrade', 'websocket, h2c'],
        [unavailable_for_legal_reasons => { blocked_by => '/authority' },
         'Link', '</authority>; rel="blocked-by"'],
        [network_authentication_required => { login_url => '/login' },
         undef, undef],
    );

    for my $case (@field_cases) {
        my ($method, $options, $name, $want) = @$case;
        my $response;
        is(dies {
            $response = PAGI::Pages->$method(
                http_scope(), as => 'text', %$options,
            );
        }, undef, "$method accepts its semantic option");
        next unless $response;
        if (defined $name) {
            is($response->header($name), $want,
                "$method emits its normalized semantic field");
        }
    }

    my $empty = PAGI::Pages->method_not_allowed(
        http_scope(), as => 'text', allow => [],
    );
    is([$empty->header_all('Allow')], [''],
        '405 emits one legal empty Allow field');

    my $multiple = PAGI::Pages->unauthorized(
        http_scope(), as => 'text',
        challenge => ['Basic realm="one"', 'Bearer realm="two"'],
    );
    is([$multiple->header_all('WWW-Authenticate')], [
        'Basic realm="one"', 'Bearer realm="two"',
    ], 'multiple authentication challenges remain separate field lines');
};

subtest 'mandatory fields can come from validated raw headers' => sub {
    my @raw_cases = (
        [unauthorized => ['wWw-AuThEnTiCaTe' => 'Basic realm="raw"'],
            'WWW-Authenticate', ['Basic realm="raw"']],
        [proxy_authentication_required => [
            'Proxy-Authenticate' => 'Basic realm="one"',
            'proxy-authenticate' => 'Bearer realm="two"',
        ], 'Proxy-Authenticate', ['Basic realm="one"', 'Bearer realm="two"']],
        [method_not_allowed => [
            Allow => 'get, HEAD', allow => 'GET, post',
        ], 'Allow', ['GET, HEAD, POST']],
        [upgrade_required => [Upgrade => 'websocket'],
            'Upgrade', ['websocket']],
    );

    for my $case (@raw_cases) {
        my ($method, $headers, $name, $want) = @$case;
        my $response = PAGI::Pages->$method(
            http_scope(), as => 'text', headers => $headers,
        );
        is([$response->header_all($name)], $want,
            "$method accepts and preserves its raw mandatory field");
    }

    my $mixed = PAGI::Pages->unauthorized(
        http_scope(), as => 'text',
        challenge => 'Basic realm="semantic"',
        headers => ['WWW-Authenticate' => 'Bearer realm="raw"'],
    );
    is([$mixed->header_all('WWW-Authenticate')], [
        'Bearer realm="raw"', 'Basic realm="semantic"',
    ], 'raw and semantic challenges coexist as separate field lines');
};

subtest 'mandatory fields and Upgrade request versions are enforced' => sub {
    my @missing = (
        [unauthorized => qr/WWW-Authenticate|challenge/],
        [method_not_allowed => qr/Allow|allow/],
        [proxy_authentication_required => qr/Proxy-Authenticate|challenge/],
        [upgrade_required => qr/Upgrade|upgrade/],
    );
    for my $case (@missing) {
        my ($method, $error) = @$case;
        like(dies { PAGI::Pages->$method(as => 'text') }, $error,
            "$method rejects missing mandatory information");
    }

    my @blank_challenges = (
        [unauthorized => [challenge => '   '], 'semantic 401'],
        [proxy_authentication_required => [challenge => '   '], 'semantic 407'],
        [unauthorized => [headers => ['WWW-Authenticate' => '   ']], 'raw 401'],
        [proxy_authentication_required => [
            headers => ['Proxy-Authenticate' => '   '],
        ], 'raw 407'],
    );
    for my $case (@blank_challenges) {
        my ($method, $args, $label) = @$case;
        like(dies { PAGI::Pages->$method(@$args) }, qr/nonempty|challenge/i,
            "$label rejects an OWS-only authentication challenge");
    }

    my $default_version = {
        type => 'http', method => 'GET', path => '/', headers => [],
        query_string => '',
    };
    my $default = PAGI::Pages->upgrade_required(
        $default_version, as => 'text', upgrade => 'websocket',
    );
    is($default->header('Connection'), 'Upgrade',
        'an absent HTTP version uses the request default of HTTP/1.1');

    for my $version ('1.0', '2', '3') {
        my @events;
        my $endpoint = PAGI::Pages->upgrade_required(
            as => 'text', upgrade => 'websocket',
        );
        like(dies {
            $endpoint->(
                http_scope(version => $version),
                sub { Future->done },
                sub { push @events, $_[0]; return Future->done },
            );
        }, qr/HTTP\/1\.1|version|Upgrade/i,
            "426 rejects explicit HTTP/$version");
        is(\@events, [], "HTTP/$version validation happens before response start");
    }
};

subtest 'single-valued semantic and raw fields cannot conflict' => sub {
    my @conflicts = (
        [method_not_allowed => [allow => 'GET',
            headers => [Allow => 'POST']]],
        [range_not_satisfiable => [length => 42,
            headers => ['Content-Range' => 'bytes */20']]],
        [upgrade_required => [upgrade => 'websocket',
            headers => [Upgrade => 'h2c']]],
        [content_too_large => [retry_after => 30,
            headers => ['Retry-After' => '60']]],
        [unavailable_for_legal_reasons => [blocked_by => '/one',
            headers => [Link => '</two>; rel="blocked-by"']]],
    );
    for my $case (@conflicts) {
        my ($method, $args) = @$case;
        like(dies { PAGI::Pages->$method(@$args) }, qr/conflict|both|raw/i,
            "$method rejects semantic/raw field conflict");
    }
};

subtest 'Retry-After accepts delay seconds and canonical IMF-fixdate only' => sub {
    my $delay = PAGI::Pages->too_many_requests(
        http_scope(), as => 'text', retry_after => 17,
    );
    is($delay->header('Retry-After'), '17',
        'non-negative delay seconds are emitted');

    my $date = 'Sun, 06 Nov 1994 08:49:37 GMT';
    my $dated = PAGI::Pages->service_unavailable(
        http_scope(), as => 'text', retry_after => $date,
    );
    is($dated->header('Retry-After'), $date,
        'canonical IMF-fixdate is preserved');

    for my $bad (
        -1,
        'Sunday, 06-Nov-94 08:49:37 GMT',
        'Sun Nov  6 08:49:37 1994',
        'Sun, 32 Nov 1994 08:49:37 GMT',
        'tomorrow',
    ) {
        like(dies {
            PAGI::Pages->content_too_large(retry_after => $bad)
        }, qr/Retry-After|retry_after|IMF-fixdate/i,
            "invalid or obsolete Retry-After '$bad' is rejected");
    }
};

subtest 'semantic values reject malformed shapes without numeric truncation' => sub {
    my $large = '123456789012345678901234567890';
    my $range = PAGI::Pages->range_not_satisfiable(
        http_scope(), as => 'text', length => $large,
    );
    is($range->header('Content-Range'), 'bytes */' . $large,
        'large non-negative lengths remain exact decimal wire values');

    my @bad = (
        [unauthorized => [challenge => ''], qr/challenge/i],
        [unauthorized => [challenge => {}], qr/challenge/i],
        [method_not_allowed => [allow => ['GET', 'bad method']], qr/token/i],
        [range_not_satisfiable => [length => -1], qr/non-negative integer/i],
        [range_not_satisfiable => [length => '1.5'], qr/non-negative integer/i],
        [upgrade_required => [upgrade => []], qr/at least one token/i],
        [unavailable_for_legal_reasons => [blocked_by => '/bad>target'],
            qr/delimiter/i],
        [network_authentication_required => [login_url => "bad login"],
            qr/URI-reference/i],
    );
    for my $case (@bad) {
        my ($method, $args, $error) = @$case;
        like(dies { PAGI::Pages->$method(@$args) }, $error,
            "$method rejects malformed $args->[0]");
    }
};

subtest 'semantic options are accepted only by their relevant statuses' => sub {
    my @unrelated = (
        [challenge => 'Basic realm="x"'],
        [allow => 'GET'],
        [length => 1],
        [upgrade => 'websocket'],
        [retry_after => 1],
        [blocked_by => '/authority'],
        [login_url => '/login'],
    );
    for my $args (@unrelated) {
        like(dies { PAGI::Pages->bad_request(@$args) }, qr/not valid|unrelated|option/i,
            "$args->[0] is rejected for an unrelated status");
    }
};

subtest 'raw headers are fully validated before entering the response' => sub {
    for my $owned (
        'cOnTeNt-TyPe', 'CONTENT-length', 'Transfer-Encoding',
        'lOcAtIoN', 'cache-CONTROL', 'ConNection',
    ) {
        like(dies {
            PAGI::Pages->not_found(headers => [$owned => 'value'])
        }, qr/response-owned/, "$owned is rejected case-insensitively");
    }

    my @bad_values = (
        ["one\r\nInjected: yes", 'CRLF'],
        ["one\x09two", 'control'],
        ["wide \x{2603}", 'wide character'],
        [[], 'reference'],
    );
    for my $case (@bad_values) {
        my ($value, $label) = @$case;
        like(dies {
            PAGI::Pages->not_found(headers => ['X-Test' => $value])
        }, qr/field-value scalar/, "$label header value is rejected");
    }

    for my $name ('Bad Name', 'Bad:Name', "Wide-\x{2603}", []) {
        like(dies {
            PAGI::Pages->not_found(headers => [$name => 'value'])
        }, qr/header name must be an HTTP token/,
            'invalid or reference-valued header name is rejected');
    }

    like(dies { PAGI::Pages->not_found(headers => {}) },
        qr/even-length arrayref/, 'non-array raw headers are rejected');
    like(dies { PAGI::Pages->not_found(headers => ['X-One']) },
        qr/even-length arrayref/, 'odd raw header lists are rejected');
};

subtest 'problem extensions cannot replace authoritative members' => sub {
    for my $member (qw(type title status detail instance)) {
        like(dies {
            PAGI::Pages->not_found(extensions => {$member => 'replacement'})
        }, qr/reserved problem member/,
            "$member cannot collide with a standard problem member");
    }
    like(dies {
        PAGI::Pages->network_authentication_required(
            extensions => {login => '/other'},
        )
    }, qr/login.*reserved|reserved.*login/i,
        '511 reserves the login problem member');
    is(dies {
        PAGI::Pages->not_found(extensions => {login => '/advisory'})
    }, undef, 'login remains an ordinary extension for non-511 problems');
};

subtest '511 login_url is consistent across HTML, text, and problem JSON' => sub {
    my $login = '/login?next=%2F&lang=en';
    my $html = decode('UTF-8', response_body(
        PAGI::Pages->network_authentication_required(
            http_scope(), as => 'html', login_url => $login,
        ),
    ), FB_CROAK);
    like($html, qr{href="/login\?next=%2F&amp;lang=en"},
        'HTML includes an escaped login link');

    my $text = decode('UTF-8', response_body(
        PAGI::Pages->network_authentication_required(
            http_scope(), as => 'text', login_url => $login,
        ),
    ), FB_CROAK);
    like($text, qr/Network login:\n\Q$login\E\n/,
        'text includes a labeled login URI');

    my $problem = decode_json(response_body(
        PAGI::Pages->network_authentication_required(
            http_scope(), as => 'json', login_url => $login,
        ),
    ));
    is($problem->{login}, $login,
        'problem JSON includes the authoritative login extension');
};

subtest 'error and welcome cache policies are exact' => sub {
    my %required_options = (
        unauthorized                  => [challenge => 'Basic realm="test"'],
        method_not_allowed            => [allow => []],
        proxy_authentication_required => [challenge => 'Basic realm="proxy"'],
        upgrade_required              => [upgrade => 'websocket'],
    );
    for my $method (@NAMED_ERRORS) {
        my $response = PAGI::Pages->$method(
            http_scope(), as => 'text', @{$required_options{$method} || []},
        );
        is($response->header('Cache-Control'), 'no-store',
            "$method defaults to no-store");
    }

    my $ordinary = PAGI::Pages->gone(
        http_scope(), as => 'text',
        cache_control => 'public, max-age=86400',
    );
    is($ordinary->header('Cache-Control'), 'public, max-age=86400',
        'ordinary errors accept an explicit cache override');

    for my $method (
        qw(precondition_required too_many_requests
           request_header_fields_too_large network_authentication_required)
    ) {
        like(dies {
            PAGI::Pages->$method(cache_control => 'public, max-age=60')
        }, qr/no-store|cache_control|cache/i,
            "$method rejects a cache value that weakens no-store");
        my $response = PAGI::Pages->$method(
            http_scope(), as => 'text', cache_control => 'No-Store',
        );
        is($response->header('Cache-Control'), 'no-store',
            "$method canonicalizes an equivalent no-store override");
    }

    my $welcome = PAGI::Pages->welcome(http_scope(), as => 'text');
    is($welcome->header('Cache-Control'), undef,
        'Welcome has no default Cache-Control');
    my $cached = PAGI::Pages->welcome(
        http_scope(), as => 'text', cache_control => 'public, max-age=300',
    );
    is($cached->header('Cache-Control'), 'public, max-age=300',
        'Welcome accepts an explicit Cache-Control value');
};

subtest 'automatic Vary merging preserves caller tokens and adds Accept once' => sub {
    my $response = PAGI::Pages->not_found(
        http_scope(),
        headers => [Vary => 'Origin, Accept-Encoding', vary => 'origin'],
    );
    is([$response->header_all('Vary')], ['Origin, Accept-Encoding, Accept'],
        'Vary is merged case-insensitively without losing caller tokens');
};

done_testing;
