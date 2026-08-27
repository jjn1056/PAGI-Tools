#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use IO::Async::Loop;
use JSON::MaybeXS qw(decode_json);

use lib 'lib';
use FindBin;
use lib "$FindBin::Bin/../lib";

use PAGI::App::URLMap;
use PAGI::App::Cascade;
use PAGI::Pages;

my $loop = IO::Async::Loop->new;

sub run_async {
    my ($code) = @_;
    my $future = $code->();
    $loop->await($future);
}

# Helper app generators
sub make_response_app {
    my ($status, $body) = @_;

    return async sub  {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => $status, headers => [] });
        await $send->({ type => 'http.response.body', body => $body, more => 0 });
    };
}

# =============================================================================
# Test: PAGI::App::URLMap
# =============================================================================

subtest 'App::URLMap routes by path prefix' => sub {

    subtest 'routes to mounted app' => sub {
        my $urlmap = PAGI::App::URLMap->new;
        $urlmap->mount('/api' => make_response_app(200, 'API'));
        $urlmap->mount('/web' => make_response_app(200, 'WEB'));
        my $app = $urlmap->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/api/users' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 200, 'routes to API';
        is $sent[1]{body}, 'API', 'API app responded';
    };

    subtest 'adjusts path for mounted app' => sub {
        my $received_path;
        my $inner = async sub  {
        my ($scope, $receive, $send) = @_;
            $received_path = $scope->{path};
            await $send->({ type => 'http.response.start', status => 200, headers => [] });
            await $send->({ type => 'http.response.body', body => 'OK', more => 0 });
        };

        my $urlmap = PAGI::App::URLMap->new;
        $urlmap->mount('/api' => $inner);
        my $app = $urlmap->to_app;

        run_async(async sub {
            await $app->(
                { type => 'http', path => '/api/users/123' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; },
            );
        });

        is $received_path, '/users/123', 'path adjusted (prefix removed)';
    };

    subtest 'negotiates Pages 404 for unmatched HTTP path' => sub {
        my $urlmap = PAGI::App::URLMap->new;
        $urlmap->mount('/api' => make_response_app(200, 'API'));
        my $app = $urlmap->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                {
                    type    => 'http',
                    path    => '/unknown',
                    headers => [['Accept', 'application/problem+json']],
                },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 404, 'returns 404';
        my %headers = map { lc($_->[0]) => $_->[1] } @{$sent[0]{headers}};
        is $headers{'content-type'}, 'application/problem+json',
            'unmatched HTTP response negotiates through Pages';
        is $headers{'cache-control'}, 'no-store',
            'unmatched HTTP response uses Pages error cache policy';
        is decode_json($sent[1]{body})->{status}, 404,
            'problem document carries the fallback status';
    };

    subtest 'longest prefix wins' => sub {
        my $urlmap = PAGI::App::URLMap->new;
        $urlmap->mount('/api' => make_response_app(200, 'API'));
        $urlmap->mount('/api/v2' => make_response_app(200, 'API-V2'));
        my $app = $urlmap->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/api/v2/users' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[1]{body}, 'API-V2', 'longer prefix matched';
    };
};

# =============================================================================
# Test: PAGI::App::Cascade
# =============================================================================

subtest 'App::Cascade tries apps in sequence' => sub {

    subtest 'returns first non-404 response' => sub {
        my $cascade = PAGI::App::Cascade->new(
            apps => [
                make_response_app(404, 'Not Found'),
                make_response_app(200, 'Found'),
                make_response_app(200, 'Never Reached'),
            ],
        );
        my $app = $cascade->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/test' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 200, 'returns 200';
        is $sent[1]{body}, 'Found', 'correct app responded';
    };

    subtest 'returns 404 if all apps return 404' => sub {
        my $cascade = PAGI::App::Cascade->new(
            apps => [
                make_response_app(404, 'Not Found 1'),
                make_response_app(404, 'Not Found 2'),
            ],
        );
        my $app = $cascade->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/test' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 404, 'returns 404 when all fail';
    };

    subtest 'custom catch codes' => sub {
        my $cascade = PAGI::App::Cascade->new(
            apps => [
                make_response_app(403, 'Forbidden'),
                make_response_app(200, 'Success'),
            ],
            catch => [403, 404],
        );
        my $app = $cascade->to_app;

        my @sent;
        run_async(async sub {
            await $app->(
                { type => 'http', path => '/test' },
                async sub { { type => 'http.disconnect' } },
                async sub  {
        my ($event) = @_; push @sent, $event },
            );
        });

        is $sent[0]{status}, 200, 'catches 403 and tries next';
    };
};

