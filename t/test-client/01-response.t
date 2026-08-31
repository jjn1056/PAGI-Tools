#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use File::Temp qw(tempfile);

use lib 'lib';
use PAGI::Test::Response;

sub captured_response {
    my (%args) = @_;
    return PAGI::Test::Response->new(
        events => [
            {
                type    => 'http.response.start',
                status  => $args{status} // 200,
                headers => $args{headers} // [],
            },
            {
                type => 'http.response.body',
                body => $args{body} // '',
                more => 0,
            },
        ],
        exception => $args{exception},
    );
}

subtest 'decodes captured response start, headers, and body events' => sub {
    my $res = PAGI::Test::Response->new(events => [
        {
            type    => 'http.response.start',
            status  => 206,
            headers => [
                ['content-type', 'text/plain'],
                ['x-wire', 'first'],
                ['X-Wire', 'second'],
            ],
        },
        { type => 'http.response.body', body => 'Hello ', more => 1 },
        { type => 'http.response.body', body => 'World', more => 0 },
    ]);

    is $res->status, 206, 'status comes from response.start';
    is $res->header_all('x-wire'), ['first', 'second'],
        'repeated headers preserve captured order';
    is $res->content, 'Hello World', 'body chunks are joined in wire order';
};

subtest 'decodes captured file events with offset and length' => sub {
    my ($fh, $path) = tempfile();
    print {$fh} '0123456789';
    close $fh;

    my $res = PAGI::Test::Response->new(events => [
        { type => 'http.response.start', status => 200, headers => [] },
        {
            type   => 'http.response.body',
            file   => $path,
            offset => 2,
            length => 4,
            more   => 0,
        },
    ]);

    is $res->content, '2345', 'file window decoded by Test Response';
};

subtest 'decodes captured filehandle events with offset and length' => sub {
    my $content = 'abcdefghij';
    open my $fh, '<', \$content or die "Cannot open scalar handle: $!";

    my $res = PAGI::Test::Response->new(events => [
        { type => 'http.response.start', status => 200, headers => [] },
        {
            type   => 'http.response.body',
            fh     => $fh,
            offset => 3,
            length => 3,
            more   => 0,
        },
    ]);

    is $res->content, 'def', 'filehandle window decoded by Test Response';
    close $fh;
};

subtest 'filehandle events normalize omitted and explicit zero offsets' => sub {
    for my $case (
        ['omitted offset', {}],
        ['explicit zero offset', { offset => 0 }],
    ) {
        my ($label, $offset) = @$case;
        my $content = 'abcdefghij';
        open my $fh, '<', \$content or die "Cannot open scalar handle: $!";
        seek($fh, 5, 0) or die "Cannot pre-position scalar handle: $!";

        my $res = PAGI::Test::Response->new(events => [
            { type => 'http.response.start', status => 200, headers => [] },
            {
                type   => 'http.response.body',
                fh     => $fh,
                %$offset,
                length => 3,
                more   => 0,
            },
        ]);

        is($res->content, 'abc', "$label reads from PAGI's default byte offset zero");
        close $fh;
    }
};

subtest 'basic response accessors' => sub {
    my $res = captured_response(
        status  => 200,
        headers => [
            ['content-type', 'text/plain'],
            ['x-custom', 'value'],
        ],
        body => 'Hello World',
    );

    is $res->status, 200, 'status';
    is $res->content, 'Hello World', 'content';
    is $res->text, 'Hello World', 'text';
    is $res->header('content-type'), 'text/plain', 'header lookup';
    is $res->header('X-Custom'), 'value', 'header case-insensitive';
    ok $res->is_success, 'is_success for 2xx';
};

subtest 'status helpers' => sub {
    ok( captured_response(status => 200)->is_success, '200 is success' );
    ok( captured_response(status => 201)->is_success, '201 is success' );
    ok( captured_response(status => 301)->is_redirect, '301 is redirect' );
    ok( captured_response(status => 404)->is_error, '404 is error' );
    ok( captured_response(status => 500)->is_error, '500 is error' );
};

subtest 'json parsing' => sub {
    my $res = captured_response(
        status  => 200,
        headers => [['content-type', 'application/json']],
        body    => '{"name":"John","age":30}',
    );

    my $data = $res->json;
    is $data->{name}, 'John', 'json name';
    is $data->{age}, 30, 'json age';
};

subtest 'json error handling' => sub {
    my $res = captured_response(
        status => 200,
        body   => 'not json',
    );

    like dies { $res->json }, qr/malformed|error|invalid|expected/i, 'dies on invalid json';
};

subtest 'convenience methods' => sub {
    my $res = captured_response(
        status  => 302,
        headers => [
            ['content-type', 'text/html'],
            ['content-length', '42'],
            ['location', '/redirect-target'],
        ],
        body => 'x' x 42,
    );

    is $res->content_type, 'text/html', 'content_type';
    is $res->content_length, '42', 'content_length';
    is $res->location, '/redirect-target', 'location';
};

subtest 'text decoding with charset' => sub {
    use Encode;

    # UTF-8 with explicit charset
    my $utf8_body = Encode::encode('UTF-8', "Héllo Wörld");
    my $res1 = captured_response(
        status  => 200,
        headers => [['content-type', 'text/plain; charset=utf-8']],
        body    => $utf8_body,
    );
    is $res1->text, "Héllo Wörld", 'text decodes UTF-8 charset';
    is $res1->content, $utf8_body, 'content returns raw bytes';

    # ISO-8859-1 (Latin-1) charset
    my $latin1_body = Encode::encode('ISO-8859-1', "café");
    my $res2 = captured_response(
        status  => 200,
        headers => [['content-type', 'text/html; charset=ISO-8859-1']],
        body    => $latin1_body,
    );
    is $res2->text, "café", 'text decodes ISO-8859-1 charset';

    # Quoted charset value
    my $res3 = captured_response(
        status  => 200,
        headers => [['content-type', 'text/plain; charset="utf-8"']],
        body    => $utf8_body,
    );
    is $res3->text, "Héllo Wörld", 'text handles quoted charset';

    # No charset defaults to UTF-8
    my $res4 = captured_response(
        status  => 200,
        headers => [['content-type', 'text/plain']],
        body    => $utf8_body,
    );
    is $res4->text, "Héllo Wörld", 'text defaults to UTF-8 when no charset';

    # No Content-Type header defaults to UTF-8
    my $res5 = captured_response(
        status => 200,
        body   => $utf8_body,
    );
    is $res5->text, "Héllo Wörld", 'text defaults to UTF-8 when no Content-Type';

    # Empty body
    my $res6 = captured_response(
        status => 200,
        body   => '',
    );
    is $res6->text, '', 'empty body returns empty string';
};

done_testing;
