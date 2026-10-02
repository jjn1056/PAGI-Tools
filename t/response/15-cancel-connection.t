use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use Scalar::Util qw(weaken);
use PAGI::Response qw(response);
use PAGI::Test::ConnectionState;

for my $stage (qw(start body terminal cleanup)) {
    subtest "caller cancellation during $stage owns abort without cancelling server sends" => sub {
        my $pending = Future->new;
        my $cleanup = Future->new;
        my ($aborts, $produced, $cleaned) = (0, 0, 0);
        my ($writer, $producer, $weak_writer, $weak_producer);
        my @events;
        my $conn = PAGI::Test::ConnectionState->new(on_abort => sub {
            ++$aborts;
            $pending->done unless $pending->is_ready;
        });
        my $response = response('Stream', sub {
            ($writer) = @_;
            $weak_writer = $writer; weaken($weak_writer);
            ++$produced;
            $writer->on_close(sub { ++$cleaned; $cleanup });
            if ($stage eq 'body') {
                $producer = (async sub { await $writer->write('hello'); await Future->new })->();
                $weak_producer = $producer; weaken($weak_producer);
                return $producer;
            }
            return;
        });
        my $observer = $response->_emit({type => 'http', 'pagi.connection' => $conn}, sub { die 'receive consumed' }, sub {
            my ($e) = @_;
            push @events, $e->{type};
            return $pending if ($stage eq 'start' && $e->{type} eq 'http.response.start')
                || ($stage eq 'body' && $e->{more})
                || ($stage eq 'terminal' && $e->{type} eq 'http.response.body' && !$e->{more});
            return Future->done;
        });
        ok(!$observer->is_ready, 'operation parked at stage');
        $observer->cancel;
        is($aborts, 1, 'one public connection abort');
        is($conn->disconnect_detail, 'response cancelled by caller', 'abort diagnostic');
        ok(!$pending->is_cancelled, 'server-owned send never cancelled');
        if ($stage eq 'start') {
            is($produced, 0, 'synchronous abort settlement does not start producer');
            is($cleaned, 0, 'no producer resources acquired');
        } else {
            is($cleaned, 1, 'resource cleanup starts once');
            is($writer->disconnect_detail, 'response cancelled by caller', 'Writer sees callback detail');
            ok(!$cleanup->is_cancelled, 'caller cancellation preserves cleanup');
            ok($producer->is_cancelled, 'owned producer cancelled') if $producer;
            undef $writer; undef $producer;
            ok($weak_writer, 'writer retained across pending cleanup');
            $cleanup->done;
            ok(!$weak_writer, 'writer released after cleanup');
            ok(!$weak_producer, 'producer released') if $stage eq 'body';
        }
    };
}
subtest 'Writer refresh preserves detail before deferred callback and clean end is not disconnect' => sub {
    my $conn = PAGI::Test::ConnectionState->new;
    my $writer = PAGI::Response::Writer->_new(connection => $conn, send => sub {Future->done});
    {
        local $conn->{_defer_notifications} = 1;
        $conn->_mark_disconnected('write_error', 'broken pipe');
    }
    is($writer->disconnect_detail, 'broken pipe', 'synchronous detail');
    ok($writer->is_disconnected, 'abnormal terminal fact');
    $conn->_deliver_notifications;
    my $clean = PAGI::Test::ConnectionState->new;
    my $w = PAGI::Response::Writer->_new(connection => $clean, send => sub {Future->done});
    $clean->_mark_complete;
    ok(!$w->is_disconnected, 'clean completion is not abnormal');
    is($w->disconnect_detail, undef, 'clean diagnostic undefined');
};
done_testing;
