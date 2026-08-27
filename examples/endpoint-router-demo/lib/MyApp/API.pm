package MyApp::API;
use parent 'PAGI::Endpoint::Router';
use strict;
use warnings;
use Future::AsyncAwait;
use PAGI::Pages;

use MyApp::API::Events;

my @USERS = (
    { id => 1, name => 'Alice' },
    { id => 2, name => 'Bob' },
);

sub new {
    my ($class, %args) = @_;
    die "events is required\n" unless $args{events};
    return bless { events => $args{events} }, $class;
}

sub Int { return qr/\A\d+\z/ }

sub routes {
    my ($self, $r) = @_;

    $r->http_default($self->app_as('api_not_found'));
    $r->get('/index' => [$self->middleware_as('require_demo_token')] => 'index')
        ->name('index');
    $r->get('/show/{user_id:&Int}' => [$self->middleware_as('require_demo_token')] => 'show')
        ->name('show');
    $r->mount('/tools', routes => sub {
        my ($tools) = @_;
        $tools->get('/status' => 'status')->name('status');
    })->name('tools');
    $r->mount('/events', app => $self->{events}->to_router)->name('events');
}

async sub api_not_found {
    my ($self, $scope, $receive, $send) = @_;
    my $response = PAGI::Pages->not_found($scope,
        detail => 'No API Endpoint route matched');
    await $response->respond($send);
}

sub require_demo_token {
    my ($self, $inner) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        my $c = $self->new_context($scope, $receive, $send);

        return await $inner->($scope, $receive, $send)
            if ($c->request->header('x-demo-token') // '') eq 'demo-token';

        my $response = PAGI::Pages->unauthorized($scope,
            challenge => 'DemoToken realm="endpoint-router-demo"',
            detail    => 'demo token required');
        return await $response->respond($send);
    };
}

async sub index {
    my ($self, $c) = @_;
    $c->state->{metrics}{requests}++;

    my $alice = $c->path_for('show', { user_id => 1 });
    return $c->html(<<"HTML");
<!doctype html>
<title>Demo API</title>
<h1>Demo API</h1>
<p>Resource: $c->state->{resource}{name}</p>
<p><a href="$alice">Alice</a></p>
HTML
}

async sub show {
    my ($self, $c) = @_;
    $c->state->{metrics}{requests}++;

    my $user_id = $c->path_param('user_id');
    my ($user) = grep { $_->{id} == $user_id } @USERS;
    return $c->html("<h1>$user->{name}</h1>") if $user;
    return PAGI::Pages->not_found($c,
        detail => 'User not found');
}

async sub status {
    my ($self, $c) = @_;
    return $c->json({
        status   => 'ready',
        resource => $c->state->{resource}{name},
    });
}

1;
