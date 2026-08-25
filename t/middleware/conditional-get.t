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
