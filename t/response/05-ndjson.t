use strict;
use warnings;
use utf8;

use Future;
use Future::AsyncAwait;
use JSON::MaybeXS ();
use Scalar::Util qw(refaddr);
use Test2::V0;

use PAGI::Response ();
use PAGI::Response::NDJSON ();
use PAGI::Response::NDJSON::Writer ();
use PAGI::Test::ConnectionState;

{
    package T::AuditExport;
    use parent 'PAGI::Response::NDJSON';
}

{
    package T::ResponseAllImport;
    PAGI::Response->import(':all');
}

{
    package T::NDJSONConcreteImport;
    use PAGI::Response::NDJSON qw(ndjson_response);
}

{
    package T::NDJSONTransport;

    sub new {
        return bless {
            buffered => 12,
            high     => 10,
            low      => 3,
            high_cb  => undef,
            drain_cb => undef,
        }, shift;
    }
    sub buffered_amount { return $_[0]{buffered} }
    sub high_water_mark { return $_[0]{high} }
    sub low_water_mark { return $_[0]{low} }
    sub on_high_water { $_[0]{high_cb} = $_[1]; return $_[0] }
    sub on_drain { $_[0]{drain_cb} = $_[1]; return $_[0] }
}

{
    package T::NDJSONDelegate;

    sub new {
        my ($class, %args) = @_;
        return bless {
            write_future => $args{write_future},
            bytes        => $args{bytes} // 0,
            buffered     => $args{buffered} // 0,
            high          => $args{high},
            low           => $args{low},
            writable      => $args{writable} // 1,
            disconnected  => $args{disconnected},
            reason        => $args{reason},
        }, $class;
    }
    sub write { $_[0]{written} = $_[1]; return $_[0]{write_future} }
    sub on_close { $_[0]{close_cb} = $_[1]; return $_[0] }
    sub is_closed { return 0 }
    sub is_disconnected { return $_[0]{disconnected} }
    sub disconnect_reason { return $_[0]{reason} }
    sub bytes_written { return $_[0]{bytes} }
    sub buffered_amount { return $_[0]{buffered} }
    sub high_water_mark { return $_[0]{high} }
    sub low_water_mark { return $_[0]{low} }
    sub is_writable { return $_[0]{writable} }
    sub on_high_water { $_[0]{high_cb} = $_[1]; return $_[0] }
    sub on_drain { $_[0]{drain_cb} = $_[1]; return $_[0] }
}

sub http_scope {
    my (%changes) = @_;
    return {
        type    => 'http',
        method  => 'GET',
        headers => [],
        %changes,
    };
}

sub receive {
    return sub { Future->done({ type => 'http.request', body => '', more => 0 }) };
}