subtest 'URLMap sets spec root_path key (not script_name)' => sub {
    my @coercion_calls;
    my $inner = async sub {
        my ($scope, $receive, $send) = @_;
        push @coercion_calls, $scope;
        await $send->({
            type    => 'http.response.start',
            status  => 200,
            headers => [['content-type', 'text/plain']],
        });
        await $send->({ type => 'http.response.body', body => 'ok', more => 0 });
    };

    my $map = PAGI::App::URLMap->new;
    $map->mount('/api' => $inner);
    my $app = $map->to_app;

    my @sent;
    my $send = sub { my ($msg) = @_; push @sent, $msg; Future->done };
    $app->({ type => 'http', method => 'GET', path => '/api/users' },
        sub { Future->done }, $send)->get;

    is $coercion_calls[0]{root_path}, '/api', 'root_path set to mount prefix';
    is $coercion_calls[0]{path}, '/users', 'path has prefix stripped';
    ok !exists $coercion_calls[0]{script_name}, 'off-spec script_name key is gone';

    @sent = ();
    @coercion_calls = ();
    $app->({ type => 'http', method => 'GET', path => '/api/users', root_path => '/outer' },
        sub { Future->done }, $send)->get;
    is $coercion_calls[0]{root_path}, '/outer/api', 'root_path appends to existing (nested mounts)';
};

subtest 'URLMap accepts instantiated components and rejects package apps' => sub {
    require TestApps::Component;

    my $map = PAGI::App::URLMap->new(
        default => TestApps::Component->new(body => 'fallback'),
    );
    $map->mount('/c' => TestApps::Component->new(body => 'mounted'));
    $map->mount('/s' => TestApps::Component->new(body => 'second'));
    my $app = $map->to_app;

    my @sent;
    my $send = sub { my ($msg) = @_; push @sent, $msg; Future->done };

    $app->({ type => 'http', method => 'GET', path => '/c/x' },
        sub { Future->done }, $send)->get;
    is $sent[1]{body}, 'mounted', 'component object mounted directly';

    @sent = ();
    $app->({ type => 'http', method => 'GET', path => '/s/x' },
        sub { Future->done }, $send)->get;
    is $sent[1]{body}, 'second', 'a second component object mounted directly';

    @sent = ();
    $app->({ type => 'http', method => 'GET', path => '/nomatch' },
        sub { Future->done }, $send)->get;
    is $sent[1]{body}, 'fallback', 'default coerced too';

    like(
        dies { PAGI::App::URLMap->new->mount('/bad' => 'TestApps::Component') },
        qr/to_app\(\) application must be a coderef or instantiated object with to_app/,
        'a mount package string is rejected without loading',
    );
    like(
        dies { PAGI::App::URLMap->new(default => 'TestApps::Component') },
        qr/to_app\(\) application must be a coderef or instantiated object with to_app/,
        'a default package string is rejected',
    );
};

