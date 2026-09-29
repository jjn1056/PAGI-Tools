#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use lib 't/lib';
use PAGI::SSE;
use PAGITest::Connected qw(sse_scope);

subtest 'each iterates over arrayref' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    my $sse = PAGI::SSE->new(sse_scope(), sub {}, $send);
    $sse->start->get;

    my @items = ('one', 'two', 'three');

    $sse->each(\@items, async sub {
        my ($item) = @_;
        await $sse->send($item);
    })->get;

    my @data_sent = map { $_->{data} } grep { $_->{type} eq 'sse.send' } @sent;
    is(\@data_sent, ['one', 'two', 'three'], 'all items sent');
};

subtest 'each with transformer returns event spec' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    my $sse = PAGI::SSE->new(sse_scope(), sub {}, $send);
    $sse->start->get;

    my @items = ({ name => 'Alice' }, { name => 'Bob' });

    $sse->each(\@items, async sub {
        my ($item, $index) = @_;
        return {
            data  => $item,
            event => 'user',
            id    => $index,
        };
    })->get;

    my @events = grep { $_->{type} eq 'sse.send' } @sent;
    is($events[0]{event}, 'user', 'first event type');
    is($events[0]{id}, '0', 'first event id');
    is($events[1]{id}, '1', 'second event id');
};

subtest 'each with coderef iterator' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    my $sse = PAGI::SSE->new(sse_scope(), sub {}, $send);
    $sse->start->get;

    my @items = (1, 2, 3);
    my $idx = 0;
    my $iterator = sub {
        return undef if $idx >= @items;
        return $items[$idx++];
    };

    $sse->each($iterator, async sub {
        my ($item) = @_;
        await $sse->send("item: $item");
    })->get;

    my @data_sent = map { $_->{data} } grep { $_->{type} eq 'sse.send' } @sent;
    is(\@data_sent, ['item: 1', 'item: 2', 'item: 3'], 'coderef iterator works');
};

subtest 'each() re-raises when callback dies; on_close runs when the connection ends' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    my $scope = sse_scope();
    my $sse = PAGI::SSE->new($scope, sub {}, $send);
    $sse->start->get;

    my $cleanup_ran = 0;
    $sse->on_close(async sub { $cleanup_ran = 1 });

    my @items = ('one', 'two', 'three');

    like(
        dies {
            $sse->each(\@items, async sub {
                my ($item) = @_;
                die "boom on $item\n" if $item eq 'two';
                await $sse->send($item);
            })->get;
        },
        qr/boom on two/,
        'exception still propagates'
    );

    ok(!$cleanup_ran, 'on_close waits for the connection to end');

    # The application died; the server ends the connection.
    $scope->{'pagi.connection'}->_mark_disconnected('server_error');
    ok($cleanup_ran, 'on_close ran once the connection ended');

    my @data_sent = map { $_->{data} } grep { $_->{type} eq 'sse.send' } @sent;
    is(\@data_sent, ['one'], 'iteration stopped at the failing item');
};

subtest 'every() re-raises when callback dies; on_close runs when the connection ends' => sub {
    unless (eval { require Future::IO::Impl::IOAsync; 1 }) {
        skip_all('Future::IO::Impl::IOAsync required for every() tests');
    }

    my @sent;
    my $scope = sse_scope();
    my $sse = PAGI::SSE->new(
        $scope,
        sub { Future->new },    # receive: never resolves
        sub { push @sent, $_[0]; Future->done },
    );
    $sse->start->get;

    my $cleanup_ran = 0;
    $sse->on_close(async sub { $cleanup_ran = 1 });

    like(
        dies {
            $sse->every(0.01, async sub { die "boom in every\n" })->get;
        },
        qr/boom in every/,
        'exception now propagates instead of being swallowed'
    );

    ok(!$cleanup_ran, 'on_close waits for the connection to end');

    # The application died; the server ends the connection.
    $scope->{'pagi.connection'}->_mark_disconnected('server_error');
    ok($cleanup_ran, 'on_close ran once the connection ended');
};

subtest 'every() learns of disconnect from the connection, never from receive' => sub {
    unless (eval { require Future::IO::Impl::IOAsync; 1 }) {
        skip_all('Future::IO::Impl::IOAsync required for every() tests');
    }

    # A receive-based disconnect watcher could cancel the live protocol
    # receive; the connection object makes one unnecessary.
    my $receive_called = 0;
    my $scope = sse_scope();
    my $sse = PAGI::SSE->new(
        $scope,
        sub { $receive_called++; return Future->new },
        sub { Future->done },
    );
    $sse->start->get;

    my $ticks = 0;
    $sse->every(0.01, async sub {
        $scope->{'pagi.connection'}->_mark_disconnected('client_closed')
            if ++$ticks >= 2;
    })->get;

    is($ticks, 2, 'every() stopped once the connection ended');
    is($receive_called, 0, 'receive was never read');
};

done_testing;
