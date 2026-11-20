use v5.24;
use warnings;
use utf8;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use PAGI::Test::Client;
use Test::Lib;
use PAGITest::LowercaseHeaders;

use PAGI::Response::Stream;

# Serves a response for one GET, as a strict server would.
sub get { PAGI::Test::Client->new(app => $_[0])->get('/') }

# The headers the response sent: all but the Date the client adds, as a server does.
sub sent_headers { [grep { $_->[0] ne 'date' } @{ $_[0]->header_pairs }] }

# A $send that records each event with the Future it returned, which the
# test settles: a server that takes its time.
sub recording_send {
    my @sent;
    return (sub { push @sent, { event => $_[0], future => Future->new }; $sent[-1]{future} }, \@sent);
}

# Calls a response with a recording $send and a connection still open;
# returns call's Future, what was sent, and the connection.
sub call_recorded {
    my ($response) = @_;
    require PAGI::Test::ConnectionState;
    my ($send, $sent) = recording_send();
    my $connection = PAGI::Test::ConnectionState->new;
    my $scope = { type => 'http', method => 'GET', 'pagi.connection' => $connection };
    my $call = $response->call($scope, sub { Future->new }, $send);
    return ($call, $sent, $connection);
}

# What each recorded event was, in a word or two.
sub sent_kinds {
    my ($sent) = @_;
    return [map {
        my $e = $_->{event};
        $e->{type} eq 'http.response.start' ? 'start'
            : $e->{type} eq 'http.response.body' ? ($e->{more} ? "body $e->{body}" : 'end')
            : $e->{type}
    } @$sent];
}

subtest 'body: code, required' => sub {
    like dies { PAGI::Response::Stream->new }, qr/\Abody must be code: /, 'none: says what to give';
    like dies { PAGI::Response::Stream->new(body => 'abc') }, qr/\Abody must be code: /, 'not code: the same';
    my $body = async sub { };
    is(PAGI::Response::Stream->new(body => $body)->body, exact_ref($body), 'body returns the code given');
};

subtest 'what the body writes, then the end when it returns' => sub {
    my $res = get(PAGI::Response::Stream->new(content_type => 'text/plain', body => async sub {
        my ($writer) = @_;
        await $writer->write('a');
        await $writer->write('b');
    }));
    is $res->status, 200, 'status 200';
    is $res->content, 'ab', 'each write, in order';
    ok $res->body_complete, 'and the end';
    is sent_headers($res), [['content-type', 'text/plain']], 'no Content-Length: the length is not known';
};

subtest 'a Content-Length you give is sent as given' => sub {
    my $res = get(PAGI::Response::Stream->new(headers => [['Content-Length', 2]], body => async sub {
        await $_[0]->write('ab');
    }));
    is sent_headers($res), [['content-length', 2]], 'yours';
    is $res->content, 'ab', 'and the body';
};

subtest 'a body that writes nothing: the start and the end' => sub {
    my $res = get(PAGI::Response::Stream->new(status => 202, body => async sub { }));
    is [$res->status, $res->content], [202, ''], 'the status, no body';
    ok $res->body_complete, 'complete';
};

subtest 'the start goes out with the first write; an empty write sends nothing' => sub {
    my $gate = Future->new;
    my ($call, $sent) = call_recorded(PAGI::Response::Stream->new(body => async sub {
        my ($writer) = @_;
        await $writer->write('');
        await $gate;
        await $writer->write('a');
    }));
    is sent_kinds($sent), [], 'an empty write: nothing, not even the start';
    $gate->done;
    is sent_kinds($sent), ['start'], 'the first write: the start first';
    $sent->[0]{future}->done;
    is sent_kinds($sent), ['start', 'body a'], 'then its chunk';
    $sent->[1]{future}->done;
    is sent_kinds($sent), ['start', 'body a', 'end'], 'the body returned: the end';
    $sent->[2]{future}->done;
    ok $call->is_done, 'call is done once the end has gone';
};

