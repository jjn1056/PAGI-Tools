#!/usr/bin/env perl

use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 'lib';

use PAGI::App::Router;
use PAGI::Compose qw(compose);
use PAGI::Response qw(text_response);
use PAGI::Routing qw(middleware mount route router);
use PAGI::Utils qw(as_app);

{
    package Local::CookbookEndpoint;
    use parent 'PAGI::Endpoint::Router';
    use PAGI::Utils qw(as_app);

    sub routes {
        my ($self, $r) = @_;
        $r->mount('/child', routes => sub {
            my ($child) = @_;
            $child->get('/' => sub {
                return main::text_response('endpoint child');
            });
        })->name('child');
        $r->get('/native' => as_app($self->app_as('native')));
    }

    sub native {
        my ($self, $scope, $receive, $send) = @_;
        return main::response_app(200, 'endpoint native')->(
            $scope, $receive, $send,
        );
    }
}

sub slurp_file {
    my ($file) = @_;
    open my $handle, '<', $file or die "Cannot read $file: $!";
    local $/;
    my $source = <$handle>;
    close $handle or die "Cannot close $file: $!";
    return $source;
}

sub cookbook_apples_block {
    my ($cookbook) = @_;
    my $heading = '=head2 Complete Declarative Apples Application';
    my $position = index $cookbook, $heading;
    die 'Complete Declarative Apples Application section not found'
        if $position < 0;

    my @lines = split /\n/, substr($cookbook, $position);
    my (@block, $started);
    for my $line (@lines) {
        if (!$started) {
            next unless $line eq '  use v5.40;';
            $started = 1;
        }
        last if length($line) && $line !~ /^  /;
        push @block, length($line) ? substr($line, 2) : '';
    }
    pop @block while @block && $block[-1] eq '';
    return join("\n", @block) . "\n";
}

sub http_scope {
    my (%changes) = @_;
    my $path = exists $changes{path} ? $changes{path} : '/';
    return {
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
        %changes,
    };
}

sub receive_request {
    return Future->done({
        type => 'http.request',
        body => '',
        more => 0,
    });
}

sub run_http {
    my ($app, %changes) = @_;
    my (@events, @warnings);
    my $error;
    my $send = sub {
        push @events, $_[0];
        return Future->done;
    };
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $ok = eval {
            Future->wrap($app->(
                http_scope(%changes),
                \&receive_request,
                $send,
            ))->get;
            1;
        };
        $error = $@ unless $ok;
    }
    return (\@events, $error, \@warnings);
}

sub response_app {
    my ($status, $body) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        my $content = ref($body) eq 'CODE' ? $body->($scope) : $body;
        await Future->wrap($send->({
            type => 'http.response.start', status => $status, headers => [],
        }));
        await Future->wrap($send->({
            type => 'http.response.body', body => $content, more => 0,
        }));
    };
}