subtest 'Cascade preserves app coercion and catch options' => sub {
    require TestApps::Component;

    my $cascade = PAGI::App::Cascade->new(
        apps => [PAGI::Pages->not_found(as => 'text')],
    );
    $cascade->add(make_response_app(404, 'coderef'));
    $cascade->add(TestApps::Component->new(body => 'object'));
    my $app = $cascade->to_app;

    my @sent;
    my $send = sub { my ($msg) = @_; push @sent, $msg; Future->done };
    $app->({ type => 'http', method => 'GET', path => '/x' },
        sub { Future->done }, $send)->get;

    is $sent[0]{status}, 200, 'fell through the 404 component';
    is $sent[1]{body}, 'object', 'coderef and component object are coerced';

    @sent = ();
    PAGI::App::Cascade->new(
        apps => [
            make_response_app(404, 'first'),
            TestApps::Component->new(body => 'component'),
        ],
    )->to_app->(
        { type => 'http', method => 'GET', path => '/class' },
        sub { Future->done }, $send,
    )->get;
    is $sent[1]{body}, 'component', 'instantiated app object is coerced';

    @sent = ();
    PAGI::App::Cascade->new(
        apps  => [make_response_app(403, 'caught'), make_response_app(200, 'custom')],
        catch => [403],
    )->to_app->(
        { type => 'http', method => 'GET', path => '/custom' },
        sub { Future->done }, $send,
    )->get;
    is $sent[1]{body}, 'custom', 'custom catch remains supported';

    like(
        dies { PAGI::App::Cascade->new(apps => [[]]) },
        qr/to_app\(\) application must be a coderef or instantiated object with to_app/,
        'constructor invalid shape uses the shared app diagnostic',
    );
    like(
        dies { PAGI::App::Cascade->new->add({}) },
        qr/to_app\(\) application must be a coderef or instantiated object with to_app/,
        'add invalid shape uses the shared app diagnostic',
    );
    like(
        dies { PAGI::App::Cascade->new(apps => ['TestApps::Component']) },
        qr/to_app\(\) application must be a coderef or instantiated object with to_app/,
        'Cascade never treats a package string as an app',
    );
};

subtest 'Pages redirect endpoints and ordinary closures compose as apps' => sub {
    my $run = sub {
        my ($app, $scope) = @_;
        my @sent;
        my $send = sub { my ($m) = @_; push @sent, $m; Future->done };
        $app->($scope, sub { Future->done }, $send)->get;
        return \@sent;
    };

    my $sent = $run->(
        PAGI::Pages->moved_permanently('/new', as => 'text'),
        { type => 'http', method => 'GET', path => '/old' },
    );
    is $sent->[0]{status}, 301, 'status';
    my %h = map { lc($_->[0]) => $_->[1] } @{$sent->[0]{headers}};
    is $h{location}, '/new', 'location';
    is $h{'content-type'}, 'text/plain; charset=utf-8',
        'fixed endpoint renders a Pages representation';

    my $dynamic = async sub {
        my ($scope, $receive, $send) = @_;
        my $target = "/from$scope->{path}";
        my $response = PAGI::Pages->redirect(
            $scope,
            $target,
            preserve_query => 1,
            as             => 'text',
        );
        await Future->wrap($response->respond($send));
    };
    $sent = $run->(
        $dynamic,
        { type => 'http', method => 'GET', path => '/p', query_string => 'a=1' },
    );
    %h = map { lc($_->[0]) => $_->[1] } @{$sent->[0]{headers}};
    is $h{location}, '/from/p?a=1',
        'ordinary closure computes the target and asks Pages to preserve query';
    is $sent->[0]{status}, 302, 'default status';

    $sent = $run->(
        PAGI::Pages->redirect('/x', as => 'text'),
        { type => 'http', method => 'GET', path => '/y', query_string => 'a=1' },
    );
    %h = map { lc($_->[0]) => $_->[1] } @{$sent->[0]{headers}};
    is $h{location}, '/x', 'Pages secure default does not preserve query';
};

subtest 'Pages terminal endpoints participate in Cascade catch handling' => sub {
    my $run = sub {
        my ($app, $scope) = @_;
        my @sent;
        my $send = sub { my ($m) = @_; push @sent, $m; Future->done };
        $app->($scope, sub { Future->done }, $send)->get;
        return \@sent;
    };

    my $cascade = PAGI::App::Cascade->new(
        apps => [
            PAGI::Pages->not_found(as => 'text'),
            PAGI::Pages->gone(as => 'text'),
        ],
    )->to_app;
    my $sent = $run->(
        $cascade,
        { type => 'http', method => 'GET', path => '/x' },
    );
    is $sent->[0]{status}, 410, 'caught Pages 404 advances to final Pages endpoint';
    like $sent->[1]{body}, qr/^410 Gone/m,
        'final Pages endpoint owns the terminal representation';
};

done_testing;