subtest 'writes not awaited go out in the order made, after one start' => sub {
    my ($call, $sent) = call_recorded(PAGI::Response::Stream->new(body => async sub {
        my ($writer) = @_;
        await Future->needs_all(map { $writer->write($_) } qw(a b c));
    }));
    $sent->[0]{future}->done;
    is sent_kinds($sent), ['start', 'body a', 'body b', 'body c'], 'one start, then each in call order';
    $_->{future}->done for @$sent[1 .. 3];
    $sent->[4]{future}->done;
    ok $call->is_done, 'then the end, and call is done';
};

subtest 'write_text: characters as UTF-8' => sub {
    my $text = "Zoë 🌍";
    my $res = get(PAGI::Response::Stream->new(body => async sub { await $_[0]->write_text($text) }));
    is $res->content, "Zo\xc3\xab \xf0\x9f\x8c\x8d", 'encoded';
    is $text, "Zoë 🌍", 'your string untouched';
    is get(PAGI::Response::Stream->new(body => async sub { await $_[0]->write("Grüße") }))->content, "Gr\xfc\xdfe",
        'write, given characters below 256: single bytes, Latin-1, as the POD warns';

    my $error;
    get(PAGI::Response::Stream->new(body => async sub {
        my ($writer) = @_;
        $error = dies { $writer->write_text("\x{D800}") };
    }));
    like $error, qr/UTF-8/, 'text UTF-8 cannot carry croaks at the call';
};

subtest 'write_item: what format_item makes of the item' => sub {
    {
        package Local::Lines;
        use parent -norequire, 'PAGI::Response::Stream';
        sub format_item { my ($self, $item) = @_; return "$item\n" }
    }
    my $body = async sub {
        my ($writer) = @_;
        for my $item (qw(a b)) { await $writer->write_item($item) }
    };
    is get(Local::Lines->new(body => $body))->content, "a\nb\n", 'a subclass formats each item';
    is get(PAGI::Response::Stream->new(body => $body))->content, 'ab', 'a plain Stream writes the item as it is';
};

subtest "connection: the request's pagi.connection" => sub {
    my $given;
    my ($call, $sent, $connection) = call_recorded(PAGI::Response::Stream->new(body => async sub { $given = $_[0]->connection }));
    is $given, exact_ref($connection), 'the one in the scope';
};

subtest 'writer_class: a subclass gives the body a writer of its own' => sub {
    {
        package Local::LoudWriter;
        use parent -norequire, 'PAGI::Response::Writer';
        sub write { my ($self, $bytes) = @_; return $self->SUPER::write(uc $bytes) }
    }
    {
        package Local::LoudStream;
        use parent -norequire, 'PAGI::Response::Stream';
        sub writer_class { 'Local::LoudWriter' }
    }
    my $given;
    my $res = get(Local::LoudStream->new(body => async sub {
        my ($writer) = @_;
        $given = ref $writer;
        await $writer->write('abc');
    }));
    is $given, 'Local::LoudWriter', 'the body gets the class it names';
    is $res->content, 'ABC', 'and its write is the one used';
    is(PAGI::Response::Stream->writer_class, 'PAGI::Response::Writer', 'by default, PAGI::Response::Writer');
};

subtest 'pipe_from: every chunk of a source until undef, waiting on each' => sub {
    {
        package Local::Source;
        sub new { my ($class, @chunks) = @_; return bless [@chunks], $class }
        sub next_chunk { my ($self) = @_; return shift @$self }
    }
    my $late = Future->new;
    my $source = Local::Source->new('a', Future->done('b'), '', $late, undef, 'never');
    my $stream = PAGI::Test::Client->new(app => PAGI::Response::Stream->new(body => async sub {
        my ($writer) = @_;
        await $writer->pipe_from($source);
        await $writer->write('!');
    }))->stream('/');
    is [map { $stream->receive_chunk } 1 .. 2], ['a', 'b'], 'chunks as they come, Futures waited for, the empty one skipped';
    $late->done('c');
    is [map { $stream->receive_chunk } 1 .. 3], ['c', '!', undef], 'until undef, then the body goes on';
    is $source, ['never'], 'nothing pulled after the undef';
};

