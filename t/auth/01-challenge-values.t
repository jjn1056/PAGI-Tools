use strict;
use warnings;
use Test2::V0;
use overload ();
use PAGI::Auth qw(basic custom_challenge);

my $basic = basic(realm => 'Staff "and" Support', charset => 'utf-8');
isa_ok $basic, 'PAGI::Auth::Challenge';
is $basic->scheme, 'Basic';
is $basic->header_value,
    'Basic realm="Staff \\"and\\" Support", charset="UTF-8"';
is basic(realm => '')->header_value, 'Basic realm=""',
    'Basic accepts an empty realm';
is $basic->_kind, 'basic', 'Basic retains private kind metadata';
is $basic->_error, undef, 'Basic has no private error metadata';
ok !$basic->can('new'), 'no public constructor is inherited by the value';
ok !overload::Method($basic, '""'), 'value has no string overload';
ok !overload::Method($basic, '%{}'), 'value has no hash overload';
ok !overload::Method($basic, '&{}'), 'value has no code overload';
like dies { $basic->{scheme} = 'Changed' }, qr/read.?only|restricted|disallowed/i,
    'locked value rejects changing a field';
like dies { $basic->{extra} = 'Changed' }, qr/read.?only|restricted|disallowed/i,
    'locked value rejects extending its representation';

my $generic = custom_challenge(
    scheme => 'DemoToken',
    params => { realm => 'demo', mode => 'interactive' },
);
is $generic->scheme, 'DemoToken';
is $generic->header_value,
    'DemoToken mode="interactive", realm="demo"';
is $generic->_kind, 'custom', 'generic values retain private kind metadata';
is $generic->_error, undef, 'generic values have no private error metadata';
is custom_challenge(scheme => 'Mutual')->header_value, 'Mutual';
is custom_challenge(scheme => 'Negotiate', token68 => 'abc+/==')->header_value,
    'Negotiate abc+/==';
is custom_challenge(
    scheme => 'DemoToken',
    params => { z => 'a\\b"c' },
)->header_value, 'DemoToken z="a\\\\b\\"c"',
    'custom parameters quote backslash and double quote';

is \@PAGI::Auth::EXPORT, [], 'Auth exports nothing by default';
is $PAGI::Auth::EXPORT_TAGS{outcomes}, [qw(challenge forbid)];
is $PAGI::Auth::EXPORT_TAGS{challenges}, [qw(basic bearer custom_challenge)];
is $PAGI::Auth::EXPORT_TAGS{all}, [qw(challenge forbid basic bearer custom_challenge)];

subtest 'Basic rejects malformed options and field values' => sub {
    my @cases = (
        [ 'missing realm', sub { basic() } ],
        [ 'odd options', sub { basic(realm => 'api', 'charset') } ],
        [ 'unknown option', sub { basic(realm => 'api', mode => 'strict') } ],
        [ 'reference option name', sub { basic([] => 'api') } ],
        [ 'reference realm', sub { basic(realm => []) } ],
        [ 'undefined realm', sub { basic(realm => undef) } ],
        [ 'non-UTF-8 charset', sub { basic(realm => 'api', charset => 'latin1') } ],
        [ 'reference charset', sub { basic(realm => 'api', charset => []) } ],
    );

    for my $value (
        "bad\rvalue", "bad\nvalue", "bad\0value", "bad\x1Fvalue",
        "bad\x7Fvalue", "bad\x{80}value",
    ) {
        push @cases, [ 'invalid realm byte', sub { basic(realm => $value) } ];
    }

    for my $case (@cases) {
        like dies { $case->[1]->() }, qr/(?:realm|charset|option|scalar|ASCII|printable|pairs)/i,
            $case->[0];
    }
};

subtest 'custom challenges reject every invalid shared and generic class' => sub {
    my @cases = (
        [ 'missing scheme', sub { custom_challenge() } ],
        [ 'odd options', sub { custom_challenge(scheme => 'Demo', 'params') } ],
        [ 'unknown option', sub { custom_challenge(scheme => 'Demo', realm => 'api') } ],
        [ 'reference option name', sub { custom_challenge([] => 'Demo') } ],
        [ 'undefined scheme', sub { custom_challenge(scheme => undef) } ],
        [ 'reference scheme', sub { custom_challenge(scheme => []) } ],
        [ 'empty scheme', sub { custom_challenge(scheme => '') } ],
        [ 'malformed scheme token', sub { custom_challenge(scheme => 'Demo Token') } ],
        [ 'Basic bypass is rejected', sub { custom_challenge(scheme => 'bAsIc') } ],
        [ 'Bearer bypass is rejected', sub { custom_challenge(scheme => 'BEARER') } ],
        [ 'params must be a hashref', sub { custom_challenge(scheme => 'Demo', params => []) } ],
        [ 'params must be unblessed', sub { custom_challenge(scheme => 'Demo', params => bless({}, 'T::Params')) } ],
        [ 'explicit empty params', sub { custom_challenge(scheme => 'Demo', params => {}) } ],
        [ 'params and token68 are exclusive', sub { custom_challenge(scheme => 'Demo', params => { realm => 'api' }, token68 => 'abc') } ],
        [ 'malformed parameter token', sub { custom_challenge(scheme => 'Demo', params => { 'bad name' => 'api' }) } ],
        [ 'case-insensitive duplicate parameters', sub { custom_challenge(scheme => 'Demo', params => { Realm => 'one', realm => 'two' }) } ],
        [ 'undefined parameter value', sub { custom_challenge(scheme => 'Demo', params => { realm => undef }) } ],
        [ 'reference parameter value', sub { custom_challenge(scheme => 'Demo', params => { realm => [] }) } ],
        [ 'empty token68', sub { custom_challenge(scheme => 'Demo', token68 => '') } ],
        [ 'reference token68', sub { custom_challenge(scheme => 'Demo', token68 => []) } ],
        [ 'malformed token68', sub { custom_challenge(scheme => 'Demo', token68 => 'abc=def') } ],
    );

    for my $value (
        "bad\rvalue", "bad\nvalue", "bad\0value", "bad\x1Fvalue",
        "bad\x7Fvalue", "bad\x{80}value",
    ) {
        push @cases, [ 'invalid parameter value', sub {
            custom_challenge(scheme => 'Demo', params => { realm => $value });
        } ];
    }

    for my $case (@cases) {
        like dies { $case->[1]->() }, qr/(?:scheme|option|params|parameter|token68|scalar|ASCII|printable|pairs|Basic|Bearer)/i,
            $case->[0];
    }
};

done_testing;
