use strict;
use warnings;
use Test2::V0;
use PAGI::Auth qw(bearer);

is bearer(realm => 'api')->header_value, 'Bearer realm="api"';

my $value = bearer(
    realm             => 'api',
    scope             => ['apples:read', 'apples:write'],
    error             => 'invalid_token',
    error_description => 'The token is no longer valid',
    error_uri         => 'https://example.test/auth/invalid-token',
    params            => { zeta => 'last', acr_values => 'urn:example:strong' },
);
is $value->header_value,
    'Bearer realm="api", scope="apples:read apples:write", error="invalid_token", '
    . 'error_description="The token is no longer valid", '
    . 'error_uri="https://example.test/auth/invalid-token", '
    . 'acr_values="urn:example:strong", zeta="last"';
is $value->_kind, 'bearer', 'Bearer retains private kind metadata';
is $value->_error, 'invalid_token', 'Bearer retains normalized error metadata';

for my $error (qw(
    invalid_request invalid_token insufficient_scope
    insufficient_user_authentication extension_error
)) {
    is bearer(error => $error)->header_value, qq(Bearer error="$error"),
        "Bearer accepts $error";
}

is bearer(
    params => {
        max_age           => 300,
        acr_values        => 'urn:example:loa:2',
        resource_metadata => 'https://resource.example.test/.well-known/oauth-protected-resource',
    },
)->header_value,
    'Bearer acr_values="urn:example:loa:2", max_age="300", '
    . 'resource_metadata="https://resource.example.test/.well-known/oauth-protected-resource"',
    'Bearer preserves caller-owned extension semantics with safe serialization';

subtest 'Bearer rejects malformed options and field values' => sub {
    my @cases = (
        [ 'odd options', sub { bearer(realm => 'api', 'scope') } ],
        [ 'unknown option', sub { bearer(realm => 'api', mode => 'strict') } ],
        [ 'reference option name', sub { bearer([] => 'api') } ],
        [ 'duplicate option', sub { bearer(realm => 'api', realm => 'other') } ],
        [ 'reference realm', sub { bearer(realm => []) } ],
        [ 'undefined realm', sub { bearer(realm => undef) } ],
        [ 'scope must be an arrayref', sub { bearer(scope => 'read') } ],
        [ 'scope must be unblessed', sub { bearer(scope => bless([], 'T::Scope')) } ],
        [ 'scope must not be empty', sub { bearer(scope => []) } ],
        [ 'scope item must be a scalar', sub { bearer(scope => [[]]) } ],
        [ 'scope item must be defined', sub { bearer(scope => [undef]) } ],
        [ 'scope item must be a token', sub { bearer(scope => ['read write']) } ],
        [ 'scope token rejects a quote', sub { bearer(scope => ['read"write']) } ],
        [ 'scope token rejects a backslash', sub { bearer(scope => ['read\\write']) } ],
        [ 'scope rejects duplicate declarations', sub { bearer(scope => ['read', 'read']) } ],
        [ 'error must be a token', sub { bearer(error => 'bad error') } ],
        [ 'error description requires an error', sub { bearer(error_description => 'explain') } ],
        [ 'error uri requires an error', sub { bearer(error_uri => 'https://example.test/error') } ],
        [ 'error description must not be empty', sub { bearer(error => 'invalid_token', error_description => '') } ],
        [ 'error description rejects a quote', sub { bearer(error => 'invalid_token', error_description => 'bad"description') } ],
        [ 'error description rejects a backslash', sub { bearer(error => 'invalid_token', error_description => 'bad\\description') } ],
        [ 'relative error uri', sub { bearer(error => 'invalid_token', error_uri => '/error') } ],
        [ 'malformed error uri', sub { bearer(error => 'invalid_token', error_uri => 'https://example.test/bad value') } ],
        [ 'error uri rejects a quote', sub { bearer(error => 'invalid_token', error_uri => 'https://example.test/bad"uri') } ],
        [ 'error uri rejects a backslash', sub { bearer(error => 'invalid_token', error_uri => 'https://example.test/bad\\uri') } ],
        [ 'params must be a hashref', sub { bearer(params => []) } ],
        [ 'params must be unblessed', sub { bearer(params => bless({}, 'T::Params')) } ],
        [ 'params must not be empty', sub { bearer(params => {}) } ],
        [ 'params cannot shadow realm', sub { bearer(params => { Realm => 'other' }) } ],
        [ 'params cannot shadow scope', sub { bearer(params => { SCOPE => 'other' }) } ],
        [ 'params cannot shadow error', sub { bearer(params => { Error => 'other' }) } ],
        [ 'params cannot shadow error description', sub { bearer(params => { ERROR_DESCRIPTION => 'other' }) } ],
        [ 'params cannot shadow error uri', sub { bearer(params => { Error_Uri => 'other' }) } ],
        [ 'params rejects case-insensitive duplicate keys', sub { bearer(params => { max_age => '1', MAX_AGE => '2' }) } ],
        [ 'params rejects invalid key', sub { bearer(params => { 'bad name' => 'value' }) } ],
        [ 'params rejects undefined value', sub { bearer(params => { max_age => undef }) } ],
        [ 'params rejects reference value', sub { bearer(params => { max_age => [] }) } ],
    );

    for my $value (
        "bad\rvalue", "bad\nvalue", "bad\0value", "bad\x1Fvalue",
        "bad\x7Fvalue", "bad\x{80}value",
    ) {
        push @cases,
            [ 'invalid realm byte', sub { bearer(realm => $value) } ],
            [ 'invalid error description byte', sub {
                bearer(error => 'invalid_token', error_description => $value);
            } ],
            [ 'invalid error uri byte', sub {
                bearer(error => 'invalid_token', error_uri => "https://example.test/$value");
            } ],
            [ 'invalid extension value byte', sub { bearer(params => { max_age => $value }) } ];
    }

    for my $case (@cases) {
        like dies { $case->[1]->() },
            qr/(?:realm|scope|error|description|uri|params|option|scalar|token|ASCII|printable|pairs|duplicate|absolute)/i,
            $case->[0];
    }
};

done_testing;
