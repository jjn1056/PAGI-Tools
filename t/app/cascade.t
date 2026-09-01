#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';

use PAGI::App::Cascade;

subtest 'a child whose client disconnected is not an application error' => sub {
    {
        package AbortedConn5;
        sub new               { return bless {}, shift }
        sub is_connected      { return 0 }
        sub disconnect_reason { return 'client_closed' }
        sub on_disconnect     { return }
    }

    my $scope = { type => 'http', method => 'GET', path => '/x', headers => [],
                  'pagi.connection' => AbortedConn5->new };
    my $send = sub { return Future->done };

    my $child = sub {
        my ($app_scope, $receive, $inner_send) = @_;
        return (async sub {
            await $inner_send->({ type => 'http.response.start',
                                  status => 200, headers => [] });
            await $inner_send->({ type => 'http.response.body',
                                  body => 'partial', more => 1 });
            return;
        })->();
    };

    my $cascade = PAGI::App::Cascade->new(apps => [$child]);
    ok(lives {
        Future->wrap($cascade->to_app->($scope, sub { Future->done }, $send))->get;
    }, 'an incomplete response from a disconnected client does not raise')
        or note($@);
};

subtest 'the carve-out is limited to abnormal ends' => sub {
    {
        package LiveConn5;
        sub new               { return bless {}, shift }
        sub is_connected      { return 1 }
        sub disconnect_reason { return undef }
        sub on_disconnect     { return }
    }

    my $child = sub {
        my ($app_scope, $receive, $inner_send) = @_;
        return (async sub {
            await $inner_send->({ type => 'http.response.start',
                                  status => 200, headers => [] });
            await $inner_send->({ type => 'http.response.body',
                                  body => 'partial', more => 1 });
            return;
        })->();
    };
    my $send = sub { return Future->done };

    # A connected client, and a scope with no connection at all -- the
    # commonest shape -- must both still be reported.
    for my $case (['a connected client', LiveConn5->new],
                  ['no connection object', undef]) {
        my ($label, $conn) = @$case;
        my $scope = { type => 'http', method => 'GET', path => '/x',
                      headers => [] };
        $scope->{'pagi.connection'} = $conn if defined $conn;

        my $cascade = PAGI::App::Cascade->new(apps => [$child]);
        my $error;
        eval {
            Future->wrap($cascade->to_app->($scope, sub { Future->done },
                $send))->get;
            1;
        } or $error = $@;

        ok($error, "$label: an incomplete response is still reported");
        like("$error", qr/without a terminal body/,
            "$label: and it is the incomplete-response error");
    }
};

subtest 'a disconnected client is not an application error before start either' => sub {
    # PAGI::Spec::Www, "Application Produced No Response": "If the client has
    # already disconnected, this is not an application error: the server MUST
    # NOT synthesize a 500 and MUST NOT log an error."
    #
    # Cascade already exempts the after_start raise. The before_start raise
    # fifteen lines below it in the same function was left unguarded, so the
    # same situation produced opposite answers from Cascade and from
    # PAGI::Compose::ResponseGuard, which exempts both.
    {
        package AbortedConnB;
        sub new               { return bless {}, shift }
        sub is_connected      { return 0 }
        sub disconnect_reason { return 'client_closed' }
        sub on_disconnect     { return }
    }

    my $scope = { type => 'http', method => 'GET', path => '/x', headers => [],
                  'pagi.connection' => AbortedConnB->new };
    my $send = sub { return Future->done };

    # A child that produces nothing at all, because its client vanished.
    my $child = sub {
        my ($app_scope, $receive, $inner_send) = @_;
        return Future->done;
    };

    my $cascade = PAGI::App::Cascade->new(apps => [$child]);
    ok(lives {
        Future->wrap($cascade->to_app->($scope, sub { Future->done }, $send))->get;
    }, 'no raise when the client had already gone before any response started')
        or note($@);
};

subtest 'silence still throws when the client is connected' => sub {
    # The carve-out above must stay scoped to abnormal ends -- Cascade's
    # documented contract is that silence throws.
    {
        package LiveConnB;
        sub new               { return bless {}, shift }
        sub is_connected      { return 1 }
        sub disconnect_reason { return undef }
        sub on_disconnect     { return }
    }

    my $send = sub { return Future->done };
    my $child = sub { return Future->done };

    for my $case (['a connected client', LiveConnB->new],
                  ['no connection object', undef]) {
        my ($label, $conn) = @$case;
        my $scope = { type => 'http', method => 'GET', path => '/x',
                      headers => [] };
        $scope->{'pagi.connection'} = $conn if defined $conn;

        my $cascade = PAGI::App::Cascade->new(apps => [$child]);
        my $error;
        eval {
            Future->wrap($cascade->to_app->($scope, sub { Future->done },
                $send))->get;
            1;
        } or $error = $@;

        ok($error, "$label: silence is still reported");
        like("$error", qr/without starting a response/,
            "$label: and it is the before_start error");
    }
};

done_testing;
