use strict;
use warnings;

use Test2::V0;
use Encode qw(decode FB_CROAK);
use Future;
use JSON::MaybeXS qw(decode_json);

use PAGI::Pages;
use PAGI::Utils qw(invoke_app);

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
    my ($application, $scope) = @_;
    $scope ||= http_scope();
    my @events;
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    Future->wrap(invoke_app(
        $application, $scope, sub { Future->done }, $send,
    ))->get;
    return \@events;
}

sub response_body {
    my ($application, $scope) = @_;
    my $events = send_response($application, $scope);
    return $events->[1]{body};
}

sub event_header_all {
    my ($events, $name) = @_;
    my $wanted = lc $name;
    return map { $_->[1] }
        grep { lc($_->[0]) eq $wanted }
        @{$events->[0]{headers} || []};
}

sub application_header_all {
    my ($application, $name, $scope) = @_;
    return [event_header_all(send_response($application, $scope), $name)];
}

sub application_header {
    my ($application, $name, $scope) = @_;
    my $values = application_header_all($application, $name, $scope);
    return @$values ? $values->[-1] : undef;
}

{
    package Local::Hostile511Pages;
    our @ISA = ('PAGI::Pages');
    sub render_problem {
        return {
            login  => '/renderer-invented',
            status => 599,
        };
    }
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
        my $application;
        is(dies {
            $application = PAGI::Pages->$method(
                as => 'text', %$options,
            );
        }, undef, "$method accepts its semantic option");
        next unless $application;
        if (defined $name) {
            is(application_header($application, $name), $want,
                "$method emits its normalized semantic field");
        }
    }

    my $empty = PAGI::Pages->method_not_allowed(
        as => 'text', allow => [],
    );
    is(application_header_all($empty, 'Allow'), [''],
        '405 emits one legal empty Allow field');

    my $multiple = PAGI::Pages->unauthorized(
        as => 'text',
        challenge => ['Basic realm="one"', 'Bearer realm="two"'],
    );
    is(application_header_all($multiple, 'WWW-Authenticate'), [
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
        my $application = PAGI::Pages->$method(
            as => 'text', headers => $headers,
        );
        is(application_header_all($application, $name), $want,
            "$method accepts and preserves its raw mandatory field");
    }

    my $mixed = PAGI::Pages->unauthorized(
        as => 'text',
        challenge => 'Basic realm="semantic"',
        headers => ['WWW-Authenticate' => 'Bearer realm="raw"'],
    );
    is(application_header_all($mixed, 'WWW-Authenticate'), [
        'Bearer realm="raw"', 'Basic realm="semantic"',
    ], 'raw and semantic challenges coexist as separate field lines');
};

subtest 'mandatory and cache fields survive response event emission' => sub {
    my @cases = (
        [unauthorized => [challenge => ['Basic realm="one"', 'Bearer realm="two"']],
            'WWW-Authenticate', ['Basic realm="one"', 'Bearer realm="two"']],
        [method_not_allowed => [allow => []], 'Allow', ['']],
        [proxy_authentication_required => [challenge => 'Basic realm="proxy"'],
            'Proxy-Authenticate', ['Basic realm="proxy"']],
        [upgrade_required => [upgrade => 'websocket'],
            'Upgrade', ['websocket']],
    );

    for my $case (@cases) {
        my ($method, $options, $name, $want) = @$case;
        my $events = send_response(PAGI::Pages->$method(
            as => 'text', @$options,
        ));
        is([event_header_all($events, $name)], $want,
            "$method emits its mandatory field on http.response.start");
        is([event_header_all($events, 'Cache-Control')], ['no-store'],
            "$method emits its default cache policy on http.response.start");
    }

    my $upgrade = send_response(PAGI::Pages->upgrade_required(
        as => 'text', upgrade => 'websocket',
    ));
    is([event_header_all($upgrade, 'Connection')], [],
        '426 emits no Connection header (a PAGI server supplies the RFC 9110 companion itself)');
    is([event_header_all($upgrade, 'Upgrade')], ['websocket'],
        '426 still emits its mandatory Upgrade header');

    my $override = send_response(PAGI::Pages->gone(
        as => 'text', cache_control => 'public, max-age=60',
    ));
    is([event_header_all($override, 'Cache-Control')], ['public, max-age=60'],
        'an explicit ordinary-error cache policy survives event emission');
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
        like(dies { PAGI::Pages->$method(@$args) },
            qr/nonempty|challenge/i,
            "$label rejects an OWS-only authentication challenge");
    }

    my $default_version = {
        type => 'http', method => 'GET', path => '/', headers => [],
        query_string => '',
    };
    my $default = PAGI::Pages->upgrade_required(
        as => 'text', upgrade => 'websocket',
    );
    is(application_header($default, 'Upgrade', $default_version), 'websocket',
        'an absent HTTP version uses the request default of HTTP/1.1');

    for my $version ('1.0', '2', '3') {
        my $application = PAGI::Pages->upgrade_required(
            as => 'text', upgrade => 'websocket',
        );
        like(dies {
            send_response($application, http_scope(version => $version));
        }, qr/HTTP\/1\.1|version|Upgrade/i,
            "426 rejects explicit HTTP/$version");
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
        like(dies { PAGI::Pages->$method(@$args) },
            qr/conflict|both|raw/i,
            "$method rejects semantic/raw field conflict");
    }
};

