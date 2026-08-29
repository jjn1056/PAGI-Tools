package MyApp::API;
use parent 'PAGI::Endpoint::Router';
use strict;
use warnings;
use Future::AsyncAwait;
use PAGI::Pages qw(not_found_page unauthorized_page);
use PAGI::Response qw(html_response json_response);
use PAGI::Routing::URL qw(path_for);
use PAGI::State qw(app_state);

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
    my $response = not_found_page($scope,
        detail => 'No API Endpoint route matched');
    await $response->respond($scope, $receive, $send);
}

sub require_demo_token {
    my ($self, $inner) = @_;
    return async sub {
        my ($scope, $receive, $send) = @_;
        my $request = $self->new_request($scope, $receive);

        return await $inner->($scope, $receive, $send)
            if ($request->header('x-demo-token') // '') eq 'demo-token';

        my $response = unauthorized_page($scope,
            challenge => 'DemoToken realm="endpoint-router-demo"',
            detail    => 'demo token required');
        return await $response->respond($scope, $receive, $send);
    };
}

async sub index {
    my ($self, $request) = @_;
    my $state = app_state($request)
        or die 'endpoint-router-demo requires Compose lifespan state';
    $state->get('metrics')->{requests}++;

    my $alice = path_for($request, 'show', { user_id => 1 });
    my $resource = $state->get('resource')->{name};
    return html_response(<<"HTML");
<!doctype html>
<title>Demo API</title>
<h1>Demo API</h1>
<p>Resource: $resource</p>
<p><a href="$alice">Alice</a></p>
HTML
}

async sub show {
    my ($self, $request) = @_;
    my $state = app_state($request)
        or die 'endpoint-router-demo requires Compose lifespan state';
    $state->get('metrics')->{requests}++;

    my $user_id = $request->path_param('user_id');
    my ($user) = grep { $_->{id} == $user_id } @USERS;
    return html_response("<h1>$user->{name}</h1>") if $user;
    return not_found_page($request,
        detail => 'User not found');
}

async sub status {
    my ($self, $request) = @_;
    my $state = app_state($request)
        or die 'endpoint-router-demo requires Compose lifespan state';
    return json_response({
        status   => 'ready',
        resource => $state->get('resource')->{name},
    });
}

1;
