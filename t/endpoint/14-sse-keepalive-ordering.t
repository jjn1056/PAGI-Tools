#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Endpoint::SSE;
use PAGI::Test::Client;

# DEVIATION D-1 (signed off by John 2026-08-25): Endpoint::SSE::handle arms
# keepalive (Endpoint/SSE.pm:27-30) BEFORE on_connect/start, while the
# PAGI::SSE object is pre-start. Both PAGI::SendValidation and the reference
# server's EventValidator reject sse.keepalive sent before sse.start -- so
# every keepalive_interval > 0 endpoint fails every request against a strict
# server. Fixed by deferred-arm: keepalive() called pre-start records the
# desired interval/comment instead of sending; start() arms the recorded
# keepalive immediately afterward, where it is legal.
#
# These tests drive the real Endpoint::SSE -> PAGI::Test::Client path (the
# strict client Task 8 deliberately avoided exercising with
# keepalive_interval > 0, precisely because of this bug) and additionally
# wrap $send with a spy to observe wire ordering directly.

package KeepaliveEndpoint {
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;

    sub keepalive_interval { 5 }

    async sub on_connect {
        my ($self, $ctx) = @_;
        await $ctx->sse->send_event(event => 'connected', data => { ok => 1 });
    }
}

# Wraps an endpoint's to_app coderef with a $send spy so the exact wire
# event order can be inspected, while still routing every event through the
# real (strict) $send that PAGI::Test::Client/PAGI::Test::SSE supplies --
# so a validation failure still surfaces exactly as it would for a real
# caller.
sub spy_wrap {
    my ($endpoint_class) = @_;
    my $real_app = $endpoint_class->to_app;
    my @observed;
    my $wrapped = async sub {
        my ($scope, $receive, $send) = @_;
        my $spy_send = async sub {
            my ($event) = @_;
            push @observed, $event;
            return await $send->($event);
        };
        return await $real_app->($scope, $receive, $spy_send);
    };
    return ($wrapped, \@observed);
}

subtest 'keepalive_interval > 0 endpoint succeeds under the strict Test::Client' => sub {
    my ($app, $observed) = spy_wrap('KeepaliveEndpoint');
    my $client = PAGI::Test::Client->new(app => $app);

    my $sse;
    ok(lives { $sse = $client->sse('/events') },
        'request does not die -- sse.keepalive is no longer sent before sse.start')
        or note $@;

    isa_ok($sse, ['PAGI::Test::SSE'], 'a real SSE connection was established, not a decline');

    my @types = map { $_->{type} } @$observed;
    my ($start_idx)     = grep { $types[$_] eq 'sse.start' }     0 .. $#types;
    my ($keepalive_idx) = grep { $types[$_] eq 'sse.keepalive' } 0 .. $#types;

    ok(defined $start_idx,     'sse.start was sent');
    ok(defined $keepalive_idx, 'sse.keepalive was sent');
    ok($keepalive_idx > $start_idx, 'sse.keepalive appears AFTER sse.start in the captured stream')
        or note('observed: ' . join(',', @types));

    is($observed->[$keepalive_idx]{interval}, 5, 'the armed interval matches keepalive_interval');
};

package DeclineWithKeepalive {
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;

    sub keepalive_interval { 5 }

    async sub on_connect {
        my ($self, $ctx) = @_;
        await $ctx->sse->decline(status => 401, body => 'Unauthorized');
    }
}

subtest 'decline from on_connect with keepalive_interval > 0: no keepalive event at all, no violation' => sub {
    my ($app, $observed) = spy_wrap('DeclineWithKeepalive');
    my $client = PAGI::Test::Client->new(app => $app);

    my $res;
    ok(lives { $res = $client->sse('/events') },
        'request does not die -- the recorded-but-never-armed keepalive causes no violation')
        or note $@;

    isa_ok($res, ['PAGI::Test::Response'], 'the decline still yields a real HTTP response');
    is($res->status, 401, 'decline status reaches the client');

    my @types = map { $_->{type} } @$observed;
    ok(!(grep { $_ eq 'sse.keepalive' } @types), 'no sse.keepalive event ever reached the wire')
        or note('observed: ' . join(',', @types));
    ok(!(grep { $_ eq 'sse.start' } @types), 'no sse.start event ever reached the wire either');
};

done_testing;
