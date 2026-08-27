use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use Future;
use Future::AsyncAwait;
use PAGI::Routing qw(router route mount middleware);

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
    package Local::FullDemoLoader;
    sub load { return do $_[1] }
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

subtest 'full-demo keeps its routes and gains a complete application boundary' => sub {
    my $file = "$Bin/../examples/full-demo/app.pl";
    my $app = Local::FullDemoLoader->load($file);
    my $load_error = $@ || $!;
    ok(!$load_error, 'full-demo loads cleanly') or diag($load_error);
    is(ref($app), 'CODE', 'full-demo returns a native PAGI coderef');

    return unless ref($app) eq 'CODE';

    my $known = run_http($app, '/');
    is($known->[0]{status}, 200, 'known full-demo route still succeeds');
    is(response_body($known), 'Hello, World!',
        'known route keeps its raw response body');

    my $missing = run_http($app, '/not-a-route');
    is([map { $_->{type} } @$missing],
        ['http.response.start', 'http.response.body'],
        'unknown full-demo route completes the HTTP response event family');
    is($missing->[0]{status}, 404,
        'unknown full-demo route receives the Compose application-boundary 404');
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
            return $_[0]->text('parent resumed');
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

done_testing;
