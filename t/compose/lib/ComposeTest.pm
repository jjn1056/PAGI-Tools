package ComposeTest;

use strict;
use warnings;
use Exporter 'import';
use Future;

our @EXPORT_OK = qw(scope capture_send run_scope channel);

sub scope {
    my (%changes) = @_;
    return {
        type         => 'http',
        method       => 'GET',
        path         => '/',
        root_path    => '',
        query_string => '',
        headers      => [],
        %changes,
    };
}

sub capture_send {
    my @events;
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    return ($send, \@events);
}

sub run_scope {
    my ($app, $request_scope, $messages) = @_;
    $messages ||= [];
    my @queue = @$messages;
    my ($send, $events) = capture_send();
    my $receive = sub {
        return Future->done(shift @queue);
    };
    Future->wrap($app->($request_scope, $receive, $send))->get;
    return $events;
}

sub channel {
    my @queued;
    my @waiters;
    my $receive = sub {
        return Future->done(shift @queued) if @queued;
        my $future = Future->new;
        push @waiters, $future;
        return $future;
    };
    my $push = sub {
        my ($event) = @_;
        if (@waiters) {
            shift(@waiters)->done($event);
        }
        else {
            push @queued, $event;
        }
        return;
    };
    return ($receive, $push);
}

1;
