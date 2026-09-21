#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use lib 'lib';

use PAGI::Middleware::ConditionalGet;
use PAGI::Test::Client;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    return $loop->await($code->());
}

subtest 'no conditional headers: request passes through unchanged' => sub {
    my $mw = PAGI::Middleware::ConditionalGet->new;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['etag', '"abc"']],
        });
        await $send->({ type => 'http.response.body', body => 'hello', more => 0 });
    };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/', method => 'GET', headers => [] },
            async sub { { type => 'http.disconnect' } },
            async sub { my ($event) = @_; push @sent, $event },
        );
    });

    is scalar(@sent), 2, 'start and body both pass through';
    is $sent[1]{body}, 'hello', 'body is unchanged';
};

subtest 'matching If-None-Match: 304 sent, body dropped' => sub {
    my $mw = PAGI::Middleware::ConditionalGet->new;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['etag', '"abc"']],
        });
        await $send->({ type => 'http.response.body', body => 'hello', more => 0 });
    };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/', method => 'GET',
              headers => [['if-none-match', '"abc"']] },
            async sub { { type => 'http.disconnect' } },
            async sub { my ($event) = @_; push @sent, $event },
        );
    });

    is scalar(@sent), 2, 'a 304 start and empty body are sent';
    is $sent[0]{status}, 304, 'status is 304';
    is $sent[1]{body}, '', 'body is empty';
};

subtest 'conditional eligibility and complete If-None-Match parsing' => sub {
    my $mw = PAGI::Middleware::ConditionalGet->new;
    my $dispatch = sub {
        my (%case) = @_;
        my $app = async sub {
            my ($scope, $receive, $send) = @_;
            await $send->({ type => 'http.response.start',
                status => $case{status} // 200, headers => $case{response_headers} // [] });
            await $send->({ type => 'http.response.body', body => 'data', more => 0 });
        };
        my @sent;
        run_async(async sub {
            await $mw->wrap($app)->({
                type => $case{type} // 'http', method => $case{method} // 'GET',
                path => '/', headers => $case{request_headers} // [],
            }, async sub { { type => 'http.disconnect' } },
            async sub { push @sent, $_[0] });
        });
        return \@sent;
    };
    my $date = 'Sun, 06 Nov 1994 08:49:37 GMT';
    my $etag = [['ETag', '"a,b"'], ['Last-Modified', $date],
        ['Cache-Control', 'private']];
    my $matching = [ ['If-None-Match', '"old"'],
        ['If-None-Match', 'W/"a,b"'] ];
    my $matched = $dispatch->(response_headers => $etag,
        request_headers => $matching);
    is($matched->[0]{status}, 304, 'weak tag in repeated field matches comma-bearing tag');
    is($matched->[1]{body}, '', '304 sends empty body');
    is($matched->[0]{headers}, $etag,
        '304 retains validator and cache metadata');
    is($dispatch->(response_headers => [['Last-Modified', $date]],
        request_headers => [['If-None-Match', '*']])->[0]{status}, 304,
        'wildcard matches eligible representation without an ETag');
    for my $value ('"other"', '"a,b", nope', '') {
        is($dispatch->(response_headers => $etag,
            request_headers => [ ['If-None-Match', $value],
                ['If-Modified-Since', $date] ])->[0]{status}, 200,
            'present If-None-Match suppresses date fallback');
    }
    is($dispatch->(response_headers => [['ETag', '"valid"']],
        request_headers => [['If-None-Match', '"valid", garbage']])
        ->[0]{status}, 200,
        'a valid prefix cannot match when the complete list is malformed');
    is($dispatch->(response_headers => [['Last-Modified', $date]],
        request_headers => [['If-None-Match', '"other"'],
            ['If-Modified-Since', $date]])->[0]{status}, 200,
        'missing current ETag does not trigger date fallback');
    is($dispatch->(response_headers => $etag,
        request_headers => [['If-Modified-Since', $date]])->[0]{status}, 304,
        'date remains effective when If-None-Match is absent');
    for my $headers ([['ETag', 'w/"simple"']],
            [['ETag', '"simple"'], ['ETag', '"simple"']]) {
        is($dispatch->(response_headers => $headers,
            request_headers => [['If-None-Match', '"simple"']])
            ->[0]{status}, 200,
            'malformed or duplicate response ETag is not matched');
    }
    for my $status (204, 205, 302, 404) {
        is($dispatch->(status => $status, response_headers => $etag,
            request_headers => [['If-None-Match', '*']])->[0]{status}, $status,
            'response without an eligible representation passes through');
    }
    for my $method ('POST', 'get') {
        is($dispatch->(method => $method, response_headers => $etag,
            request_headers => $matching)->[0]{status}, 200,
            'method outside exact GET/HEAD passes through');
    }
    is($dispatch->(method => 'HEAD', response_headers => $etag,
        request_headers => $matching)->[0]{status}, 304, 'HEAD may select 304');
    is($dispatch->(type => 'sse', response_headers => $etag,
        request_headers => $matching)->[0]{status}, 200,
        'non-HTTP scope passes through');
};

subtest 'A4: post-304 trailers from the wrapped app never reach the strict client' => sub {
    my $mw = PAGI::Middleware::ConditionalGet->new;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type     => 'http.response.start',
            status   => 200,
            headers  => [['etag', '"abc"'], ['trailer', 'x-checksum']],
            trailers => 1,
        });
        await $send->({ type => 'http.response.body', body => 'hello', more => 0 });
        await $send->({ type => 'http.response.trailers', headers => [['x-checksum', 'deadbeef']] });
    };
    my $wrapped = $mw->wrap($app);

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $res = PAGI::Test::Client->new(app => $wrapped)->get(
        '/', headers => { 'if-none-match' => '"abc"' },
    );

    is $res->status, 304, 'clean 304 response';
    is scalar(@warnings), 0, 'no warning: post-304 events are swallowed' or diag(@warnings);
};

done_testing;