subtest 'trailers: the ones the body returns, after the end' => sub {
    my $res;
    my $warnings = warnings {
        $res = get(PAGI::Response::Stream->new(has_trailers => 1, body => async sub {
            my ($writer) = @_;
            await $writer->write('a');
            return [['x-status', 'ok']];
        }));
    };
    is $warnings, [], 'a complete response: no warnings';
    is [$res->content, $res->trailer_pairs], ['a', [['x-status', 'ok']]], 'the body, then its trailers';
    ok(PAGI::Response::Stream->new(has_trailers => 1, body => async sub { })->has_trailers, 'has_trailers: declared');
    ok(!PAGI::Response::Stream->new(body => async sub { })->has_trailers, 'and not, unless declared');

    my $rows = 0;
    $warnings = warnings {
        $res = get(PAGI::Response::Stream->new(has_trailers => 1, body => async sub {
            my ($writer) = @_;
            for my $row (1 .. 5) {
                return [['x-status', 'truncated']] if $row > 2;   # an early end
                await $writer->write($row);
            }
            return [['x-status', 'complete']];
        }));
    };
    is [$res->content, $res->trailer_pairs], ['12', [['x-status', 'truncated']]], 'an early return ends it, with its trailers';

    $warnings = warnings {
        $res = get(PAGI::Response::Stream->new(has_trailers => 1, body => async sub { await $_[0]->write('a'); return }));
    };
    is $warnings, [], 'none returned: still complete';
    is $res->trailer_pairs, [], 'empty trailers';
};

subtest 'a 204 with trailers: the body runs, and the end and the trailers go' => sub {
    my ($ran, $res);
    my $warnings = warnings {
        $res = get(PAGI::Response::Stream->new(status => 204, has_trailers => 1, body => async sub {
            $ran = 1;
            await $_[0]->write('dropped');
            return [['x-status', 'ok']];
        }));
    };
    ok $ran, 'the body ran';
    is [$res->status, $res->content], [204, ''], 'a 204, its body dropped by the server';
    is $warnings, [], 'complete: the end and the trailers went';
};

subtest 'the client leaves while the body waits: the body is cancelled' => sub {
    my $waiting = Future->new;
    my $outcome;
    my $stream = PAGI::Test::Client->new(app => PAGI::Response::Stream->new(body => async sub {
        my ($writer) = @_;
        $writer->on_close(sub { $outcome = $_[0]->outcome });
        await $writer->write('a');
        await $waiting;
        await $writer->write('never');
    }))->stream('/');
    is $stream->receive_chunk, 'a', 'a chunk';
    $stream->close;
    ok $waiting->is_cancelled, 'what the body was waiting on is cancelled';
    is $stream->response->content, 'a', 'nothing after';
    is $outcome, 'disconnected', 'outcome: disconnected';
};

subtest 'the client left, but the news comes later: the writes stop at once' => sub {
    # As a server keeping PAGI::Spec 0.6 does it: once the client has gone, a
    # send does nothing and settles on a later turn of the event loop, after
    # the news of the leave, which is delivered on the loop too.
    my $connection = PAGI::Test::ConnectionState->new;
    my ($sends, $writes, $outcome) = (0, 0);
    my @later;    # sends made once the client had gone, settled on the next turn
    my $send = sub {
        if (++$sends == 3) {
            local $connection->{_defer_notifications} = 1;
            $connection->_mark_disconnected('client_closed');
        }
        return Future->done unless defined $connection->disconnect_reason;
        push @later, Future->new;
        return $later[-1];
    };
    my $call = PAGI::Response::Stream->new(body => async sub {
        my ($writer) = @_;
        $writer->on_close(sub { $outcome = $_[0]->outcome });
        while ($writes < 1000) { $writes++; await $writer->write('x') }    # awaits only writes
    })->call({ type => 'http', method => 'GET', 'pagi.connection' => $connection }, sub { Future->new }, $send);
    ok $writes < 10, "the body stopped writing once the client had gone ($writes writes)";
    ok !$call->is_ready, 'and waits for the news';
    # The next turn of the event loop: the news, then the sends it holds.
    $connection->_deliver_notifications;
    $_->done for grep { !$_->is_ready } @later;
    is $outcome, 'disconnected', 'which cancels the body: disconnected';
    ok $call->is_done, 'and call is done';
};

