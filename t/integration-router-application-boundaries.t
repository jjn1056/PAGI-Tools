use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use Future;
use Future::AsyncAwait;
use PAGI::Response ();
use PAGI::Response::Text ();
use PAGI::Compose qw(compose);
use PAGI::Routing qw(router route mount middleware);
use PAGI::Utils qw(request_response);

sub run_http {
    my ($app, $path) = @_;
    my @events;
    my $scope = {
        type         => 'http',
        http_version => '1.1',
        method       => 'GET',
        scheme       => 'http',
        path         => $path,
        raw_path     => $path,
        root_path    => '',
        query_string => '',
        headers      => [],
        server       => ['testserver', 80],
        client       => ['127.0.0.1', 50000],
    };
    my $receive = sub {
        return Future->done({
            type => 'http.request', body => '', more => 0,
        });
    };
    my $send = sub {
        my ($event) = @_;
        push @events, $event;
        return Future->done;
    };

    Future->wrap($app->($scope, $receive, $send))->get;
    return \@events;
}

sub response_body {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
}

{
    package Local::MountedIntegrationApp;

    sub new { return bless { compilations => 0 }, $_[0] }
    sub compilations { $_[0]{compilations} }
    sub to_app {
        my ($self) = @_;
        ++$self->{compilations};
        return async sub {
            my ($scope, $receive, $send) = @_;
            await $send->({
                type => 'http.response.start', status => 200,
                headers => [['x-child-path', $scope->{path}]],
            });
            await $send->({
                type => 'http.response.body', body => 'mounted integration', more => 0,
            });
        };
    }
}

local $ENV{PAGI_ENV} = 'production';

subtest 'background-task example remains a composable routing object during response migration' => sub {
    my $file = "$Bin/../examples/background-tasks/app.pl";
    my $app = do $file;
    my $load_error = $@;
    ok(!$load_error, 'background-task example loads cleanly')
        or diag($load_error);
    isa_ok($app, 'PAGI::Compose');
};

subtest 'a mounted object is one compiled application boundary' => sub {
    my $component = Local::MountedIntegrationApp->new;
    my $middleware_builds = 0;
    my $mount_middleware = middleware(sub {
        my ($inner) = @_;
        ++$middleware_builds;
        return $inner;
    });
    my $app = router(routes => [
        mount('/service', app => $component,
            middleware => [$mount_middleware]),
        route('/service/item' => sub {
            return PAGI::Response::Text->new('parent resumed');
        }),
    ])->to_app;

    is([$component->compilations, $middleware_builds], [1, 1],
        'the object and Mount middleware compile once at the parent boundary');
    my $events = run_http($app, '/service/item');
    is(response_body($events), 'mounted integration',
        'the selected child application owns completion');
    is($events->[0]{headers}, [['x-child-path', '/item']],
        'the child receives the rewritten remainder');
    run_http($app, '/service/again');
    is([$component->compilations, $middleware_builds], [1, 1],
        'requests do not recompile the child or Mount middleware');
};

subtest 'request_response is the explicit bridge at application-native positions' => sub {
    my $handler = sub { return PAGI::Response::Text->new('bridged') };
    my @cases = (
        ['Router http_default', router(routes => [], http_default => request_response($handler))->to_app],
        ['Mount app', router(routes => [mount('/bridge', app => request_response($handler))])->to_app, '/bridge'],
        ['Compose app', compose(app => request_response($handler))->to_app],
    );
    for my $case (@cases) {
        my ($label, $app, $path) = @$case;
        is(response_body(run_http($app, $path // '/')), 'bridged',
            "$label accepts the explicit Request handler adapter");
    }
};

done_testing;
