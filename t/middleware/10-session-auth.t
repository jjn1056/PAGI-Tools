#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;
use IO::Async::Loop;

use PAGI::Middleware::Cookie;
use PAGI::Middleware::Session;

my $loop = IO::Async::Loop->new;

sub make_scope {
    my (%opts) = @_;
    return { type => 'http', method => 'GET', path => '/',
        headers => $opts{headers} // [] };
}

sub run_async (&) { my ($code) = @_; $loop->await($code->()) }

subtest 'Cookie middleware - parses cookies' => sub {
    my $captured;
    my $app = PAGI::Middleware::Cookie->new->wrap(async sub { $captured = $_[0] });
    run_async { $app->(make_scope(headers => [['cookie', 'session=abc123; user=john']]),
        async sub { {} }, async sub { }) };
    ok exists $captured->{'pagi.cookies'}, 'has cookies in scope';
    is $captured->{'pagi.cookies'}{session}, 'abc123', 'session cookie parsed';
    is $captured->{'pagi.cookies'}{user}, 'john', 'user cookie parsed';
};

subtest 'Cookie middleware - cookie jar sets response cookies' => sub {
    my $app = PAGI::Middleware::Cookie->new->wrap(async sub {
        my ($scope, $receive, $send) = @_;
        $scope->{'pagi.cookie_jar'}->set('token', 'xyz789', httponly => 1, secure => 1);
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    });
    my @events;
    run_async { $app->(make_scope(), async sub { {} }, async sub { push @events, $_[0] }) };
    my @set = map { $_->[1] } grep { lc($_->[0]) eq 'set-cookie' } @{$events[0]{headers}};
    ok @set, 'has Set-Cookie header';
    like $set[0], qr/token=xyz789/, 'cookie value set';
    like $set[0], qr/HttpOnly/i, 'HttpOnly flag set';
    like $set[0], qr/Secure/i, 'Secure flag set';
};

subtest 'Session middleware - creates new session' => sub {
    PAGI::Middleware::Session->clear_sessions;
    my $captured;
    my $app = PAGI::Middleware::Session->new(secret => 'test-secret')->wrap(async sub {
        my ($scope, $receive, $send) = @_;
        $captured = $scope;
        $scope->{'pagi.session'}{user_id} = 42;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
    });
    my @events;
    run_async { $app->(make_scope(), async sub { {} }, async sub { push @events, $_[0] }) };
    ok exists $captured->{'pagi.session'}, 'has session in scope';
    ok exists $captured->{'pagi.session_id'}, 'has session_id';
    like $captured->{'pagi.session_id'}, qr/\A[0-9a-f]{64}\z/, 'session ID is SHA256 hash';
    ok scalar(grep { lc($_->[0]) eq 'set-cookie' } @{$events[0]{headers}}),
        'has Set-Cookie header for new session';
};

subtest 'Session middleware - restores existing session' => sub {
    PAGI::Middleware::Session->clear_sessions;
    my $session = PAGI::Middleware::Session->new(secret => 'test-secret');
    my $session_id;
    my $first = $session->wrap(async sub {
        my ($scope, $receive, $send) = @_;
        $session_id = $scope->{'pagi.session_id'};
        $scope->{'pagi.session'}{counter} = 1;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => '', more => 0 });
    });
    run_async { $first->(make_scope(), async sub { {} }, async sub { }) };
    my $restored;
    my $second = $session->wrap(async sub { $restored = $_[0]{'pagi.session'} });
    run_async { $second->(make_scope(headers => [['cookie', "pagi_session=$session_id"]]), async sub { {} }, async sub { }) };
    is $restored->{counter}, 1, 'session data restored';
};

for my $case (['default', undef, qr/SameSite=Lax/], ['custom', 'Strict', qr/SameSite=Strict/]) {
    my ($name, $samesite, $expected) = @$case;
    subtest "Session middleware - $name SameSite cookie" => sub {
        PAGI::Middleware::Session->clear_sessions;
        my %options = $samesite
            ? (cookie_options => { httponly => 1, path => '/', samesite => $samesite }) : ();
        my $app = PAGI::Middleware::Session->new(secret => 'test-secret', %options)->wrap(async sub {
            my ($scope, $receive, $send) = @_;
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        });
        my @events;
        run_async { $app->(make_scope(), async sub { {} }, async sub { push @events, $_[0] }) };
        my ($set) = map { $_->[1] } grep { lc($_->[0]) eq 'set-cookie' } @{$events[0]{headers}};
        like $set, $expected, "$name SameSite value is used";
    };
}

done_testing;
