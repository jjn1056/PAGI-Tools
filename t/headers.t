use strict;
use warnings;
use Test2::V0;
use PAGI::Headers;

subtest 'empty + construction from pairs' => sub {
    my $h = PAGI::Headers->new;
    is $h->is_empty, 1, 'new is empty';
    is $h->count, 0, 'count 0';
    is $h->to_pairs, [], 'no pairs';

    my $h2 = PAGI::Headers->new([['Content-Type','text/plain'],['X-Foo','a'],['X-Foo','b']]);
    is $h2->is_empty, 0, 'not empty';
    is $h2->count, 3, 'three header lines';
};

subtest 'case-insensitive reads, original casing preserved' => sub {
    my $h = PAGI::Headers->new([['Content-Type','text/plain'],['X-Foo','a'],['X-Foo','b']]);
    is $h->get('content-type'), 'text/plain', 'get is case-insensitive';
    is $h->get('X-FOO'), 'b', 'get returns the LAST value';
    is [$h->get_all('x-foo')], ['a','b'], 'get_all returns all values in order';
    is $h->has('CONTENT-TYPE'), 1, 'has is case-insensitive';
    is $h->has('x-bar'), 0, 'has false for absent';
    is [$h->names], ['Content-Type','X-Foo'], 'names: distinct, insertion order, ORIGINAL casing';
    is [@{$h}], [['Content-Type','text/plain'],['X-Foo','a'],['X-Foo','b']], '@{} overload yields the pairs';
};

subtest '@{} overload is a copy (read-only): pushing onto it does not mutate' => sub {
    my $h = PAGI::Headers->new([['X-A','1']]);
    push @{$h}, ['X-B','2'];          # pushes onto the COPY
    is $h->count, 1, 'container unchanged by pushing onto the deref';
    is $h->has('x-b'), 0, 'no X-B leaked in';
};

subtest 'set replaces, add appends, set_default is set-if-absent' => sub {
    my $h = PAGI::Headers->new([['X-Foo','a'],['X-Foo','b']]);
    $h->set('X-Foo','only');
    is [$h->get_all('x-foo')], ['only'], 'set replaces all values';
    $h->add('X-Foo','more');
    is [$h->get_all('x-foo')], ['only','more'], 'add appends';
    $h->set_default('X-Foo','ignored');
    is [$h->get_all('x-foo')], ['only','more'], 'set_default no-op when present';
    $h->set_default('X-New','fresh');
    is $h->get('x-new'), 'fresh', 'set_default sets when absent';
    is $h->set('X-Foo','z'), $h, 'writers return self for chaining';
};

subtest 'remove returns values; clear empties' => sub {
    my $h = PAGI::Headers->new([['Set-Cookie','a=1'],['X-Keep','k'],['Set-Cookie','b=2']]);
    is [$h->remove('set-cookie')], ['a=1','b=2'], 'remove returns the removed values';
    is $h->has('set-cookie'), 0, 'header gone after remove';
    is [$h->names], ['X-Keep'], 'others preserved';
    $h->clear;
    is $h->is_empty, 1, 'clear empties';
};

subtest 'remove_content_headers' => sub {
    my $h = PAGI::Headers->new([
        ['Content-Type','text/html'], ['Content-Length','5'], ['X-Keep','k'],
    ]);
    my $removed = $h->remove_content_headers;
    isa_ok $removed, ['PAGI::Headers'], 'returns a PAGI::Headers of the removed set';
    is [$removed->names], ['Content-Type','Content-Length'], 'removed content-* headers';
    is $h->has('content-type'), 0, 'content headers gone from original';
    is $h->has('x-keep'), 1, 'non-content preserved';
};

subtest 'dehop strips the fixed set AND Connection-named headers' => sub {
    my $h = PAGI::Headers->new([
        ['Connection','keep-alive, X-Secret'], ['Transfer-Encoding','chunked'],
        ['X-Secret','sensitive'], ['X-Keep','k'],
    ]);
    $h->dehop;
    is $h->has('connection'), 0, 'Connection stripped';
    is $h->has('transfer-encoding'), 0, 'fixed hop-by-hop stripped';
    is $h->has('x-secret'), 0, 'header NAMED by Connection is also stripped';
    is $h->has('x-keep'), 1, 'end-to-end header kept';
};

subtest 'output forms + clone independence' => sub {
    my $h = PAGI::Headers->new([['X-A','1'],['X-B','2']]);
    is $h->to_pairs, [['X-A','1'],['X-B','2']], 'to_pairs';
    is [$h->flatten], ['X-A','1','X-B','2'], 'flatten is a flat list';
    is $h->to_string, "X-A: 1\r\nX-B: 2\r\n", 'to_string wire form, insertion order';
    my $c = $h->clone;
    $c->set('X-A','changed');
    is $h->get('x-a'), '1', 'clone is independent of the original';
};

subtest 'undef header value is rejected (fail loud, never stored)' => sub {
    my $h = PAGI::Headers->new([['X-A','1']]);
    like dies { $h->add('X-B', undef) }, qr/value must be defined/, 'add rejects undef value';
    like dies { $h->set('X-C', undef) }, qr/value must be defined/, 'set rejects undef value';
    like dies { $h->set_default('X-D', undef) }, qr/value must be defined/, 'set_default rejects undef value';
    is $h->to_pairs, [['X-A','1']], 'nothing was stored by the rejected calls';
    like dies { $h->get(undef) }, qr/header name required/, 'the undef-NAME guard still holds';
};

done_testing;
