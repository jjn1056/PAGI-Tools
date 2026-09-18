#!/usr/bin/env perl
use strict;
use warnings;

use Future;
use Future::AsyncAwait;
use PAGI::Compose qw(compose);
use PAGI::Pages ();
use PAGI::Response qw(json_response text_response);
use PAGI::Routing qw(sse websocket);
use PAGI::Utils qw(as_app_object);

{
    package ProtocolRefusal::NoticeService;

    sub new {
        my ($class, %args) = @_;
        return bless {label => $args{label}}, $class;
    }

    sub notice_for {
        my ($self, $request) = @_;
        return Future->done($self->{label} . ':' . $request->path);
    }
}

{
    package ProtocolRefusal::Application;

    sub new {
        my ($class) = @_;
        return bless {}, $class;
    }

    sub to_app {
        my ($self) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            my $body = 'Custom application: ' . $scope->{path};
            await $send->({
                type    => 'http.response.start',
                status  => 503,
                headers => [['content-type', 'text/plain; charset=utf-8']],
            });
            await $send->({
                type => 'http.response.body', body => $body, more => 0,
            });
            return;
        };
    }
}

my $notices = ProtocolRefusal::NoticeService->new(
    label => 'notice-service',
);

sub unavailable_handler {
    return sub {
        my ($request) = @_;
        return json_response(
            {error => 'Unavailable', path => $request->path},
            status => 503,
        );
    };
}

sub async_unavailable_handler {
    my ($service) = @_;
    return async sub {
        my ($request) = @_;
        my $notice = await $service->notice_for($request);
        return json_response(
            {error => 'Unavailable', notice => $notice},
            status => 503,
        );
    };
}

sub unavailable_page {
    return PAGI::Pages->service_unavailable(
        detail => 'Protocol refusal example',
    );
}

my $handler = unavailable_handler();
my $async_handler = async_unavailable_handler($notices);
my $custom = ProtocolRefusal::Application->new;
my $native = as_app_object(async sub {
    my ($scope, $receive, $send) = @_;
    await $send->({
        type    => 'http.response.start',
        status  => 503,
        headers => [['content-type', 'text/plain; charset=utf-8']],
    });
    await $send->({
        type => 'http.response.body', body => 'Scheduled maintenance', more => 0,
    });
    return;
});

compose(routes => [
    websocket('/ws/response' => async sub {
        my ($ws) = @_;
        await $ws->deny(text_response('Scheduled maintenance', status => 503));
        return;
    }),
    sse('/events/response' => async sub {
        my ($sse) = @_;
        await $sse->decline(json_response(
            {error => 'Unavailable', form => 'response'},
            status => 503,
        ));
        return;
    }),

    websocket('/ws/handler' => async sub {
        my ($ws) = @_;
        await $ws->deny($handler);
        return;
    }),
    sse('/events/handler' => async sub {
        my ($sse) = @_;
        await $sse->decline($handler);
        return;
    }),

    websocket('/ws/async-handler' => async sub {
        my ($ws) = @_;
        await $ws->deny($async_handler);
        return;
    }),
    sse('/events/async-handler' => async sub {
        my ($sse) = @_;
        await $sse->decline($async_handler);
        return;
    }),

    websocket('/ws/pages' => async sub {
        my ($ws) = @_;
        await $ws->deny(unavailable_page());
        return;
    }),
    sse('/events/pages' => async sub {
        my ($sse) = @_;
        await $sse->decline(sub { return unavailable_page() });
        return;
    }),

    websocket('/ws/object' => async sub {
        my ($ws) = @_;
        await $ws->deny($custom);
        return;
    }),
    sse('/events/object' => async sub {
        my ($sse) = @_;
        await $sse->decline($custom);
        return;
    }),

    websocket('/ws/native' => async sub {
        my ($ws) = @_;
        await $ws->deny($native);
        return;
    }),
    sse('/events/native' => async sub {
        my ($sse) = @_;
        await $sse->decline($native);
        return;
    }),
]);
