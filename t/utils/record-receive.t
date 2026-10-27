#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use PAGI::Utils::Middleware qw(record_receive);
use PAGI::Utils::ReceiveBuffer::TempFile;

# A receive that delivers the given events, then a disconnect for every
# later call, as a server does once the body is complete.
sub client_sending {
    my @events = @_;
    my $calls = 0;
    my $receive = sub {
        $calls++;
        return Future->done(@events ? shift @events : { type => 'http.disconnect' });
    };
    return ($receive, \$calls);
}

sub drain {
    my ($receive, $count) = @_;
    return [map { $receive->()->get } 1 .. $count];
}

my @body = (
    { type => 'http.request', body => 'name=', more => 1 },
    { type => 'http.request', body => 'Ada', more => 0 },
);

subtest 'exported on request only' => sub {
    package NoRecordImport { use PAGI::Utils::Middleware; }
    ok(!NoRecordImport->can('record_receive'), 'not exported by default');
};

subtest 'a body read in full is delivered again, then the live receive continues' => sub {
    my ($receive, $calls) = client_sending(@body);
    my ($reading, $replaying) = record_receive($receive);

    is(drain($reading, 2), \@body, 'the reader sees the body');
    is(drain($replaying, 3), [@body, { type => 'http.disconnect' }],
        'the replay delivers the body again, then what the client sends next');
    is($$calls, 3, 'the client was read once per event');
};

subtest 'a body read in part is delivered in full' => sub {
    my ($receive) = client_sending(@body);
    my ($reading, $replaying) = record_receive($receive);

    is($reading->()->get, $body[0], 'the reader stops after the first event');
    is(drain($replaying, 2), \@body, 'the replay delivers the recorded event, then the live one');
};

subtest 'a body never read passes straight through' => sub {
    my ($receive) = client_sending(@body);
    my (undef, $replaying) = record_receive($receive);
    is(drain($replaying, 2), \@body, 'the replay is the live receive');
};

subtest 'a disconnect in mid-body is delivered again' => sub {
    my ($receive) = client_sending($body[0], { type => 'http.disconnect', reason => 'gone' });
    my ($reading, $replaying) = record_receive($receive);
    drain($reading, 2);
    is(drain($replaying, 2), [$body[0], { type => 'http.disconnect', reason => 'gone' }],
        'the partial body and the disconnect come back in order');
};

subtest 'the reader may not read once the replay has begun' => sub {
    my ($receive) = client_sending(@body);
    my ($reading, $replaying) = record_receive($receive);
    $reading->()->get;
    $replaying->()->get;
    like(dies { $reading->()->get }, qr/record_receive: the recording receive was called after the replay began/,
        'reading after the replay began fails');
};

subtest 'stacked layers hand on the same events' => sub {
    my ($receive) = client_sending(@body);
    my ($outer_reading, $outer_replaying) = record_receive($receive);
    my $read_by_outer = drain($outer_reading, 2);
    my ($inner_reading, $inner_replaying) = record_receive($outer_replaying);
    drain($inner_reading, 2);
    my $delivered = drain($inner_replaying, 2);
    ref_is($delivered->[$_], $read_by_outer->[$_], "event $_ reaches the application as the same hash") for 0, 1;
};

subtest 'a buffer may be given' => sub {
    my ($receive) = client_sending(@body);
    my ($reading, $replaying) = record_receive($receive,
        buffer => PAGI::Utils::ReceiveBuffer::TempFile->new(spool_threshold => 0));
    my $read = drain($reading, 2);
    my $replayed = drain($replaying, 2);
    is($replayed, \@body, 'the replay delivers the body');
    ok($replayed->[0] != $read->[0], 'through the given buffer, which spooled it');
};

subtest 'by default the body is kept in memory, however large' => sub {
    my ($receive) = client_sending({ type => 'http.request', body => 'x' x (1024 * 1024), more => 0 });
    my ($reading, $replaying) = record_receive($receive);
    my $read = $reading->()->get;
    ref_is($replaying->()->get, $read, 'the same event comes back: nothing was spooled');
};

subtest 'a TempFile buffer spools a large body, if given' => sub {
    my ($receive) = client_sending({ type => 'http.request', body => 'x' x (65 * 1024), more => 0 });
    my ($reading, $replaying) = record_receive($receive, buffer => PAGI::Utils::ReceiveBuffer::TempFile->new);
    my $read = $reading->()->get;
    my $replayed = $replaying->()->get;
    is($replayed, $read, 'the body comes back');
    ok($replayed != $read, 'as a copy, from the temp file');
};

# A buffer whose Futures are still pending when returned, as one kept in
# Redis returns them; settle completes what it was asked so far.
package Local::DeferredBuffer {
    sub new { bless { inner => PAGI::Utils::ReceiveBuffer::TempFile->new, pending => [] }, shift }
    sub append {
        my ($self, $event) = @_;
        my $f = Future->new;
        push @{$self->{pending}}, sub { $self->{inner}->append($event)->get; $f->done };
        return $f;
    }
    sub take {
        my ($self) = @_;
        my $f = Future->new;
        push @{$self->{pending}}, sub { $f->done($self->{inner}->take->get) };
        return $f;
    }
    sub settle { my ($self) = @_; (shift @{$self->{pending}})->() while @{$self->{pending}} }
}

subtest 'a buffer whose Futures complete later' => sub {
    my ($receive) = client_sending(@body);
    my $buffer = Local::DeferredBuffer->new;
    my ($reading, $replaying) = record_receive($receive, buffer => $buffer);

    my $read = $reading->();
    ok(!$read->is_ready, 'reading waits until the buffer has kept the event');
    $buffer->settle;
    is($read->get, $body[0], 'then delivers it');

    my $replayed = $replaying->();
    ok(!$replayed->is_ready, 'the replay waits for the buffer');
    $buffer->settle;
    is($replayed->get, $body[0], 'then delivers the kept event');

    my $after = $replaying->();
    $buffer->settle;
    is($after->get, $body[1], 'an empty buffer, once it answers, hands over to the live receive');
};

subtest 'arguments are checked' => sub {
    like(dies { record_receive('not code') }, qr/record_receive receive must be a coderef/, 'receive');
    like(dies { record_receive(sub {}, buffer => {}) },
        qr/record_receive buffer must be an object with append and take/, 'buffer');
    like(dies { record_receive(sub {}, bogus => 1) }, qr/record_receive has unknown option 'bogus'/,
        'unknown option');
};

done_testing;
