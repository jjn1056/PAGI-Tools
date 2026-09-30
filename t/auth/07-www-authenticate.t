#!/usr/bin/env perl
use strict;
use warnings;

use Test2::V0;

use lib 'lib';
use PAGI::Auth qw(www_authenticate);
use PAGI::Utils::Headers ();

is www_authenticate('Bearer'), 'Bearer';
is www_authenticate('Basic', realm => 'api', charset => 'UTF-8'),
    'Basic realm="api", charset="UTF-8"';
is www_authenticate('Bearer', resource_metadata => 'https://api.example/meta'),
    'Bearer resource_metadata="https://api.example/meta"';
is www_authenticate('Demo', Label => '', realm => 'a"b'),
    'Demo Label="", realm="a\\"b"';
is www_authenticate('Demo', path => 'a\\b'), 'Demo path="a\\\\b"';
is www_authenticate('Demo', first => '1', SECOND => '2'),
    'Demo first="1", SECOND="2"', 'pair order and casing are preserved';
is www_authenticate('Demo', tab => "a\tb", byte => "\xFF"),
    "Demo tab=\"a\tb\", byte=\"\xFF\"",
    'HTAB and byte obs-text are permitted';
is www_authenticate('Demo', x_extension => 'yes'),
    'Demo x_extension="yes"', 'unknown valid extension names are accepted';

for my $call (
    [utils => sub { PAGI::Utils::Headers::www_authenticate('Bearer', realm => 'api') }],
    [exported => sub { www_authenticate('Bearer', realm => 'api') }],
    [class => sub { PAGI::Auth->www_authenticate('Bearer', realm => 'api') }],
    [instance => sub { PAGI::Auth->new->www_authenticate('Bearer', realm => 'api') }],
    [subclass => sub { Local::Formatter->www_authenticate('Bearer', realm => 'api') }],
) {
    is $call->[1]->(), 'Bearer realm="api"', "$call->[0] invocation";
}

my @invalid = (
    ['absent scheme', sub { www_authenticate() }, qr/scheme.*required/i],
    ['undefined scheme', sub { www_authenticate(undef) }, qr/scheme/],
    ['reference scheme', sub { www_authenticate([]) }, qr/scheme/],
    ['empty scheme', sub { www_authenticate('') }, qr/scheme/],
    ['invalid scheme', sub { www_authenticate('Bad Scheme') }, qr/scheme.*token/i],
    ['odd pairs', sub { www_authenticate('Bearer', 'realm') }, qr/pairs/i],
    ['undefined name', sub { www_authenticate('Bearer', (undef, 'x')) }, qr/name/],
    ['reference name', sub { www_authenticate('Bearer', [] => 'x') }, qr/name/],
    ['invalid name', sub { www_authenticate('Bearer', 'bad name' => 'x') }, qr/name.*token/i],
    ['duplicate name', sub { www_authenticate('Bearer', realm => 'a', Realm => 'b') }, qr/duplicate/i],
    ['undefined value', sub { www_authenticate('Bearer', realm => undef) }, qr/value/],
    ['reference value', sub { www_authenticate('Bearer', realm => []) }, qr/value/],
    ['array scope value', sub { www_authenticate('Bearer', scope => ['read']) }, qr/value/],
    ['CRLF value', sub { www_authenticate('Bearer', realm => "bad\r\nheader") }, qr/value|quoted/i],
    ['NUL value', sub { www_authenticate('Bearer', realm => "bad\0header") }, qr/value|quoted/i],
    ['DEL value', sub { www_authenticate('Bearer', realm => "bad\x7fheader") }, qr/value|quoted/i],
    ['control value', sub { www_authenticate('Bearer', realm => "bad\x1fheader") }, qr/value|quoted/i],
    ['wide character', sub { www_authenticate('Bearer', realm => "\x{100}") }, qr/value|quoted|byte/i],
);
for my $case (@invalid) {
    like dies { $case->[1]->() }, $case->[2], $case->[0];
}

{
    package Local::Formatter;
    use parent 'PAGI::Auth';
}

done_testing;