subtest 'a body that returns once the client has gone, before the news: disconnected, no end' => sub {
    {   # the POD's SUBCLASSING example
        package Polite::Writer;
        use parent -norequire, 'PAGI::Response::Writer';
        use Future::AsyncAwait;
        async sub write {
            my ($self, $bytes) = @_;
            return 0 if defined $self->connection->disconnect_reason;
            await $self->SUPER::write($bytes);
            return 1;
        }
        package Polite::Stream;
        use parent -norequire, 'PAGI::Response::Stream';
        sub writer_class { 'Polite::Writer' }
    }
    my $connection = PAGI::Test::ConnectionState->new;
    my ($sends, $outcome) = (0);
    my @sent;
    my $send = sub {
        push @sent, $_[0];
        if (++$sends == 3) {
            local $connection->{_defer_notifications} = 1;
            $connection->_mark_disconnected('client_closed');
        }
        return Future->done;
    };
    my $call = Polite::Stream->new(body => async sub {
        my ($writer) = @_;
        $writer->on_close(sub { $outcome = $_[0]->outcome });
        my $n = 0;
        while (await $writer->write($n++)) { }
    })->call({ type => 'http', method => 'GET', 'pagi.connection' => $connection }, sub { Future->new }, $send);
    ok $call->is_done, 'the body returned, and call is done';
    is $outcome, 'disconnected', 'disconnected, though the news has not come';
    is scalar(grep { !$_->{more} && $_->{type} eq 'http.response.body' } @sent), 0, 'and no end was sent';
    $connection->_deliver_notifications;
};

subtest 'the client leaves while the start is still being sent: disconnected, no end' => sub {
    my $outcome;
    my ($call, $sent, $connection) = call_recorded(PAGI::Response::Stream->new(body => async sub {
        my ($writer) = @_;
        $writer->on_close(sub { $outcome = $_[0]->outcome });
        await $writer->write('a');
    }));
    is sent_kinds($sent), ['start'], 'the start, still pending';
    $connection->_mark_disconnected('client_closed');
    ok $call->is_done, 'call is done, not failed';
    is $outcome, 'disconnected', 'disconnected';
    is sent_kinds($sent), ['start'], 'and nothing more is sent: no end for a client that left';
};

subtest 'a body that writes nothing: one start, one end, no length, finished' => sub {
    my $outcome;
    my ($call, $sent) = call_recorded(PAGI::Response::Stream->new(body => async sub {
        $_[0]->on_close(sub { $outcome = $_[0]->outcome });
    }));
    $sent->[0]{future}->done;
    $sent->[1]{future}->done;
    is sent_kinds($sent), ['start', 'end'], 'a start, then the end';
    ok !(grep { $_->[0] eq 'content-length' } @{ $sent->[0]{event}{headers} }), 'no Content-Length';
    is $outcome, 'finished', 'finished';
    ok $call->is_done, 'call is done';
};

subtest 'HEAD: the body runs, and the client gets the headers and no body' => sub {
    my ($ran, $outcome);
    my $res = PAGI::Test::Client->new(app => PAGI::Response::Stream->new(content_type => 'text/plain', body => async sub {
        my ($writer) = @_;
        $writer->on_close(sub { $outcome = $_[0]->outcome });
        $ran = 1;
        await $writer->write('abc');
    }))->head('/');
    ok $ran, 'the body ran';
    is [$res->status, $res->content, $res->header('content-type')], [200, '', 'text/plain'], 'the headers, no body';
    is $outcome, 'finished', 'finished';
};

