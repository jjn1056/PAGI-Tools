#!/usr/bin/env perl
use strict;
use warnings;
use Test2::V0;
use Future;

use lib 'lib';
use PAGI::App::Router;

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
    $router->get('/users' => sub { return $_[0]->text('Users list') });
    my $app = $router->to_app;

    my $matched = invoke($app, path => '/users');
    is([$matched->[0]{status}, body($matched)], [200, 'Users list'],
        'exact path returns its Context Response');
    is(invoke($app, path => '/posts')->[0]{status}, 404,
        'unknown path returns 404');
    my $wrong = invoke($app, method => 'POST', path => '/users');
    is($wrong->[0]{status}, 405, 'wrong method returns 405');
    my ($allow) = map { $_->[1] }
        grep { lc($_->[0]) eq 'allow' } @{$wrong->[0]{headers}};
    is($allow, 'GET, HEAD', 'shared automatic HEAD appears in Allow');
};

subtest 'brace parameters and terminal wildcards reach Context' => sub {
    my @captured;
    my $router = PAGI::App::Router->new;
    $router->get('/users/{id}' => sub {
        push @captured, $_[0]->path_params;
        return $_[0]->text('user');
    });
    $router->get('/users/{user_id}/posts/{post_id}' => sub {
        push @captured, $_[0]->path_params;
        return $_[0]->text('post');
    });
    $router->get('/files/*filepath' => sub {
        push @captured, $_[0]->path_params;
        return $_[0]->text('file');
    });
    my $app = $router->to_app;

    invoke($app, path => '/users/123');
    invoke($app, path => '/users/42/posts/99');
    invoke($app, path => '/files/path/to/file.txt');
    is(\@captured, [
        { id => 123 },
        { user_id => 42, post_id => 99 },
        { filepath => 'path/to/file.txt' },
    ], 'all shared Pattern captures are exposed by Context');
};

subtest 'HTTP verb methods and automatic HEAD retain shared behavior' => sub {
    my $router = PAGI::App::Router->new;
    $router->post('/users' => sub {
        return $_[0]->response->status(201)->text('Created');
    });
    $router->delete('/users/{id}' => sub {
        return $_[0]->response->status(204)->text('');
    });
    $router->get('/report' => sub {
        return $_[0]->response->status(203)->text('representation');
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
        my ($c) = @_;
        my $frame = $c->scope->{'pagi.routing'}{frames}[-1];
        $captured = {
            match => { %{$frame->{match}} },
            captures => { %{$frame->{captures}} },
            has_old => exists $c->scope->{'pagi.router'} ? 1 : 0,
        };
        return $c->text('OK');
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

done_testing;
