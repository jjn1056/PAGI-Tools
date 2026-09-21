#!/usr/bin/env perl
use strict;
use warnings;

use Test2::V0;

use lib 'lib';
use PAGI::Headers;
use PAGI::Utils::Headers qw(
    parse_authorization_bearer
    parse_authorization_basic
    www_authenticate
);

# These cases fail if recognition accepts a partial credential, treats HTAB as
# the required scheme separator, or changes the RFC 6750 token alphabet.
subtest 'Bearer parsing recognizes only complete Bearer credentials' => sub {
    my @cases = (
        ['missing value', undef, undef, 0],
        ['surrounding OWS', " \tBearer 0\t ", '0', 0],
        ['mixed-case scheme', 'bEaReR abc.DEF_~+/==', 'abc.DEF_~+/==', 0],
        ['another scheme', 'Basic Og==', undef, 0],
        ['no partial credential', 'Bearer one two', undef, 1],
        ['tab is not the credential separator', "Bearer\ttoken", undef, 1],
        ['supported scheme without credentials', 'Bearer', undef, 1],
        ['empty value', '', undef, 1],
        ['invalid scheme syntax', '@Bearer token', undef, 1],
        ['equals alone is not a token', 'Bearer =', undef, 1],
    );

    for my $case (@cases) {
        is parse_authorization_bearer($case->[1]), $case->[2], $case->[0];
        if ($case->[3]) {
            like dies { parse_authorization_bearer($case->[1], raise_on_error => 1) },
                qr/Bearer|bearer|authorization/i, "$case->[0] raises in reporting mode";
        }
        else {
            is parse_authorization_bearer($case->[1], raise_on_error => 1), $case->[2],
                "$case->[0] has the same recognition in reporting mode";
        }
    }

    my $error = dies { parse_authorization_bearer('Bearer secret extra', raise_on_error => 1) };
    unlike $error, qr/secret/, 'credential is not included in the error';
};

# These cases fail if decoding accepts invalid Base64, splits every colon, or
# turns valid empty/raw byte components into absence.
subtest 'Basic parsing validates Base64 and decoded credential bytes' => sub {
    my @cases = (
        ['missing value', undef, [undef, undef], 0],
        ['surrounding OWS', " \tBasic Og==\t ", ['', ''], 0],
        ['mixed-case scheme', 'bAsIc dTpwOnE=', ['u', 'p:q'], 0],
        ['another scheme', 'Bearer token', [undef, undef], 0],
        ['empty components are values', 'Basic Og==', ['', ''], 0],
        ['raw bytes are retained', 'Basic /zpw', ["\xFF", 'p'], 0],
        ['invalid Base64 alphabet', 'Basic !!!!', [undef, undef], 1],
        ['invalid Base64 padding', 'Basic Zg=', [undef, undef], 1],
        ['trailing Base64 garbage', 'Basic dTpw!!!!', [undef, undef], 1],
        ['decoded credential needs colon', 'Basic dXNlcg==', [undef, undef], 1],
        ['decoded controls rejected', 'Basic dQA6cA==', [undef, undef], 1],
        ['supported scheme without credentials', 'Basic', [undef, undef], 1],
        ['tab is not the credential separator', "Basic\tdTpw", [undef, undef], 1],
    );

    for my $case (@cases) {
        is [parse_authorization_basic($case->[1])], $case->[2], $case->[0];
        if ($case->[3]) {
            like dies { parse_authorization_basic($case->[1], raise_on_error => 1) },
                qr/Basic|basic|authorization/i, "$case->[0] raises in reporting mode";
        }
        else {
            is [parse_authorization_basic($case->[1], raise_on_error => 1)], $case->[2],
                "$case->[0] has the same recognition in reporting mode";
        }
    }

    my $error = dies { parse_authorization_basic('Basic c2VjcmV0', raise_on_error => 1) };
    unlike $error, qr/secret/, 'decoded credential is not included in the error';
};

subtest 'parser arguments reject programming errors in both absence and value cases' => sub {
    like dies { parse_authorization_bearer(undef, unexpected => 1) },
        qr/unknown option/i, 'Bearer validates options before treating input as absent';
    like dies { parse_authorization_basic(undef, unexpected => 1) },
        qr/unknown option/i, 'Basic validates options before treating input as absent';
    like dies { parse_authorization_bearer([], raise_on_error => 1) },
        qr/scalar|value/i, 'Bearer rejects a reference value';
    like dies { parse_authorization_basic([], raise_on_error => 1) },
        qr/scalar|value/i, 'Basic rejects a reference value';
    like dies { parse_authorization_bearer('Bearer token', raise_on_error => 1, raise_on_error => 0) },
        qr/duplicate/i, 'duplicate options are rejected';
};

subtest 'singleton Authorization helpers do not select duplicate credentials' => sub {
    my $headers = PAGI::Headers->new([
        ['Authorization', 'Bearer first'], ['authorization', 'Bearer second'],
    ]);

    is $headers->get('Authorization'), 'Bearer second', 'raw get still returns last';
    is $headers->get_single('Missing'), undef, 'missing singleton returns undef';
    is $headers->get_single('Authorization'), undef, 'duplicate singleton is unusable';
    is $headers->authorization_bearer, undef, 'duplicate credentials not selected';
    is [ $headers->authorization_basic ], [undef, undef],
        'duplicate Basic credentials are not selected';
    like dies { $headers->get_single('Authorization', raise_on_error => 1) },
        qr/single|duplicate|multiple/i, 'singleton duplicate throws when requested';
    like dies { $headers->authorization_bearer(unknown => 1) }, qr/unknown option/i,
        'Headers helpers retain parser argument validation';
};

subtest 'WWW-Authenticate formatting delegates to the shared formatter' => sub {
    is www_authenticate('Bearer', realm => 'api'), 'Bearer realm="api"', 'plain value';
    is www_authenticate('Demo', Label => '', realm => 'a"b'),
        'Demo Label="", realm="a\\"b"', 'quotes values and preserves pair order';
    like dies { www_authenticate('Bearer', realm => 'a', Realm => 'b') }, qr/duplicate/i,
        'duplicate parameter names are rejected case-insensitively';
};

done_testing;
