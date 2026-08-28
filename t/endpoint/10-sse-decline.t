#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use PAGI::Endpoint::SSE;
use PAGI::Test::Client;

# A2 end-to-end: an Endpoint::SSE subclass that declines from on_connect
# (the Cookbook auth-gate pattern) must, under the strict PAGI::Test::Client,
# yield a real 401 response -- never an sse.start, never an exception. This
# reproduces the bug found live during review: Endpoint::SSE.pm:48
# unconditionally awaited $sse->run after on_connect, so a decline left the
# PAGI::SSE object "pending" and run() went on to emit sse.start AFTER a
# completed decline -- a MUST-raise under the server's mandatory first-send-
# wins validation (PAGI::Spec::Www.pod, SSE Response Denial).

package DeclineOnConnect {
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;

    async sub on_connect {
        my ($self, $sse) = @_;
        await $sse->decline(
            status  => 401,
            headers => [['content-type', 'text/plain'], ['www-authenticate', 'Bearer']],
            body    => 'Unauthorized',
        );
    }
}

subtest 'on_connect decline yields a real 401 response, no sse.start, no exception' => sub {
    my $app = DeclineOnConnect->to_app;
    my $client = PAGI::Test::Client->new(app => $app);

    my $res;
    ok(lives { $res = $client->sse('/events') }, 'no exception for a decline from on_connect')
        or note $@;

    isa_ok($res, ['PAGI::Test::Response'], 'client hands back a real HTTP response, not an SSE connection');
    is($res->status, 401, 'decline status reaches the client');
    is($res->content, 'Unauthorized', 'decline body reaches the client');
    is($res->header('www-authenticate'), 'Bearer', 'decline headers reach the client');
};

package DeclineThenTryToStream {
    use parent 'PAGI::Endpoint::SSE';
    use Future::AsyncAwait;

    our $post_decline_exception;

    async sub on_connect {
        my ($self, $sse) = @_;
        await $sse->decline(status => 403, body => 'Forbidden');
    }
}

subtest 'handle() does not call run() (and therefore never sends sse.start) after a decline' => sub {
    # Under PAGI::SendValidation (wired into PAGI::Test::SSE), a stray
    # sse.start sent after a completed decline fails the send outright --
    # so if handle()'s guard were missing, this would die instead of
    # returning a clean 403.
    my $app = DeclineThenTryToStream->to_app;
    my $client = PAGI::Test::Client->new(app => $app);

    my $res;
    ok(lives { $res = $client->sse('/events') }, 'no exception -- the guarded run() never sends a post-decline sse.start')
        or note $@;
    is($res->status, 403, 'decline status still reaches the client');
};

done_testing;
