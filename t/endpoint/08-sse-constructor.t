#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::SSE;

{
    package Local::WrongSSECache;
    sub new { return bless { scope => $_[1] }, $_[0] }
    sub scope { return $_[0]{scope} }
}

subtest 'can create SSE endpoint subclass' => sub {
    require PAGI::Endpoint::SSE;

    package NotificationEndpoint {
        use parent 'PAGI::Endpoint::SSE';
        use Future::AsyncAwait;

        async sub on_connect {
            my ($self, $sse) = @_;
            await $sse->send_event(event => 'welcome', data => { time => time() });
        }

        sub on_disconnect {
            my ($self, $sse) = @_;
            # cleanup subscriber
        }
    }

    my $endpoint = NotificationEndpoint->new;
    isa_ok($endpoint, 'PAGI::Endpoint::SSE');
};

subtest 'keepalive_interval has default' => sub {
    require PAGI::Endpoint::SSE;

    is(PAGI::Endpoint::SSE->keepalive_interval, 0, 'default keepalive_interval is 0 (disabled)');
};

subtest 'subclass can override keepalive' => sub {
    package LiveEndpoint {
        use parent 'PAGI::Endpoint::SSE';
        sub keepalive_interval { 30 }
    }

    is(LiveEndpoint->keepalive_interval, 30, 'custom keepalive_interval');
};

subtest 'app reuses only a compatible exact-scope SSE cache' => sub {
    {
        package CacheAwareEndpoint;
        use parent 'PAGI::Endpoint::SSE';
        our $seen;
        sub on_connect {
            ($seen) = $_[1];
            return $_[1]->start;
        }
    }

    for my $case (
        'parent SSE',
        'wrong class',
        'throwing scope',
        'same scope SSE',
    ) {
        subtest $case => sub {
            my $scope = { type => 'sse', path => '/events', headers => [] };
            my $parent_scope = { type => 'sse', path => '/parent', headers => [] };
            my $parent = PAGI::SSE->new(
                $parent_scope, sub { Future->done }, sub { Future->done },
            );
            my $cached = $case eq 'parent SSE'
                ? $parent
                : $case eq 'wrong class'
                    ? Local::WrongSSECache->new($scope)
                    : $case eq 'throwing scope'
                        ? bless({}, 'PAGI::SSE')
                        : PAGI::SSE->new(
                            $scope,
                            sub { Future->done({ type => 'sse.disconnect' }) },
                            sub { Future->done },
                        );
            $scope->{'pagi.sse'} = $cached;
            $CacheAwareEndpoint::seen = undef;

            my $run = sub {
                CacheAwareEndpoint->to_app->(
                    $scope,
                    sub { Future->done({ type => 'sse.disconnect' }) },
                    sub { Future->done },
                )->get;
            };
            if ($case eq 'throwing scope') {
                no warnings 'redefine';
                local *PAGI::SSE::scope = sub { die 'cached scope exploded' };
                $run->();
            }
            else {
                $run->();
            }

            isa_ok($CacheAwareEndpoint::seen, ['PAGI::SSE'],
                'the endpoint receives an SSE stream');
            is(refaddr($CacheAwareEndpoint::seen->scope), refaddr($scope),
                'the endpoint stream owns the selected scope');
            if ($case eq 'same scope SSE') {
                is(refaddr($CacheAwareEndpoint::seen), refaddr($cached),
                    'the same-scope exact class cache is reused');
            }
            else {
                isnt(refaddr($CacheAwareEndpoint::seen), refaddr($cached),
                    'the incompatible cached object is replaced');
            }
        };
    }
};

done_testing;
