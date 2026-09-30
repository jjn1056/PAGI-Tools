#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Future;

use lib 'lib';
use lib 't/lib';
use PAGI::SSE;
use PAGI::Stash;
use PAGITest::Connected qw(sse_scope);

subtest 'complete SSE session' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    my $scope = sse_scope(
        path    => '/events',
        headers => [['last-event-id', '5']],
    );

    my $sse = PAGI::SSE->new($scope, sub {}, $send);

    # Check last event ID
    is($sse->last_event_id, '5', 'got last event id');

    # Register cleanup
    my $cleanup_ran = 0;
    $sse->on_close(sub { $cleanup_ran = 1 });

    # Store data in stash
    my $stash = PAGI::Stash->new($sse);
    $stash->set(user_id => 42);
    is($stash->get('user_id'), 42, 'stash works');

    # Start and send events
    $sse->start->get;
    $sse->send_event(data => 'catch-up', id => '6')->get;
    $sse->send_json({ type => 'hello' })->get;

    # Run until disconnect
    my $run = $sse->run;
    $scope->{'pagi.connection'}->_mark_disconnected('client_closed');
    $run->get;

    ok($cleanup_ran, 'cleanup ran');
    ok($sse->is_closed, 'connection closed');

    # Verify sent events
    is($sent[0]{type}, 'sse.start', 'start sent');
    is($sent[1]{id}, '6', 'catch-up event with id');
    like($sent[2]{data}, qr/"type".*"hello"/, 'JSON event sent');
};

subtest 'notification stream pattern' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; Future->done };

    my $scope = sse_scope(path => '/notifications');

    my $sse = PAGI::SSE->new($scope, sub {}, $send);

    # Simulate subscriber registration
    my $subscriber_id;
    my $unsubscribed = 0;

    $sse->on_close(sub {
        $unsubscribed = 1;
    });

    $sse->start->get;

    # Send some notifications
    for my $i (1..3) {
        $sse->send_event(
            event => 'notification',
            data  => { id => $i, message => "Notification $i" },
            id    => $i,
        )->get;
    }

    # Client disconnects
    my $run = $sse->run;
    $scope->{'pagi.connection'}->_mark_disconnected('client_closed');
    $run->get;

    ok($unsubscribed, 'unsubscribe callback ran');

    my @notifications = grep { ($_->{event} // '') eq 'notification' } @sent;
    is(scalar @notifications, 3, 'all 3 notifications sent');
};

done_testing;