subtest 'a client that left before call: the body never runs, nothing is sent' => sub {
    my $ran = 0;
    my $response = PAGI::Response::Stream->new(body => async sub { $ran++; await $_[0]->write('a') });
    my $stream = PAGI::Test::Client->new(app => async sub {
        my ($scope, $receive, $send) = @_;
        await $scope->{'pagi.connection'}->disconnect_future;   # the client leaves first
        await $response->call($scope, $receive, $send);
    })->stream('/');
    $stream->close;
    is $ran, 0, 'the body never ran';
    is $stream->response, undef, 'nothing was sent';
};

subtest 'the body dies: call fails with its error, no end' => sub {
    my $outcome;
    my $res = get(PAGI::Response::Stream->new(body => async sub {
        $_[0]->on_close(sub { $outcome = $_[0]->outcome });
        die "broke\n";
    }));
    is [$res->status, $res->exception], [500, "broke\n"], 'before any write: no start went, so the 500 can';
    is $outcome, 'failed', 'outcome: failed';

    # stream, not get: get answers any failure before the end with its 500.
    $res = PAGI::Test::Client->new(app => PAGI::Response::Stream->new(body => async sub {
        await $_[0]->write('a');
        die "broke\n";
    }))->stream('/')->response;
    is [$res->status, $res->content], [200, 'a'], 'after a write: what was sent';
    ok !$res->body_complete, 'and no end';
    is $res->exception, "broke\n", 'the error unchanged';
};

subtest 'on_close: once, in order, each awaited; one that dies warns, and the rest run' => sub {
    my @ran;
    my $later = Future->new;
    my ($call, $sent) = call_recorded(PAGI::Response::Stream->new(body => async sub {
        my ($writer) = @_;
        $writer->on_close(async sub { push @ran, 'first: ' . $_[0]->outcome; await $later; push @ran, 'first done' });
        $writer->on_close(sub { die "cleanup broke\n" });
        $writer->on_close(sub { push @ran, 'third' });
        is $writer->outcome, undef, 'no outcome while the body runs';
    }));
    $sent->[0]{future}->done;              # the start
    my $warnings = warnings {
        $sent->[1]{future}->done;          # the end
        is \@ran, ['first: finished'], 'the first runs once the end has gone, with the outcome set';
        ok !$call->is_ready, 'and call waits for it';
        $later->done;
    };
    is \@ran, ['first: finished', 'first done', 'third'], 'then the rest, in order';
    like $warnings, [qr/\Aon_close callback died: cleanup broke/], 'the one that died is warned about';
    ok $call->is_done, 'then call is done';
};

subtest 'two clients follow one feed; one leaves, the other keeps receiving' => sub {
    my @waiting;                       # each follower's own wait for the next message
    my $feed = PAGI::Response::Stream->new(body => async sub {
        my ($writer) = @_;
        await $writer->write("hello\n");
        while (1) {
            push @waiting, my $next = Future->new;
            await $writer->write(await($next) . "\n");
        }
    });
    my $client = PAGI::Test::Client->new(app => $feed);
    my ($one, $two) = map { $client->stream('/') } 1 .. 2;
    is [map { $_->receive_chunk } $one, $two], ["hello\n", "hello\n"], 'each has the greeting';
    my $publish = sub { my ($message) = @_; $_->done($message) for grep { !$_->is_ready } splice @waiting };
    $publish->('hi');
    is [map { $_->receive_chunk } $one, $two], ["hi\n", "hi\n"], 'each gets the message';
    $one->close;
    $publish->('again');
    is $two->receive_chunk, "again\n", 'the one left keeps receiving';
    $two->close;
};

done_testing;
