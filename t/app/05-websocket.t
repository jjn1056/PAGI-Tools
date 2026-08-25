#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use lib 'lib';

use PAGI::App::WebSocket::Echo;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

# =============================================================================
# Test: PAGI::App::WebSocket::Echo
# =============================================================================

subtest 'App::WebSocket::Echo' => sub {

    subtest 'echoes text messages' => sub {
        my $app = PAGI::App::WebSocket::Echo->new->to_app;

        my @events = (
            { type => 'websocket.receive', text => 'Hello' },
            { type => 'websocket.disconnect', code => 1000 },
        );
        my $event_idx = 0;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'websocket', path => '/' },
                async sub { $events[$event_idx++] },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{type}, 'websocket.accept', 'accepts connection';
        is $sent[1]{type}, 'websocket.send', 'sends echo';
        is $sent[1]{text}, 'Hello', 'echoes correct text';
    };

    subtest 'echoes binary messages' => sub {
        my $app = PAGI::App::WebSocket::Echo->new->to_app;

        my @events = (
            { type => 'websocket.receive', bytes => "\x00\x01\x02" },
            { type => 'websocket.disconnect', code => 1000 },
        );
        my $event_idx = 0;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'websocket', path => '/' },
                async sub { $events[$event_idx++] },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[1]{bytes}, "\x00\x01\x02", 'echoes binary data';
    };

    subtest 'calls on_connect callback' => sub {
        my $connected = 0;
        my $app = PAGI::App::WebSocket::Echo->new(
            on_connect => sub { $connected = 1 },
        )->to_app;

        my @events = (
            { type => 'websocket.disconnect', code => 1000 },
        );
        my $event_idx = 0;

        run_async(async sub {
            await $app->(
                { type => 'websocket', path => '/' },
                async sub { $events[$event_idx++] },
                async sub  {
        my ($event) = @_; },
            );
        });

        ok $connected, 'on_connect called';
    };

    subtest 'calls on_disconnect callback' => sub {
        my ($disconnect_code, $disconnect_reason);
        my $app = PAGI::App::WebSocket::Echo->new(
            on_disconnect => sub  {
        my ($scope, $code, $reason) = @_; $disconnect_code = $code; $disconnect_reason = $reason },
        )->to_app;

        my @events = (
            { type => 'websocket.disconnect', code => 1001, reason => 'client_closed' },
        );
        my $event_idx = 0;

        run_async(async sub {
            await $app->(
                { type => 'websocket', path => '/' },
                async sub { $events[$event_idx++] },
                async sub  {
        my ($event) = @_; },
            );
        });

        is $disconnect_code, 1001, 'on_disconnect called with code';
        is $disconnect_reason, 'client_closed', 'on_disconnect called with reason';
    };
};

done_testing;
