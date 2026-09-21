#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use lib 'lib';
use PAGI::Utils::Headers qw(parse_header_parameters format_header_parameters quote_header_value);

subtest 'complete parameter grammar preserves bytes, order and duplicates' => sub {
    is parse_header_parameters('attachment; filename="quarterly; report.txt"'),
        { value => 'attachment', parameters => [filename => 'quarterly; report.txt'] },
        'semicolon inside quoted parameter is data';
    is parse_header_parameters('x; A=one; a=""'),
        { value => 'x', parameters => [a => 'one', a => ''] },
        'generic result retains duplicates and quoted empty values';
    is parse_header_parameters(" \tattachment \t;\tname = \"a\\\"b\\\\c\" \t;; X = y ; "),
        { value => 'attachment', parameters => [name => 'a"b\\c', x => 'y'] },
        'OWS, empty slots and quoted escapes are scanned completely';
    is parse_header_parameters('x; filename*=UTF-8\'\'caf%C3%A9.txt'),
        { value => 'x', parameters => ['filename*' => "UTF-8''caf%C3%A9.txt"] },
        'extended parameter remains raw';
    is parse_header_parameters('x'), { value => 'x', parameters => [] },
        'valid value without parameters has empty list';
    is parse_header_parameters(undef), undef, 'missing value is not an error';
};

subtest 'malformed input rejects the entire parse' => sub {
    for my $value ('', ' ; a=b', 'x; a', 'x; a=', 'x; =b', 'x; a="unfinished',
        'x; a="ok"junk', 'x; a="bad\\', "x; a=one two", "x; a=\x01",
        "x; a=\x{100}", "x; a=\"bad\x0a\"") {
        is parse_header_parameters($value), undef, "rejects malformed [$value]";
        like dies { parse_header_parameters($value, raise_on_error => 1) },
            qr/parse_header_parameters.*malformed/i, 'reporting mode identifies parser';
    }
    like dies { parse_header_parameters([], raise_on_error => 1) }, qr/scalar/i,
        'reference value is programming error';
    like dies { parse_header_parameters(undef, unexpected => 1) }, qr/unknown option/i,
        'options checked even for absence';
};

subtest 'formatter quotes only when needed and rejects injection' => sub {
    is format_header_parameters('attachment', filename => 'quarterly; report.txt'),
        'attachment; filename="quarterly; report.txt"', 'formatter quotes delimiters';
    is format_header_parameters('x', A => 'one', a => ''),
        'x; A=one; a=""', 'formatter preserves name case/order and duplicates';
    is format_header_parameters('x', name => 'a"b\\c'),
        'x; name="a\\"b\\\\c"', 'formatter escapes quote and backslash';
    is quote_header_value('a"b\\c'), '"a\\"b\\\\c"',
        'explicit quote helper always quotes';
    for my $leading ('', 'x;y', 'x,y', "x\x0a") {
        like dies { format_header_parameters($leading) }, qr/leading/i,
            'unsafe leading value rejected';
    }
    like dies { format_header_parameters('x', 'a') }, qr/pairs/i, 'odd pairs rejected';
    like dies { format_header_parameters('x', 'bad name' => 'v') }, qr/name/i, 'invalid name rejected';
    like dies { format_header_parameters('x', a => undef) }, qr/value/i, 'undef value rejected';
    like dies { quote_header_value("x\x0a") }, qr/quoted-string/i, 'control byte rejected';
    like dies { quote_header_value("\x{100}") }, qr/quoted-string/i, 'wide character rejected';
};

done_testing;
