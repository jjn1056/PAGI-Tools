#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Time::HiRes ();

use PAGI::Test::Client;
use Test::Lib;
use PAGITest::LowercaseHeaders;

# Events an app sends.
sub start_event { return { type => 'http.response.start', status => 200, headers => [['content-type', 'text/plain'], @_] } }
sub chunk_event { my ($body, $more) = @_; return { type => 'http.response.body', body => $body, more => $more // 1 } }

# A client for one app, and the connection its last request had.
my $connection;
sub client_for {
    my ($app, %args) = @_;
    return PAGI::Test::Client->new(%args, app => async sub {
        my ($scope, $receive, $send) = @_;
        $connection = $scope->{'pagi.connection'};
        await $app->($scope, $receive, $send);
    });
}

# Waits for whichever comes first: $future, or the client leaving. Returns
# undef if the client left.
async sub until_left {
    my ($scope, $future) = @_;
    my $left = $scope->{'pagi.connection'}->disconnect_future;
    my $first = await Future->wait_any($future->then(sub { Future->done(1) }), $left->then(sub { Future->done(0) }));
    return $first ? await $future : undef;
}

subtest 'each chunk as it was sent, then undef; the response completes' => sub {
    my $stream = client_for(async sub {
        my ($scope, $receive, $send) = @_;
        await $send->(start_event());
        for my $body (qw(a b)) { await $send->(chunk_event($body)) }
        await $send->(chunk_event('c', 0));
    })->stream('/');
    is [map { $stream->receive_chunk } 1 .. 3], [qw(a b c)], 'one chunk per body event, in order';
    is $stream->receive_chunk, undef, 'then undef: the response is over';
    ok $stream->response->body_complete, 'it completed';
    is $stream->response->content, 'abc', 'and the response holds the whole body';
    ok $stream->is_closed, 'the stream is over';
    is $connection->disconnect_reason, undef, 'a clean end records no reason';
};

subtest 'stream returns before the start, and before the end' => sub {
    my ($before_start, $mid_body) = (Future->new, Future->new);
    my $stream = client_for(async sub {
        my ($scope, $receive, $send) = @_;
        await $before_start;
        await $send->(start_event());
        await $send->(chunk_event('a'));
        await $mid_body;
        await $send->(chunk_event('b', 0));
    })->stream('/');
    is $stream->response, undef, 'nothing sent yet: no response';
    ok !$stream->is_closed, 'and not over';
    $before_start->done;
    is $stream->receive_chunk, 'a', 'the first chunk, once sent';
    is $stream->response->status, 200, 'the start came with it';
    ok !$stream->is_closed, 'not over: the app is still writing';
    $mid_body->done;
    is $stream->receive_chunk, 'b', 'the next';
    is $stream->receive_chunk, undef, 'then the end';
};

subtest 'a receive_chunk already waiting wakes when the chunk, or the end, arrives' => sub {
    require Future::IO;
    my $stream = client_for(async sub {
        my ($scope, $receive, $send) = @_;
        await $send->(start_event());
        await Future::IO->sleep(0.05);          # real I/O between writes
        await $send->(chunk_event('late'));
        await Future::IO->sleep(0.05);
        await $send->(chunk_event('', 0));
    })->stream('/');
    my $started = Time::HiRes::time();
    is $stream->receive_chunk(timeout => 3), 'late', 'the chunk sent while it waited';
    is $stream->receive_chunk(timeout => 3), undef, 'then the end, while it waited';
    ok Time::HiRes::time() - $started < 1, 'each as it arrived, not at the timeout';

    my $forever = Future->new;
    $stream = client_for(async sub {
        my ($scope, $receive, $send) = @_;
        await $send->(start_event());
        await Future::IO->sleep(0.05);
        $scope->{'pagi.connection'}->abort('enough');
        await $forever;                         # aborted, but still running
    })->stream('/');
    $started = Time::HiRes::time();
    is $stream->receive_chunk(timeout => 3), undef, 'an abort while it waited: undef';
    ok Time::HiRes::time() - $started < 1, 'as it happened';
    $forever->cancel;
};

subtest 'a response that completes: on_complete and on_end run, end_future is done' => sub {
    require Future::IO;
    my @seen;
    my $stream = client_for(async sub {
        my ($scope, $receive, $send) = @_;
        my $connection = $scope->{'pagi.connection'};
        $connection->on_complete(sub { push @seen, 'complete' });
        $connection->on_end(sub { push @seen, 'end' });
        await $send->(start_event());
        await Future::IO->sleep(0.02);          # completes after stream returns
        await $send->(chunk_event('a', 0));
        await $connection->end_future;          # cleanup after the response
        push @seen, 'cleaned up';
    })->stream('/');
    is $stream->receive_chunk, 'a', 'the chunk';
    is $stream->receive_chunk, undef, 'then the end';
    is \@seen, ['complete', 'end', 'cleaned up'], 'each callback ran, and the app got past end_future';
};

subtest 'the app dies while receive_chunk waits: undef, at once' => sub {
    require Future::IO;
    my $stream = client_for(async sub {
        my ($scope, $receive, $send) = @_;
        await $send->(start_event());
        await Future::IO->sleep(0.05);
        die "late\n";
    })->stream('/');
    my $started = Time::HiRes::time();
    is $stream->receive_chunk(timeout => 3), undef, 'undef: the response is over';
    ok Time::HiRes::time() - $started < 1, 'as it happened, not at the timeout';
    is $stream->response->exception, "late\n", 'the error is on the response';
};

subtest 'an event with no bytes is not a chunk' => sub {
    my $stream = client_for(async sub {
        my ($scope, $receive, $send) = @_;
        await $send->(start_event());
        await $send->(chunk_event(''));
        await $send->(chunk_event('a'));
        await $send->(chunk_event('', 0));
    })->stream('/');
    is $stream->receive_chunk, 'a', 'the empty write is skipped';
    is $stream->receive_chunk, undef, 'and so is the empty last event';
};

subtest 'receive_chunk waits up to its timeout, then dies' => sub {
    my $stream = client_for(async sub {
        my ($scope, $receive, $send) = @_;
        await $send->(start_event());
        await until_left($scope, Future->new);
    })->stream('/');
    my $started = Time::HiRes::time();
    like dies { $stream->receive_chunk(timeout => 0.2) }, qr/\ATimeout waiting for a response body chunk/, 'it says so';
    ok Time::HiRes::time() - $started < 2, 'at the timeout';
    $stream->close;
};

subtest 'close before any write: the client leaves' => sub {
    my @seen;
    my $stream = client_for(async sub {
        my ($scope, $receive, $send) = @_;
        await $receive->();                     # the request
        push @seen, (await $receive->())->{type};
        my $sent = $send->(start_event());
        push @seen, $sent->is_done ? 'send succeeded' : 'send did not succeed';
    })->stream('/');
    $stream->close;
    is \@seen, ['http.disconnect', 'send succeeded'], 'a waiting receive gets the disconnect; a later send succeeds';
    is $stream->response, undef, 'and is not recorded';
    is $connection->disconnect_reason, 'client_closed', 'client_closed';
    is $connection->disconnect_detail, undef, 'with no detail';
    ok $stream->is_closed, 'the stream is over';
    is $stream->receive_chunk, undef, 'nothing more to read';
    ok lives { $stream->close }, 'a second close does nothing';
};

subtest 'close mid-body: what was read stays' => sub {
    my $stream = client_for(async sub {
        my ($scope, $receive, $send) = @_;
        await $send->(start_event());
        await $send->(chunk_event('a'));
        await until_left($scope, Future->new);
    })->stream('/');
    is $stream->receive_chunk, 'a', 'a chunk';
    $stream->close;
    is $stream->response->content, 'a', 'it stays in the response';
    ok !$stream->response->body_complete, 'which never completed';
    is $connection->disconnect_reason, 'client_closed', 'client_closed';
};

subtest 'close runs the app until it has reacted' => sub {
    require Future::IO;
    my @seen;
    my $stream = client_for(async sub {
        my ($scope, $receive, $send) = @_;
        await $send->(start_event());
        await until_left($scope, Future->new);
        await Future::IO->sleep(0.05);          # the app does real work on leaving
        push @seen, 'cleaned up';
    })->stream('/');
    $stream->close;
    is \@seen, ['cleaned up'], 'done by the time close returns';
};

subtest 'an app that ignores the client leaving: close cancels it and dies' => sub {
    local $PAGI::Test::_Drive::TIMEOUT = 0.3;
    my $forever = Future->new;
    my $stream = client_for(async sub {
        my ($scope, $receive, $send) = @_;
        await $send->(start_event());
        await $forever;                         # never notices
    })->stream('/');
    like dies { $stream->close }, qr/\APAGI application did not end within 0\.3 seconds after the client left/, 'it says why';
    ok $forever->is_cancelled, 'the app was cancelled, so it cannot resume in another test';
};

subtest 'two streams open, and a request between them' => sub {
    my @waiting;
    my $client = client_for(async sub {
        my ($scope, $receive, $send) = @_;
        if ($scope->{path} eq '/publish') {
            my @followers = splice @waiting;
            $_->done($scope->{query_string}) for @followers;
            await $send->(start_event());
            return await $send->(chunk_event(scalar @followers, 0));
        }
        await $send->(start_event());
        await $send->(chunk_event("hello\n"));
        while (1) {
            push @waiting, my $next = Future->new;
            my $message = await until_left($scope, $next);
            return unless defined $message;     # the client left
            await $send->(chunk_event("$message\n"));
        }
    });
    my ($one, $two) = map { $client->stream('/feed') } 1 .. 2;
    is [map { $_->receive_chunk } $one, $two], ["hello\n", "hello\n"], 'each has the greeting';
    is $client->get('/publish?hi')->content, '2', 'a request while both are open';
    is [map { $_->receive_chunk } $one, $two], ["hi\n", "hi\n"], 'each gets the message';
    $one->close;
    @waiting = grep { !$_->is_ready } @waiting;
    is $client->get('/publish?again')->content, '1', 'one is left';
    is $two->receive_chunk, "again\n", 'and it keeps receiving';
    $two->close;
};

subtest 'how a response ends' => sub {
    my $stream;
    my $warned = warnings {
        $stream = client_for(async sub {
            my ($scope, $receive, $send) = @_;
            await $send->(start_event());
            await $send->(chunk_event('a'));
        })->stream('/');
    };
    like $warned, [qr/\Aincomplete response: /], 'returns after the start, unfinished: the warning get gives';
    is [$connection->disconnect_reason, $connection->disconnect_detail], ['server_error', undef], 'server_error, as get records it';
    is $stream->receive_chunk, 'a', 'what was sent stays readable';
    is $stream->receive_chunk, undef, 'then undef';

    $warned = warnings {
        client_for(async sub {
            my ($scope, $receive, $send) = @_;
            await $send->({ %{ start_event() }, trailers => 1 });
            await $send->(chunk_event('a', 0));
        })->stream('/');
    };
    like $warned, [qr/\Aincomplete response: /], 'trailers declared, never sent: warned';
    is $connection->disconnect_reason, 'server_error', 'server_error';

    $stream = client_for(async sub {
        my ($scope, $receive, $send) = @_;
        await $send->(start_event());
        await $send->(chunk_event('a'));
        die "broke\nsecond line\n";
    })->stream('/');
    is [$connection->disconnect_reason, $connection->disconnect_detail], ['server_error', undef], 'dies after the start: server_error';
    is $stream->response->exception, "broke\nsecond line\n", 'the error is on the response';
    is [$stream->response->status, $stream->response->content], [200, 'a'], 'and what was sent stays';

    $stream = client_for(async sub { die "nope\n" })->stream('/');
    is [$stream->response->status, $stream->response->content], [500, 'Internal Server Error'], 'dies before the start: a 500, as get gives';
    is [$connection->disconnect_reason, $connection->disconnect_detail], ['server_error', undef], 'server_error';
    is $stream->response->exception, "nope\n", 'and the error';

    $warned = warnings { $stream = client_for(async sub { return })->stream('/') };
    like $warned, [qr/\Aincomplete response: /], 'returns without starting: warned';
    is $stream->response->status, 500, 'a 500';
    is [$connection->disconnect_reason, $connection->disconnect_detail], ['server_error', undef], 'server_error';

    my @seen;
    $stream = client_for(async sub {
        my ($scope, $receive, $send) = @_;
        await $send->(start_event());
        await $send->(chunk_event('a'));
        await $receive->();                     # the request
        my $waiting = $receive->();             # waiting when the abort comes
        $scope->{'pagi.connection'}->abort('enough');
        push @seen, (await $waiting)->{type};
    })->stream('/');
    is [$connection->disconnect_reason, $connection->disconnect_detail], ['app_abort', 'enough'], 'aborts: app_abort, its detail';
    is \@seen, ['http.disconnect'], 'a waiting receive gets the disconnect';
    is $stream->receive_chunk, 'a', 'what was sent stays readable';
    is $stream->receive_chunk, undef, 'then undef, at once';

    @seen = ();
    client_for(async sub {
        my ($scope, $receive, $send) = @_;
        await $send->(start_event());
        $scope->{'pagi.connection'}->abort('enough');
        await $receive->();                     # the request
        push @seen, (await $receive->())->{type};
    })->stream('/');
    is \@seen, ['http.disconnect'], 'a receive made after the abort gets the disconnect too';
};

subtest 'an ending is recorded when the app ends, not when the test next looks' => sub {
    my $gate = Future->new;
    my $stream = client_for(async sub {
        my ($scope, $receive, $send) = @_;
        await $send->(start_event());
        await $gate;
        die "late\n";
    })->stream('/');
    $gate->done;
    is $connection->disconnect_reason, 'server_error', 'recorded as the app failed';
    ok $stream->is_closed, 'and the stream is over';

    my @seen;
    $gate = Future->new;
    $stream = client_for(async sub {
        my ($scope, $receive, $send) = @_;
        $scope->{'pagi.connection'}->on_complete(sub { push @seen, 'complete' });
        await $send->(start_event());
        await $gate;
        await $send->(chunk_event('a', 0));
    })->stream('/');
    $gate->done;
    is \@seen, ['complete'], 'on_complete runs as the app completes';
};

subtest 'the path comes first, as for get; the method defaults to GET' => sub {
    my $seen;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        my $event = await $receive->();
        $seen = "$scope->{method} $scope->{path} $event->{body}";
        await $send->(start_event());
        await $send->(chunk_event('ok', 0));
    };
    client_for($app)->stream('/feed')->close;
    is $seen, 'GET /feed ', 'a path alone: GET';
    client_for($app)->stream('/jobs', method => 'post', json => { id => 42 })->close;
    is $seen, 'POST /jobs {"id":42}', 'method as an option, any case; the rest as get takes them';
};

subtest 'a stream sees what get sees' => sub {
    my $bad_header = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->(start_event(['x-note', "a\r\nb"]));
    };
    is client_for($bad_header)->stream('/')->response->exception, client_for($bad_header)->get('/')->exception,
        'a header the client refuses: the same refusal';

    my $page = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->(start_event());
        await $send->(chunk_event('abc', 0));
    };
    my $head = client_for($page)->stream('/', method => 'HEAD');
    is $head->receive_chunk, undef, 'HEAD: no body chunks';
    is [$head->response->content, $head->response->body_complete], [client_for($page)->head('/')->content, 1],
        'the empty, complete body head gives';

    my $no_content = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 204, headers => [] });
        await $send->(chunk_event('abc', 0));
    };
    my $empty = client_for($no_content)->stream('/');
    is $empty->receive_chunk, undef, '204: no body chunks';
    is $empty->response->content, client_for($no_content)->get('/')->content, 'the empty body get gives';

    my $client = client_for(async sub {
        my ($scope, $receive, $send) = @_;
        my ($cookie) = map { $_->[1] } grep { $_->[0] eq 'cookie' } @{ $scope->{headers} };
        if ($scope->{path} eq '/echo') {
            await $send->(start_event());
            return await $send->(chunk_event($cookie // 'none', 0));
        }
        await $send->(start_event(['set-cookie', 'sid=1; Path=/']));
        await $send->(chunk_event('x'));
        await until_left($scope, Future->new);
    });
    my $stream = $client->stream('/');
    is $stream->receive_chunk, 'x', 'a stream whose start sets a cookie';
    is $client->get('/echo')->content, 'sid=1', 'is stored at the start, while the stream is open';
    $stream->close;
};

subtest 'callback style: the client leaves when it returns' => sub {
    my $inner;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->(start_event());
        await $send->(chunk_event('a'));
        await until_left($scope, Future->new);
    };
    my @returned = client_for($app)->stream('/', sub { $inner = shift; is $inner->receive_chunk, 'a', 'inside' });
    is \@returned, [], 'returns nothing';
    ok $inner->is_closed, 'closed after';
    is $connection->disconnect_reason, 'client_closed', 'by the client leaving';

    like dies { client_for($app)->stream('/', sub { $inner = shift; die "test broke\n" }) }, qr/\Atest broke/,
        "the callback's error";
    ok $inner->is_closed, 'closed after a die too';
};

subtest 'raise_app_exceptions: a failure is raised, not recorded' => sub {
    like dies {
        client_for(async sub {
            my ($scope, $receive, $send) = @_;
            await $send->(start_event());
            die "broke\n";
        }, raise_app_exceptions => 1)->stream('/');
    }, qr/\Abroke/, 'from stream, when the app has already failed';
};

done_testing;
