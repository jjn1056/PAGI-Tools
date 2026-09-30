use strict;
use warnings;
use Test2::V0;
use PAGI::Utils::Headers qw(parse_etag format_etag parse_etag_list etag_matches);

is parse_etag('W/"a,b"'), { value => 'a,b', weak => 1 }, 'comma belongs to opaque tag';
is parse_etag('""'), { value => '', weak => 0 }, 'empty opaque tag is valid';
is parse_etag('"a\\b"'), { value => 'a\\b', weak => 0 }, 'backslash is retained, not unescaped';
is parse_etag("\t\"\x80\xff\" "), { value => "\x80\xff", weak => 0 },
    'only outer SP and HTAB are ignored; obs-text bytes are retained';
for my $bad ('w/"a"', '"a"tail', '"a""b"', '"a b"', "\"a\x00b\"", "\"a\x7fb\"", "\"a\nb\"") {
    is parse_etag($bad), undef, "invalid entity-tag is rejected: $bad";
}
is parse_etag(undef, raise_on_error => 1), undef, 'missing tag is not an error';
like dies { parse_etag('w/"a"', raise_on_error => 1) }, qr/parse_etag.*malformed/i,
    'malformed tag raises when requested';
like dies { parse_etag([]) }, qr/parse_etag.*scalar/i, 'reference tag is misuse';
like dies { parse_etag('"a"', unknown => 1) }, qr/unknown option/i,
    'unknown parser option is misuse';

is format_etag(''), '""', 'empty opaque value formats as strong tag';
is format_etag('a\\b', weak => 1), 'W/"a\\b"', 'formatter preserves backslash';
is format_etag("\x80\xff"), "\"\x80\xff\"", 'formatter preserves high bytes';
for my $bad ('a"b', 'a b', "a\x00b", "a\x7fb", "a\nb") {
    like dies { format_etag($bad) }, qr/format_etag.*opaque/i,
        'formatter rejects invalid opaque content';
}
like dies { format_etag(undef) }, qr/format_etag.*opaque/i, 'undefined opaque value is misuse';
like dies { format_etag([]) }, qr/format_etag.*opaque/i, 'reference opaque value is misuse';
like dies { format_etag('x', unknown => 1) }, qr/unknown option/i,
    'formatter rejects unknown option';

my $condition = parse_etag_list(['"old"', 'W/"a,b"', '"old"']);
is $condition, { any => 0, tags => [
    { value => 'old', weak => 0 }, { value => 'a,b', weak => 1 },
    { value => 'old', weak => 0 },
] }, 'all occurrences and repeated tags retain order';
is parse_etag_list([]), undef, 'no field occurrences means absence';
is parse_etag_list(['']), { any => 0, tags => [] }, 'present empty list is distinct';
is parse_etag_list([', ,']), { any => 0, tags => [] }, 'empty members are skipped';
is parse_etag_list([' , "a",, W/"b,c", ']), { any => 0, tags => [
    { value => 'a', weak => 0 }, { value => 'b,c', weak => 1 },
] }, 'cursor consumes complete tags before commas';
is parse_etag_list(['*']), { any => 1, tags => [] }, 'wildcard condition';
my $positioned_fields = ['"alpha", "beta"'];
$positioned_fields->[0] =~ /"alpha", /g;
my $original_position = pos($positioned_fields->[0]);
is parse_etag_list($positioned_fields), { any => 0, tags => [
    { value => 'alpha', weak => 0 }, { value => 'beta', weak => 0 },
] }, 'parser reads a field with an existing regex position';
is pos($positioned_fields->[0]), $original_position,
    'list parsing preserves the caller field regex position';
for my $bad (['*', '"a"'], ['"a", *'], ['*,'], [',*'], ['*', ''],
             ['"a"oops'], ['"a", W/"b'], ['w/"a"']) {
    is parse_etag_list($bad), undef, 'malformed complete condition is unusable';
}
like dies { parse_etag_list(['"a", nope'], raise_on_error => 1) },
    qr/parse_etag_list.*malformed/i, 'malformed list can raise';
like dies { parse_etag_list('"a"') }, qr/parse_etag_list.*arrayref/i,
    'list argument must be an arrayref';
like dies { parse_etag_list([undef]) }, qr/parse_etag_list.*scalar/i,
    'each occurrence must be a defined scalar';
like dies { parse_etag_list([[]]) }, qr/parse_etag_list.*scalar/i,
    'reference occurrence is misuse';
like dies { parse_etag_list(['bad', []]) }, qr/parse_etag_list.*scalar/i,
    'all occurrence shapes are checked before syntax';

ok !etag_matches($condition, '"a,b"'), 'strong comparison rejects weak candidate';
ok etag_matches($condition, '"a,b"', weak => 1), 'weak comparison compares opaque bytes';
ok etag_matches($condition, '"old"'), 'strong candidate matches strong current tag';
ok !etag_matches($condition, 'W/"old"'), 'strong comparison rejects weak current tag';
ok etag_matches($condition, 'W/"old"', weak => 1), 'weak comparison accepts weak current tag';
ok !etag_matches($condition, '"OLD"', weak => 1), 'opaque bytes compare case-sensitively';
ok etag_matches(parse_etag_list(['*']), 'W/"anything"'), 'wildcard matches valid current tag';
ok !etag_matches(undef, '"a"'), 'absent condition does not match';
ok !etag_matches(parse_etag_list(['']), '"a"'), 'present empty list does not match';
is $condition->{tags}[1], { value => 'a,b', weak => 1 }, 'matching does not mutate condition';
like dies { etag_matches(undef, undef) }, qr/etag_matches.*current/i,
    'missing current tag is misuse even with absent condition';
like dies { etag_matches(undef, 'w/"a"') }, qr/etag_matches.*current/i,
    'malformed current tag is misuse even with absent condition';
like dies { etag_matches(undef, []) }, qr/etag_matches.*current/i,
    'reference current tag is misuse even with absent condition';
like dies { etag_matches({}, '"a"') }, qr/etag_matches.*condition/i,
    'malformed parsed condition is misuse';
like dies { etag_matches({ any => 0, tags => [{ value => 'a"b', weak => 0 }] }, '"a"') },
    qr/etag_matches.*condition/i, 'malformed parsed tag content is misuse';
like dies { etag_matches($condition, '"a"', unknown => 1) }, qr/unknown option/i,
    'comparison rejects unknown option';

done_testing;