sub response_status {
    my ($events) = @_;
    my ($start) = grep {
        ($_->{type} // '') eq 'http.response.start'
    } @$events;
    return defined $start ? $start->{status} : undef;
}

sub response_body {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
}

my $cookbook = slurp_file('lib/PAGI/Tools/Cookbook.pod');

subtest 'canonical apples block stays synchronized with the runnable example' => sub {
    my $example = slurp_file('examples/starlette-apples/app.pl');
    $example =~ s/\A#![^\n]*\n//;
    is(cookbook_apples_block($cookbook), $example,
        'the complete Cookbook block is the runnable apples source without its shebang');
};

subtest 'Cookbook publishes the representative final forms' => sub {
    unlike($cookbook,
        qr/\b(?:mount|route|Router)\s+or\s+group\s+level\b/i,
        'Cookbook never recommends the removed group routing boundary');
    like($cookbook,
        qr/\$main_router->mount\('\/api', app => \$api_router->to_router\)/,
        'mutable App Router shows an explicit application Mount');
    like($cookbook,
        qr/\$main_router->mount\('\/reports', routes => sub \{/,
        'mutable App Router shows the routes callback Mount shorthand');
    like($cookbook,
        qr/route\('\/files\/\*path' => as_app\(\$file_endpoint\)/,
        'as_app remains the exact native Route marker');
    like($cookbook,
        qr/\$r->get\('\/download' => as_app\(\$self->app_as\('download'\)\)\)/,
        'Endpoint app_as remains explicit beneath as_app');
    like($cookbook,
        qr/outer Router middleware.*Router-mount middleware.*child Router middleware.*inline-mount middleware.*route middleware/s,
        'middleware placement order is published');
    like($cookbook,
        qr/A bare Router has no root ErrorHandler, response-completion guard, or lifespan\s+owner, but its compiled app already installs a Router HeadBoundary\./,
        'direct Router retains its own HEAD owner while lacking root safety');
    like($cookbook,
        qr/outer idempotent application-root HEAD boundary/,
        'Compose publishes its distinct outer HEAD owner');
    like($cookbook,
        qr/compose\(\s+routes => \[.*?http_default => not_found\(.*?desc\s+=> 'Starlette apples comparison application'/s,
        'Compose routes form publishes flattened Router options');
    unlike($cookbook, qr/compose\(\s*app\s*=>/,
        'Cookbook has no removed Compose app mode');
};

subtest 'representative Cookbook forms construct and dispatch' => sub {
    my $middleware_calls = 0;
    my $factory = sub {
        my ($app) = @_;
        return async sub {
            my ($scope, $receive, $send) = @_;
            ++$middleware_calls;
            await Future->wrap($app->($scope, $receive, $send));
        };
    };

    my $declarative = router(routes => [
        route('/leaf' => sub { return text_response('leaf') },
            middleware => [middleware($factory)]),
        route('/raw' => as_app(response_app(200, 'raw'))),
        mount('/app', app => response_app(200, sub {
            my ($scope) = @_;
            return 'app:' . $scope->{path} . ':' . $scope->{root_path};
        })),
        mount('/routes', routes => [
            route('/' => sub { return text_response('routes') }),
        ]),
    ])->to_app;

    my %expected = (
        '/leaf'       => 'leaf',
        '/raw'        => 'raw',
        '/app/tail'   => 'app:/tail:/app',
        '/routes'     => 'routes',
        '/routes/'    => 'routes',
    );
    for my $path (sort keys %expected) {
        my ($events, $error) = run_http(
            $declarative, path => $path, raw_path => $path,
        );
        is($error, undef, "$path dispatches without error");
        is(response_body($events), $expected{$path},
            "$path uses the documented application position");
    }
    is($middleware_calls, 1, 'route middleware wraps the selected leaf once');

    my $callback_calls = 0;
    my $mutable = PAGI::App::Router->new;
    $mutable->mount('/mutable', routes => sub {
        my ($child) = @_;
        ++$callback_calls;
        $child->get('/' => sub { return text_response('mutable') });
    })->name('mutable');
    my ($mutable_events, $mutable_error) = run_http(
        $mutable->to_app, path => '/mutable', raw_path => '/mutable',
    );
    is($mutable_error, undef, 'mutable callback Mount dispatches');
    is([$callback_calls, response_body($mutable_events)], [1, 'mutable'],
        'mutable callback runs once and constructs its child Router');

    my $endpoint = Local::CookbookEndpoint->new;
    my ($endpoint_child, $endpoint_child_error) = run_http(
        $endpoint->to_app, path => '/child', raw_path => '/child',
    );
    is($endpoint_child_error, undef, 'Endpoint routes callback dispatches');
    is(response_body($endpoint_child), 'endpoint child',
        'Endpoint callback Mount constructs its child Router');
    my ($endpoint_native, $endpoint_native_error) = run_http(
        $endpoint->to_app, path => '/native', raw_path => '/native',
    );
    is($endpoint_native_error, undef, 'Endpoint app_as dispatches');
    is(response_body($endpoint_native), 'endpoint native',
        'Endpoint app_as supplies an exact native application');
};

subtest 'direct Router stays low-level while Compose supplies root safety' => sub {
    my $silent = async sub { return };
    my $router = router(routes => [
        route('/silent' => as_app($silent)),
    ]);

    my ($direct_events, $direct_error, $direct_warnings) = run_http(
        $router->to_app, path => '/silent', raw_path => '/silent',
    );
    is($direct_error, undef, 'direct Router permits selected application silence');
    is($direct_events, [], 'direct Router does not synthesize a response');
    is($direct_warnings, [], 'direct Router emits no root-safety warning');

    my ($safe_events, $safe_error) = run_http(
        compose(routes => [mount('/' => app => $router)])->to_app,
        path => '/silent', raw_path => '/silent',
    );
    is($safe_error, undef, 'Compose contains selected application silence');
    is(response_status($safe_events), 500,
        'Compose response-completion guard emits the production-safe 500');
};

done_testing;
