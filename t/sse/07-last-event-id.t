#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;

use lib 'lib';
use PAGI::SSE;

subtest 'last_event_id returns header value' => sub {
    my $scope = {
        type    => 'sse',
        headers => [
            ['last-event-id', '42'],
        ],
    };

    my $sse = PAGI::SSE->new($scope, sub {}, sub {});

    is($sse->last_event_id, '42', 'returns last-event-id header');
};

subtest 'last_event_id is case-insensitive' => sub {
    my $scope = {
        type    => 'sse',
        headers => [
            ['Last-Event-ID', 'abc-123'],
        ],
    };

    my $sse = PAGI::SSE->new($scope, sub {}, sub {});

    is($sse->last_event_id, 'abc-123', 'case-insensitive lookup');
};

subtest 'last_event_id returns undef when missing' => sub {
    my $scope = {
        type    => 'sse',
        headers => [],
    };

    my $sse = PAGI::SSE->new($scope, sub {}, sub {});

    is($sse->last_event_id, undef, 'undef when no header');
};

subtest 'query helpers preserve decoded raw values and HTTP metadata' => sub {
    my $sse = PAGI::SSE->new({
        type         => 'sse',
        query_string => 'name=caf%C3%A9&tag=one&tag=two&raw=%FF',
        http_version => '2',
        headers      => [],
    }, sub {}, sub {});

    is($sse->query_param('name'), "caf\x{e9}",
        'query_param decodes a UTF-8 value');
    is([$sse->query_params->get_all('tag')], ['one', 'two'],
        'query_params retains repeated values');
    is($sse->raw_query_param('raw'), "\xff",
        'raw_query_param preserves undecoded bytes');
    is($sse->raw_query_params->get('name'), "caf\xc3\xa9",
        'raw_query_params preserves percent-decoded UTF-8 bytes');
    is($sse->http_version, '2', 'http_version reads direct scope metadata');
};

done_testing;