sub terminal_events {
    my ($events) = @_;
    return [grep {
        ($_->{type} // '') eq 'http.response.body' && !($_->{more} // 0)
    } @$events];
}

PAGI::Response->import('ndjson_response');
my $factory = __PACKAGE__->can('ndjson_response');
isa_ok($factory->(sub { }), 'PAGI::Response::NDJSON');
is(PAGI::Response::NDJSON->new(sub { })->protocol_response_capability,
    'body-events-v1');
ok(T::ResponseAllImport->can('ndjson_response'),
    ':all imports the NDJSON response factory');

subtest 'the concrete NDJSON module exports its factory and retains content-type overrides' => sub {
    my $concrete_factory = T::NDJSONConcreteImport->can('ndjson_response');
    ok($concrete_factory, 'concrete module imports its NDJSON response factory into the caller package');
    my $response = $concrete_factory->(
        sub { },
        content_type => 'application/vnd.pagi.audit+ndjson',
    );
    isa_ok($response, 'PAGI::Response::NDJSON');
    is($response->content_type, 'application/vnd.pagi.audit+ndjson',
        'explicit content type overrides the NDJSON default');

    my @events;
    $response->to_app->(
        http_scope(), receive(), sub { push @events, $_[0]; Future->done },
    )->get;
    is($events[0]{headers}, array {
        item ['Content-Type' => 'application/vnd.pagi.audit+ndjson'];
        end;
    }, 'response start preserves the explicit content type');
};

subtest 'NDJSON construction writes one JSON record per item' => sub {
    my @events;
    my @writers;
    my $response = ndjson_response(
        async sub {
            my ($writer) = @_;
            push @writers, $writer;
            await $writer->write_item({ id => 1 });
            await $writer->write_item(undef);
            await $writer->write_item("first\nsecond");
        },
        status  => 201,
        headers => ['X-Export' => 1],
    );

    $response->to_app->(
        http_scope(), receive(), sub { push @events, $_[0]; Future->done },
    )->get;

    isa_ok($response, ['PAGI::Response::NDJSON', 'PAGI::Response::Stream']);
    isa_ok($writers[0], 'PAGI::Response::NDJSON::Writer');
    is($events[0]{status}, 201);
    is($events[0]{headers}, array {
        item ['X-Export' => 1];
        item ['Content-Type' => 'application/x-ndjson'];
        end;
    });
    is([map { $_->{body} } grep { $_->{more} } @events], [
        qq|{"id":1}\n|,
        "null\n",
        qq|"first\\nsecond"\n|,
    ]);
    is($events[-1], { type => 'http.response.body', body => '', more => 0 });
};

subtest 'NDJSON records are unflagged UTF-8 bytes with exactly one LF' => sub {
    my @events;
    my @values = (
        { name => 'Ada', active => \1 },
        [1, 'two'],
        "line\r\nbreak",
        4.5,
        \1,
        undef,
        "caf\x{e9}",
    );
    my $response = ndjson_response(async sub {
        my ($writer) = @_;
        for my $value (@values) {
            await $writer->write_item($value);
        }
    });

    $response->to_app->(
        http_scope(), receive(), sub { push @events, $_[0]; Future->done },
    )->get;

    my @records = map { $_->{body} } grep { $_->{more} } @events;
    is(scalar @records, scalar @values, 'every supplied value emits one record');
    my $decoder = JSON::MaybeXS->new(utf8 => 1);
    my @decoded;
    for my $record (@records) {
        ok(!utf8::is_utf8($record), 'record is an unflagged byte scalar');
        is(substr($record, -1), "\n", 'record has one trailing LF');
        my $json = substr($record, 0, -1);
        unlike($json, qr/[\r\n]/, 'JSON payload contains no raw interior CR or LF');
        push @decoded, $decoder->decode($json);
    }
    is($decoded[0]{name}, 'Ada', 'object record is semantically decodable');
    ok($decoded[0]{active}, 'object boolean is semantically decodable');
    is($decoded[1], [1, 'two'], 'array record is semantically decodable');
    is($decoded[2], "line\r\nbreak", 'CR and LF in a string round-trip semantically');
    is($decoded[3], 4.5, 'number record is semantically decodable');
    ok($decoded[4], 'top-level boolean is semantically decodable');
    is($decoded[5], undef, 'undef encodes as JSON null rather than EOF');
    is($decoded[6], "caf\x{e9}", 'non-ASCII text round-trips through UTF-8');
};

subtest 'NDJSON preserves explicit framing and does not create an empty record' => sub {
    my @empty_events;
    ndjson_response(sub { }, headers => ['Content-Length' => 99])->to_app->(
        http_scope(), receive(), sub { push @empty_events, $_[0]; Future->done },
    )->get;

    is($empty_events[0]{headers}, array {
        item ['Content-Length' => 99];
        item ['Content-Type' => 'application/x-ndjson'];
        end;
    }, 'explicit Content-Length is retained without NDJSON computing one');
    is([map { $_->{body} } grep { $_->{more} } @empty_events], [],
        'an empty producer emits no blank NDJSON record');
    is($empty_events[-1], { type => 'http.response.body', body => '', more => 0 },
        'empty producer still receives Stream terminal close');
};

subtest 'NDJSON has a narrow Writer API and retains common construction validation' => sub {
    my $writer;
    ndjson_response(sub { $writer = $_[0]; return })->to_app->(
        http_scope(), receive(), sub { Future->done },
    )->get;

    ok(!$writer->can('write'), 'raw byte write is not exposed');
    ok(!$writer->can('write_text'), 'text write is not exposed');
    ok(!$writer->can('pipe_from'), 'source relaying is not exposed');
    ok(!$writer->can('close'), 'terminal close is not exposed');
    isa_ok(T::AuditExport->new(sub { }), 'T::AuditExport');
    like(dies { PAGI::Response::NDJSON->new('not a producer') }, qr/producer.*coderef/i,
        'producer must be a coderef');
    like(dies { PAGI::Response::NDJSON->new(sub { }, status => 200, status => 201) },
        qr/duplicate/i, 'duplicate common options retain base validation');
    like(dies { PAGI::Response::NDJSON->new(sub { }, headers => ['X-Odd']) },
        qr/(?:even|headers)/i, 'malformed common options retain base validation');
};

subtest 'JSON encoding failure enters the inherited producer failure path' => sub {
    my @events;
    my $cleanup_calls = 0;
    my $response = ndjson_response(sub {
        my ($writer) = @_;
        $writer->on_close(sub { ++$cleanup_calls });
        return $writer->write_item(bless {}, 'T::Unencodable');
    });
    my $running = $response->to_app->(
        http_scope(), receive(), sub { push @events, $_[0]; Future->done },
    );

    like(dies { $running->get }, qr/NDJSON item encoding failed/,
        'unsupported value reports the NDJSON encoding diagnostic');
    is([grep { $_->{more} } @events], [], 'failing item sends no body event');
    is(terminal_events(\@events), [], 'producer failure emits no false terminal success');
    is($cleanup_calls, 1, 'producer failure runs cleanup exactly once');
};

subtest 'NDJSON Writer returns the generic write Future and delegates observations' => sub {
    my $known = Future->new;
    my $delegate = T::NDJSONDelegate->new(
        write_future => $known,
        bytes        => 11,
        buffered     => 12,
        high         => 10,
        low          => 3,
        writable     => 0,
        disconnected => 0,
    );
    my $writer = PAGI::Response::NDJSON::Writer->_new($delegate);
    my ($close, $high, $drain) = (sub { }, sub { }, sub { });

    is(refaddr($writer->write_item({ id => 1 })), refaddr($known),
        'write_item returns the delegate write Future without an adapter');
    is($delegate->{written}, qq|{"id":1}\n|, 'delegate receives UTF-8 JSON plus one LF');
    is($writer->on_close($close), $writer, 'on_close returns the NDJSON Writer');
    is($delegate->{close_cb}, $close, 'on_close delegates callback identity');
    is($writer->is_closed, 0, 'is_closed delegates');
    is($writer->is_disconnected, 0, 'is_disconnected delegates');
    is($writer->disconnect_reason, undef, 'disconnect_reason delegates');
    is($writer->bytes_written, 11, 'bytes_written delegates encoded accepted bytes');
    is($writer->buffered_amount, 12, 'buffered_amount delegates');
    is($writer->high_water_mark, 10, 'high watermark delegates');
    is($writer->low_water_mark, 3, 'low watermark delegates');
    ok(!$writer->is_writable, 'writability delegates');
    is($writer->on_high_water($high), $writer, 'on_high_water returns the NDJSON Writer');
    is($writer->on_drain($drain), $writer, 'on_drain returns the NDJSON Writer');
    is($delegate->{high_cb}, $high, 'high-water callback delegates by identity');
    is($delegate->{drain_cb}, $drain, 'drain callback delegates by identity');

    my $neutral = PAGI::Response::NDJSON::Writer->_new(
        T::NDJSONDelegate->new(write_future => Future->done, disconnected => undef),
    );
    is($neutral->is_disconnected, undef, 'missing connection retains neutral disconnect state');
    is($neutral->buffered_amount, 0, 'missing transport retains neutral buffer amount');
    is($neutral->high_water_mark, undef, 'missing transport retains neutral high watermark');
    is($neutral->low_water_mark, undef, 'missing transport retains neutral low watermark');
    ok($neutral->is_writable, 'missing transport retains neutral writability');
};

subtest 'write_item inherits real send backpressure and encoded byte accounting' => sub {
    my @events;
    my $body_send = Future->new;
    my ($writer, $write);
    my $response = ndjson_response(sub {
        ($writer) = @_;
        $write = $writer->write_item({ id => 1 });
        return $write;
    });
    my $running = $response->to_app->(
        http_scope(), receive(), sub {
            push @events, $_[0];
            return Future->done if $_[0]{type} eq 'http.response.start';
            return $body_send if $_[0]{more};
            return Future->done;
        },
    );

    ok(!$write->is_ready, 'write_item remains pending while the body send is pending');
    ok(!$running->is_ready, 'Stream remains pending at the same backpressure boundary');
    like(dies { $writer->write_item({ id => 2 }) }, qr/outstanding|await.*write/i,
        'a second record cannot bypass the pending write');
    $body_send->done;
    $write->get;
    $running->get;
    is($writer->bytes_written, length(qq|{"id":1}\n|),
        'accepted encoded bytes include the record LF');
};

subtest 'an unchanged NDJSON Response creates independent Writers per invocation' => sub {
    my @writers;
    my @gates;
    my $calls = 0;
    my $response = ndjson_response(sub {
        my ($writer) = @_;
        ++$calls;
        push @writers, $writer;
        my $gate = Future->new;
        push @gates, $gate;
        return $gate;
    });
    my (@one, @two);
    my $first = $response->to_app->(http_scope(), receive(), sub { push @one, $_[0]; Future->done });
    my $second = $response->to_app->(http_scope(), receive(), sub { push @two, $_[0]; Future->done });

    is($calls, 2, 'concurrent invocations call the producer independently');
    isnt($writers[0], $writers[1], 'concurrent invocations receive distinct specialized Writers');
    $gates[0]->done;
    $gates[1]->done;
    $first->get;
    $second->get;
    is(scalar @{terminal_events(\@one)}, 1, 'first invocation terminates normally');
    is(scalar @{terminal_events(\@two)}, 1, 'second invocation terminates normally');
};

subtest 'disconnect waits for a server-owned NDJSON send and cleans up once' => sub {
    my $connection = PAGI::Test::ConnectionState->new;
    my $body_send = Future->new;
    my @events;
    my ($writer, $write, $cleanup_calls) = (undef, undef, 0);
    my $response = ndjson_response(sub {
        ($writer) = @_;
        $writer->on_close(sub { ++$cleanup_calls });
        $write = $writer->write_item({ id => 1 });
        return $write;
    });
    my $running = $response->to_app->(
        http_scope('pagi.connection' => $connection), receive(), sub {
            push @events, $_[0];
            return Future->done if $_[0]{type} eq 'http.response.start';
            return $body_send if $_[0]{more};
            return Future->done;
        },
    );

    $connection->_mark_disconnected('client_gone');
    ok(!$running->is_ready, 'disconnect waits for the server-owned send Future');
    is($cleanup_calls, 0, 'cleanup cannot outrun the pending server send');
    $body_send->done;
    $running->get;
    is($writer->bytes_written, 0, 'discarded NDJSON bytes are not counted');
    is(terminal_events(\@events), [], 'disconnect sends no terminal success');
    is($cleanup_calls, 1, 'disconnect runs cleanup once');
};

subtest 'failure and caller cancellation retain Stream lifecycle behavior' => sub {
    my @sync_events;
    my $sync_cleanup = 0;
    my $sync = ndjson_response(sub {
        $_[0]->on_close(sub { ++$sync_cleanup });
        die "synchronous producer failure\n";
    })->to_app->(http_scope(), receive(), sub { push @sync_events, $_[0]; Future->done });
    like(dies { $sync->get }, qr/synchronous producer failure/,
        'synchronous producer failure propagates after start');
    is($sync_cleanup, 1, 'synchronous failure cleans up once');
    is(terminal_events(\@sync_events), [], 'synchronous failure sends no terminal success');

    my @future_events;
    my $failed = Future->fail("Future producer failure\n");
    my $future = ndjson_response(sub { return $failed })->to_app->(
        http_scope(), receive(), sub { push @future_events, $_[0]; Future->done },
    );
    like(dies { $future->get }, qr/Future producer failure/,
        'producer Future failure propagates after start');
    is(terminal_events(\@future_events), [], 'Future failure sends no terminal success');

    my $body_send = Future->new;
    my @cancel_events;
    my $cancel_cleanup = 0;
    my $cancelled = ndjson_response(sub {
        my ($writer) = @_;
        $writer->on_close(sub { ++$cancel_cleanup });
        return $writer->write_item({ pending => 1 });
    })->to_app->(
        http_scope(), receive(), sub {
            push @cancel_events, $_[0];
            return Future->done if $_[0]{type} eq 'http.response.start';
            return $body_send;
        },
    );
    $cancelled->cancel;
    ok($cancelled->is_cancelled, 'caller sees its cancellation observer settle');
    is($cancel_cleanup, 0, 'caller cancellation still waits for the server send');
    $body_send->done;
    is($cancel_cleanup, 1, 'caller cancellation cleans up once after send settlement');
    is(terminal_events(\@cancel_events), [], 'caller cancellation sends no terminal success');
};

done_testing;
