#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Scalar::Util qw(refaddr);

use lib 'lib';
use PAGI::App::Router;
use PAGI::Compose qw(compose);
use PAGI::Response ();

sub invoke {
    my ($app, %scope) = @_;
    my @events;
    $app->({
        type => 'http', method => 'GET', path => '/', headers => [], %scope,
    }, sub {
        return Future->done({ type => 'http.request', body => '', more => 0 });
    }, sub {
        push @events, $_[0];
        return Future->done;
    })->get;
    return \@events;
}

sub body {
    my ($events) = @_;
    return join '', map { $_->{body} // '' }
        grep { ($_->{type} // '') eq 'http.response.body' } @$events;
}

subtest 'basic App routing returns Responses through the shared compiler' => sub {
    my $router = PAGI::App::Router->new;
    $router->get('/users' => sub { return PAGI::Response->text('Users list') });
    my $app = compose(app => $router)->to_app;

    my $matched = invoke($app, path => '/users');
    is([$matched->[0]{status}, body($matched)], [200, 'Users list'],
        'exact path returns its Request handler Response');
    is(invoke($app, path => '/posts')->[0]{status}, 404,
        'unknown path returns 404');
    my $wrong = invoke($app, method => 'POST', path => '/users');
    is($wrong->[0]{status}, 405, 'wrong method returns 405');
    my ($allow) = map { $_->[1] }
        grep { lc($_->[0]) eq 'allow' } @{$wrong->[0]{headers}};
    is($allow, 'GET, HEAD', 'shared automatic HEAD appears in Allow');
};

subtest 'brace parameters and terminal wildcards reach Request' => sub {
    my @captured;
    my $router = PAGI::App::Router->new;
    $router->get('/users/{id}' => sub {
        push @captured, $_[0]->path_params;
        return PAGI::Response->text('user');
    });
    $router->get('/users/{user_id}/posts/{post_id}' => sub {
        push @captured, $_[0]->path_params;
        return PAGI::Response->text('post');
    });
    $router->get('/files/*filepath' => sub {
        push @captured, $_[0]->path_params;
        return PAGI::Response->text('file');
    });
    my $app = $router->to_app;

    invoke($app, path => '/users/123');
    invoke($app, path => '/users/42/posts/99');
    invoke($app, path => '/files/path/to/file.txt');
    is(\@captured, [
        { id => 123 },
        { user_id => 42, post_id => 99 },
        { filepath => 'path/to/file.txt' },
    ], 'all shared Pattern captures are exposed by Request');
};

subtest 'HTTP verb methods and automatic HEAD retain shared behavior' => sub {
    my $router = PAGI::App::Router->new;
    $router->post('/users' => sub {
        return PAGI::Response->text('Created', status => 201);
    });
    $router->delete('/users/{id}' => sub {
        return PAGI::Response->text('', status => 204);
    });
    $router->get('/report' => sub {
        return PAGI::Response->text('representation', status => 203);
    });
    my $app = $router->to_app;

    is(invoke($app, method => 'POST', path => '/users')->[0]{status}, 201,
        'POST declaration matches');
    is(invoke($app, method => 'DELETE', path => '/users/123')->[0]{status}, 204,
        'DELETE declaration matches');
    my $head = invoke($app, method => 'HEAD', path => '/report');
    is([$head->[0]{status}, body($head)], [203, ''],
        'GET automatic HEAD retains status and suppresses its body');
};

subtest 'route information lives in pagi.routing rather than pagi.router' => sub {
    my $captured;
    my $router = PAGI::App::Router->new;
    $router->get('/users/{id}' => sub {
        my ($request) = @_;
        my $frame = $request->scope->{'pagi.routing'}{frames}[-1];
        $captured = {
            match => { %{$frame->{match}} },
            captures => { %{$frame->{captures}} },
            has_old => exists $request->scope->{'pagi.router'} ? 1 : 0,
        };
        return PAGI::Response->text('OK');
    })->name('show')->desc('Show user');

    invoke($router->to_app, path => '/users/123');
    is($captured, {
        match => {
            kind => 'route',
            route => '/users/{id}',
            name => '/show',
            logical_namespace => '/',
            desc => 'Show user',
        },
        captures => { id => 123 },
        has_old => 0,
    }, 'the shared metadata frame records the effective route');
};

subtest 'App Router HTTP default is one-shot, retained, and HTTP NONE only' => sub {
    my @default_calls;
    my $default = sub {
        my ($scope, $receive, $send) = @_;
        push @default_calls, [$scope->{type}, scalar @_];
        $send->({
            type => 'http.response.start', status => 404, headers => [],
        })->get;
        $send->({
            type => 'http.response.body', body => 'custom', more => 0,
        })->get;
        return Future->done;
    };

    my $constructor = PAGI::App::Router->new(http_default => $default);
    my $first = $constructor->to_router;
    is(refaddr($first->http_default), refaddr($default),
        'constructor retains the exact native application');
    like(dies { $constructor->http_default(sub { }) },
        qr/http_default.*only.*once|already configured/i,
        'constructor configuration consumes the one method slot');

    my $method = PAGI::App::Router->new;
    is($method->http_default($default), $method,
        'method configuration returns the mutable Router');
    my $method_snapshot = $method->to_router;
    $method->get('/late' => sub { return PAGI::Response->text('late') });
    is($method_snapshot->routes, [],
        'later parent mutation cannot alter an old snapshot');
    is(refaddr($method_snapshot->http_default), refaddr($default),
        'the old snapshot retains its configured default identity');
    like(dies { $method->http_default($default) },
        qr/http_default.*only.*once|already configured/i,
        'a second method configuration croaks');

    my $app = $constructor->to_app;
    is(body(invoke($app, path => '/missing')), 'custom',
        'HTTP NONE invokes the custom default');
    invoke($app, type => 'websocket', method => undef, path => '/missing',
        extensions => { 'websocket.http.response' => {} });
    invoke($app, type => 'sse', method => undef, path => '/missing');
    is(\@default_calls, [['http', 3]],
        'WebSocket and SSE misses never invoke the HTTP default');
};

done_testing;
