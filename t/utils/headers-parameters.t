#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test2::V0;
use lib 'lib';
use PAGI::Utils::Headers qw(
    parse_header_parameters format_header_parameters quote_header_value
    content_disposition
);

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

subtest 'response disposition formats character filenames as wire bytes' => sub {
    is(content_disposition('attachment', filename => 'report.pdf'),
        'attachment; filename="report.pdf"', 'ASCII download filename');
    my $value = content_disposition('attachment', filename => 'résumé.pdf');
    is($value, "attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf",
        'UTF-8 extended filename');
    ok(!utf8::is_utf8($value), 'formatter produces a byte string');
    is(content_disposition('attachment', filename => 'resume.pdf',
        'filename*' => "UTF-8''r%C3%A9sum%C3%A9.pdf"),
        "attachment; filename=\"resume.pdf\"; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf",
        'explicit ASCII fallback and extended name');
    is(content_disposition('inline', filename => 'a"b\\c.txt', note => 'Q1; draft'),
        'inline; filename="a\\"b\\\\c.txt"; note="Q1; draft"',
        'filename and ordinary parameters share safe quoted-string escaping');
    is(content_disposition('attachment', note => 'first', other => 'second'),
        'attachment; note=first; other=second', 'ordinary pair order is preserved');
    is(content_disposition('attachment', filename => pack('C*', 0xC3, 0xA9)),
        "attachment; filename*=UTF-8''%C3%83%C2%A9",
        'encoded UTF-8 bytes must be decoded by the caller first');
    is(content_disposition('attachment', 'filename*' => "X{Y}''report.txt"),
        "attachment; filename*=X{Y}''report.txt",
        'extended filename accepts charset brace characters');

    for my $case (
        ['missing disposition', [], qr/disposition/i],
        ['invalid disposition', ['attach ment'], qr/disposition/i],
        ['odd pairs', ['attachment', 'filename'], qr/pairs/i],
        ['invalid name', ['attachment', 'bad name' => 'x'], qr/name/i],
        ['duplicate name', ['attachment', Name => 'a', name => 'b'], qr/duplicate/i],
        ['filename control', ['attachment', filename => "a\x0ab"], qr/filename/i],
        ['ordinary control', ['attachment', note => "a\x0ab"], qr/value/i],
        ['bad percent escape', ['attachment', 'filename*' => "UTF-8''bad%2"], qr/filename\*/i],
        ['dot in charset', ['attachment', 'filename*' => "UTF.8''report.txt"], qr/filename\*/i],
        ['pipe in charset', ['attachment', 'filename*' => "UTF|8''report.txt"], qr/filename\*/i],
        ['non-ASCII extended value', ['attachment', 'filename*' => 'résumé'], qr/filename\*/i],
        ['generated collision', ['attachment', filename => 'résumé',
            'filename*' => "UTF-8''resume"], qr/filename\*/i],
        ['surrogate filename', ['attachment', filename => "\x{D800}"], qr/filename/i],
    ) {
        my ($label, $args, $error) = @$case;
        like(dies { content_disposition(@$args) }, $error, "$label is rejected");
    }
};

done_testing;
