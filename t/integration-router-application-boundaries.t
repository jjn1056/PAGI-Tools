use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use Future;

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
    package Local::BackgroundTasksLoader;
    sub load { return do $_[1] }
}

{
    package Local::FullDemoLoader;
    sub load { return do $_[1] }
}

local $ENV{PAGI_ENV} = 'production';

subtest 'background-tasks deploys its Router as a complete application' => sub {
    my $file = "$Bin/../examples/background-tasks/app.pl";
    my $app = Local::BackgroundTasksLoader->load($file);
    my $load_error = $@ || $!;
    ok(!$load_error, 'background-tasks loads cleanly') or diag($load_error);
    is(ref($app), 'CODE', 'background-tasks returns a native PAGI coderef');

    return unless ref($app) eq 'CODE';

    my $known = run_http($app, '/');
    is($known->[0]{status}, 200, 'known background-tasks route still succeeds');
    like(response_body($known), qr/Background Tasks Demo/,
        'known route keeps its example page');

    my $missing = run_http($app, '/not-a-route');
    is([map { $_->{type} } @$missing],
        ['http.response.start', 'http.response.body'],
        'unknown route completes the HTTP response event family');
    is($missing->[0]{status}, 404,
        'unknown route receives the Compose application-boundary 404');
};

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

done_testing;
