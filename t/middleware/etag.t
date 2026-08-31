#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;

use lib 'lib';

use PAGI::Middleware::ETag;
use PAGI::Test::Client;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    return $loop->await($code->());
}

subtest 'buffered response: ETag header generated from the body' => sub {
    my $mw = PAGI::Middleware::ETag->new;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [] });
        await $send->({ type => 'http.response.body', body => 'hello', more => 0 });
    };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/', method => 'GET' },
            async sub { { type => 'http.disconnect' } },
            async sub { my ($event) = @_; push @sent, $event },
        );
    });

    my ($etag) = map { $_->[1] } grep { lc($_->[0]) eq 'etag' } @{$sent[0]{headers}};
    ok $etag, 'an ETag header was added';
    is $sent[1]{body}, 'hello', 'body is unchanged';
};

subtest 'response already carrying an ETag passes through unchanged' => sub {
    my $mw = PAGI::Middleware::ETag->new;
    my $app = async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200, headers => [['etag', '"preset"']] });
        await $send->({ type => 'http.response.body', body => 'hello', more => 0 });
    };
    my $wrapped = $mw->wrap($app);

    my @sent;
    run_async(async sub {
        await $wrapped->(
            { type => 'http', path => '/', method => 'GET' },
            async sub { { type => 'http.disconnect' } },
            async sub { my ($event) = @_; push @sent, $event },
        );
    });

    is $sent[0]{headers}, [['etag', '"preset"']], 'the preset ETag is not replaced';
};

subtest 'A5 buffered: inner app never responds -- ETag emits nothing' => sub {
    my $mw = PAGI::Middleware::ETag->new;
    my $never_responds = async sub { return; };
    my $wrapped = $mw->wrap($never_responds);

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $res = PAGI::Test::Client->new(app => $wrapped)->get('/');

    is $res->status, 500, "the strict client's no-response backstop fires";
    is scalar(@warnings), 1, 'exactly one warning';
    like $warnings[0], qr/incomplete/i, 'the warning documents the incomplete response'
        or diag(@warnings);
};

subtest 'A5 streaming: a body chunk arriving with no prior start invents nothing' => sub {
    my $mw = PAGI::Middleware::ETag->new;
    my $malformed = async sub {
        my ($scope, $receive, $send) = @_;
        # A body chunk sent before any http.response.start -- ETag must not
        # fabricate a start event with an undefined status to carry it.
        await $send->({ type => 'http.response.body', body => 'oops', more => 1 });
        await $send->({ type => 'http.response.body', body => 'still oops', more => 0 });
    };
    my $wrapped = $mw->wrap($malformed);

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $res = PAGI::Test::Client->new(app => $wrapped)->get('/');

    is $res->status, 500, "the strict client's no-response backstop fires";
    is scalar(@warnings), 1, 'exactly one warning';
    like $warnings[0], qr/incomplete/i, 'the warning documents the incomplete response'
        or diag(@warnings);
};

subtest 'a disconnected client gets no fabricated validator' => sub {
    my @sent;
    my $send = sub { push @sent, $_[0]; return Future->done };

    {
        package AbortedConn;
        sub new               { return bless {}, shift }
        sub is_connected      { return 0 }
        sub disconnect_reason { return 'client_closed' }
        sub on_disconnect     { return }
    }

    my $scope = { type => 'http', method => 'GET', path => '/x', headers => [],
                  'pagi.connection' => AbortedConn->new };

    # An application that starts a response and stops -- without sending any
    # body chunk -- because the client vanished before it could send one.
    # (A single more=>1 chunk instead would take ETag's pre-existing
    # streaming-passthrough branch, which never reaches the buggy
    # post-completion synthesis this guard protects.)
    my $app = sub {
        my ($app_scope, $receive, $inner_send) = @_;
        return (async sub {
            await $inner_send->({ type => 'http.response.start',
                                  status => 200, headers => [] });
            return;
        })->();
    };

    my $wrapped = PAGI::Middleware::ETag->new->wrap($app);
    Future->wrap($wrapped->($scope, sub { Future->done }, $send))->get;

    my @etags = map { @{ $_->{headers} || [] } }
                grep { $_->{type} eq 'http.response.start' } @sent;
    is(scalar(grep { lc($_->[0]) eq 'etag' } @etags), 0,
        'no ETag is attached to an aborted response');
    is(scalar(grep { $_->{type} eq 'http.response.body' && !$_->{more} } @sent), 0,
        'no terminal body event is fabricated');
};

done_testing;
