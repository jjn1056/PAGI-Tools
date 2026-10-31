#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use lib 'lib';

use PAGI::Middleware::ConditionalGet;

my $loop = IO::Async::Loop->new;

# D1: a repeated If-Modified-Since reads joined "date1, date2", which
# HTTP::Date cannot parse, so the condition is not met and the client gets
# the full response (before D1 the last date alone could produce a 304).
subtest 'repeated If-Modified-Since gets the full response' => sub {
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['last-modified', 'Wed, 21 Oct 2026 07:28:00 GMT']],
        });
        await $send->({ type => 'http.response.body', body => 'hello', more => 0 });
    };
    my $wrapped = PAGI::Middleware::ConditionalGet->new->wrap($app);

    my @sent;
    $loop->await($wrapped->(
        {
            type => 'http', path => '/', method => 'GET',
            headers => [
                ['if-modified-since', 'Wed, 21 Oct 2020 07:28:00 GMT'],
                ['if-modified-since', 'Wed, 21 Oct 2026 07:28:00 GMT'],
            ],
        },
        async sub { { type => 'http.disconnect' } },
        async sub { my ($event) = @_; push @sent, $event },
    ));

    is $sent[0]{status}, 200, 'two If-Modified-Since fields: full response';
    is $sent[1]{body}, 'hello', 'body sent';
};

done_testing;