subtest 'Retry-After accepts delay seconds and canonical IMF-fixdate only' => sub {
    my $delay = PAGI::Pages->too_many_requests(
        as => 'text', retry_after => 17,
    );
    is(application_header($delay, 'Retry-After'), '17',
        'non-negative delay seconds are emitted');

    my $date = 'Sun, 06 Nov 1994 08:49:37 GMT';
    my $dated = PAGI::Pages->service_unavailable(
        as => 'text', retry_after => $date,
    );
    is(application_header($dated, 'Retry-After'), $date,
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
        as => 'text', length => $large,
    );
    is(application_header($range, 'Content-Range'), 'bytes */' . $large,
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
        like(dies { PAGI::Pages->bad_request(@$args) },
            qr/not valid|unrelated|option/i,
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
            PAGI::Pages->not_found(
                extensions => {$member => 'replacement'})
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
        PAGI::Pages->not_found(
            extensions => {login => '/advisory'})
    }, undef, 'login remains an ordinary extension for non-511 problems');
};

subtest '511 login_url is consistent across HTML, text, and problem JSON' => sub {
    my $login = '/login?next=%2F&lang=en';
    my $html = decode('UTF-8', response_body(
        PAGI::Pages->network_authentication_required(
            as => 'html', login_url => $login,
        ),
    ), FB_CROAK);
    like($html, qr{href="/login\?next=%2F&amp;lang=en"},
        'HTML includes an escaped login link');

    my $text = decode('UTF-8', response_body(
        PAGI::Pages->network_authentication_required(
            as => 'text', login_url => $login,
        ),
    ), FB_CROAK);
    like($text, qr/Network login:\n\Q$login\E\n/,
        'text includes a labeled login URI');

    my $problem = decode_json(response_body(
        PAGI::Pages->network_authentication_required(
            as => 'json', login_url => $login,
        ),
    ));
    is($problem->{login}, $login,
        'problem JSON includes the authoritative login extension');

    my $invented = decode_json(response_body(
        Local::Hostile511Pages->network_authentication_required(
            as => 'json',
        ),
    ));
    ok(!exists($invented->{login}),
        'a hostile renderer cannot invent the reserved 511 login member');
    is($invented->{status}, 511,
        'a hostile renderer cannot replace the 511 problem status');

    my $reasserted = decode_json(response_body(
        Local::Hostile511Pages->network_authentication_required(
            as => 'json', login_url => $login,
        ),
    ));
    is($reasserted->{login}, $login,
        'validated login_url replaces a hostile renderer login member');
};

subtest 'error and welcome cache policies are exact' => sub {
    my %required_options = (
        unauthorized                  => [challenge => 'Basic realm="test"'],
        method_not_allowed            => [allow => []],
        proxy_authentication_required => [challenge => 'Basic realm="proxy"'],
        upgrade_required              => [upgrade => 'websocket'],
    );
    for my $method (@NAMED_ERRORS) {
        my $application = PAGI::Pages->$method(
            as => 'text', @{$required_options{$method} || []},
        );
        is(application_header($application, 'Cache-Control'), 'no-store',
            "$method defaults to no-store");
    }

    my $ordinary = PAGI::Pages->gone(
        as => 'text',
        cache_control => 'public, max-age=86400',
    );
    is(application_header($ordinary, 'Cache-Control'), 'public, max-age=86400',
        'ordinary errors accept an explicit cache override');

    for my $method (
        qw(precondition_required too_many_requests
           request_header_fields_too_large network_authentication_required)
    ) {
        like(dies {
            PAGI::Pages->$method(
                cache_control => 'public, max-age=60')
        }, qr/no-store|cache_control|cache/i,
            "$method rejects a cache value that weakens no-store");
        my $application = PAGI::Pages->$method(
            as => 'text', cache_control => 'No-Store',
        );
        is(application_header($application, 'Cache-Control'), 'no-store',
            "$method canonicalizes an equivalent no-store override");
    }

    my $welcome = PAGI::Pages->welcome(as => 'text');
    is(application_header($welcome, 'Cache-Control'), undef,
        'Welcome has no default Cache-Control');
    my $cached = PAGI::Pages->welcome(
        as => 'text', cache_control => 'public, max-age=300',
    );
    is(application_header($cached, 'Cache-Control'), 'public, max-age=300',
        'Welcome accepts an explicit Cache-Control value');
};

subtest 'automatic Vary merging preserves caller tokens and adds Accept once' => sub {
    my $application = PAGI::Pages->not_found(
        headers => [Vary => 'Origin, Accept-Encoding', vary => 'origin'],
    );
    is(application_header_all($application, 'Vary'),
        ['Origin, Accept-Encoding, Accept'],
        'Vary is merged case-insensitively without losing caller tokens');
};

done_testing;
