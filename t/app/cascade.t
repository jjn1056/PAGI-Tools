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

done_testing;
