use strict;
use warnings;
use Future;
use Future::AsyncAwait;
use Test2::V0;

use lib 't/lib';
use PAGI::Response qw(response);
use PAGI::Response::Stream;
use PAGI::Response::NDJSON;
use PAGI::Test::ConnectionState;

# A Stream's content may be a source, an object with next_chunk: Stream pulls
# it one value at a time, writing each before the next pull, and calls no
# other method on it. Cleanup is the explicit on_close option.

{
    package Local::Source;
    # Hands out its values one per pull, as Futures (or immediately, with
    # immediate => 1); on_pull runs before each pull.
    sub new {
        my ($class, %args) = @_;
        return bless { values => [ @{ $args{values} } ], pulls => 0, %args }, $class;
    }
    sub next_chunk {
        my ($self) = @_;
        $self->{pulls}++;
        $self->{on_pull}->($self) if $self->{on_pull};
        return Future->fail($self->{fail}) if $self->{fail} && $self->{pulls} == $self->{fail_at};
        my $value = shift @{ $self->{values} };
        return $self->{immediate} ? $value : Future->done($value);
    }
    sub close { $_[0]{closed}++ }    # Stream must never call this
}

# Serves $response once; returns (body events' bodies, the invocation's Future).
sub serve {
    my ($response, %scope) = @_;
    my @events;
    my $f = $response->to_app->(
        { type => 'http', method => 'GET', headers => [], %scope },
        sub { Future->done({ type => 'http.request', body => '', more => 0 }) },
        sub { push @events, $_[0]; Future->done },
    );
    $f->await;
    return ([ map { $_->{body} } grep { $_->{type} eq 'http.response.body' && length($_->{body} // '') } @events ], $f);
}

subtest 'bytes from a source, in order' => sub {
    my ($bodies) = serve(response('Stream', Local::Source->new(values => ['a', 'b', 'c'])));
    is($bodies, ['a', 'b', 'c'], 'each chunk written');
    ($bodies) = serve(response('Stream', Local::Source->new(values => ['a', 'b'], immediate => 1)));
    is($bodies, ['a', 'b'], 'an immediate next_chunk works too');
    ($bodies) = serve(response('Stream', Local::Source->new(values => ['a', '', 'b'])));
    is($bodies, ['a', 'b'], 'an empty chunk is skipped');
    my $source = Local::Source->new(values => ['a', undef, 'never']);
    ($bodies) = serve(response('Stream', $source));
    is($bodies, ['a'], 'undef ends the stream');
    is($source->{pulls}, 2, 'and nothing is pulled after it');
};

subtest 'the next pull waits for the write' => sub {
    my ($pending, @settled_before_pull);
    my $send = sub {
        my ($event) = @_;
        return Future->done unless ($event->{type} eq 'http.response.body' && length($event->{body} // ''));
        return $pending = Future->new;
    };
    my $source = Local::Source->new(values => ['a', 'b'],
        on_pull => sub { push @settled_before_pull, !$pending || $pending->is_ready });
    my $f = response('Stream', $source)->to_app->(
        { type => 'http', method => 'GET', headers => [] },
        sub { Future->done({ type => 'http.request', body => '', more => 0 }) }, $send);
    is($source->{pulls}, 1, 'one pull while the first write is pending');
    # Release each write in turn until the stream ends.
    $pending->done while !$f->is_ready && $pending && !$pending->is_ready;
    $f->await;
    is([ @settled_before_pull ], [ (1) x @settled_before_pull ], 'each pull happened after the previous write settled');
};

subtest 'on_close runs once, however the stream ends' => sub {
    my $closed = 0;
    serve(response('Stream', Local::Source->new(values => ['a']), on_close => sub { $closed++ }));
    is($closed, 1, 'on completion');

    $closed = 0;
    my ($bodies, $f) = serve(response('Stream',
        Local::Source->new(values => ['a', 'b'], fail => "read broke\n", fail_at => 2),
        on_close => sub { $closed++ }));
    is($closed, 1, 'after a failed pull');
    ok($f->is_failed, 'a failed pull is a producer error');

    $closed = 0;
    my $conn = PAGI::Test::ConnectionState->new;
    my $source = Local::Source->new(values => ['a', 'b', 'c'],
        on_pull => sub { $conn->_mark_disconnected('client_closed') if $_[0]{pulls} == 2 });
    ($bodies) = serve(response('Stream', $source, on_close => sub { $closed++ }), 'pagi.connection' => $conn);
    is($source->{pulls}, 2, 'no pull after the client left');
    is($closed, 1, 'on disconnect');

    $closed = 0;
    my $waited = Future->new;
    my $stream = response('Stream', Local::Source->new(values => ['a']), on_close => sub { $closed++; $waited });
    my $served = $stream->to_app->({ type => 'http', method => 'GET', headers => [] },
        sub { Future->done({ type => 'http.request', body => '', more => 0 }) }, sub { Future->done });
    ok(!$served->is_ready, 'a Future from on_close is waited for');
    $waited->done;
    $served->await;
    ok($served->is_done, 'and the response ends after it');
};

subtest 'on_close with a producer' => sub {
    my ($mine, $option) = (0, 0);
    serve(response('Stream', async sub {
        my ($writer) = @_;
        $writer->on_close(sub { $mine++ });
        await $writer->write('x');
    }, on_close => sub { $option++ }));
    is([$mine, $option], [1, 1], "the option and the producer's own both run once");
};

subtest "a source's own close is never called" => sub {
    my $source = Local::Source->new(values => ['a']);
    serve(response('Stream', $source));
    ok(!$source->{closed}, 'not on completion');
    $source = Local::Source->new(values => ['a', 'b'], fail => "x\n", fail_at => 2);
    serve(response('Stream', $source));
    ok(!$source->{closed}, 'not after a failure');
};

subtest 'NDJSON: each value is an item' => sub {
    my ($bodies) = serve(response('NDJSON', Local::Source->new(values => [{ a => 1 }, 0, '', [1, 2]])));
    is(join('', @$bodies), qq({"a":1}\n0\n""\n[1,2]\n), 'objects, 0 and the empty string are items');
};

subtest 'refusals' => sub {
    like(dies { PAGI::Response::Stream->new({}) },
        qr/PAGI::Response::Stream->new requires a producer coderef or a source object with next_chunk/,
        'an unblessed hash');
    like(dies { PAGI::Response::Stream->new(bless {}, 'Nothing') },
        qr/requires a producer coderef or a source object with next_chunk/, 'an object without next_chunk');
    like(dies { response('Stream', sub {}, on_close => 'x') },
        qr/Stream on_close must be a code reference/, 'a non-code on_close');
};

done_testing;
